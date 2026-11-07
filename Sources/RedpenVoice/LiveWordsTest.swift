import AppKit
import AVFoundation
import FluidAudio
import Foundation
import VoiceCore
import WhisperKit

/// Synthetic input only when invoked for this build. Never opens a microphone, tap, notes writer, or provider.
enum LiveWordsTest {
    @MainActor
    static func run(_ args: [String]) async -> Int32 {
        guard let first = args.first else { print("usage: --live-words-test audio.wav [others.wav|silent] [--speed 4] [--dictation-check]"); return 2 }
        // The shipping app cannot share this test process's priority leases. Never compete with its dictation.
        let pid = ProcessInfo.processInfo.processIdentifier
        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.processIdentifier != pid && $0.executableURL?.lastPathComponent == "RedpenVoice"
        }) {
            print("ASR test not started. Another Redpen Voice instance is running. Keep using the installed app; run this test only when it is closed.")
            return 2
        }
        do {
            // A real meeting has active capture. This passive process does not, so keep App Nap from changing
            // its clock or WebKit scheduling while it feeds synthetic audio at talking speed.
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                                 reason: "Real-time synthetic live words verification")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            guard captureChecks() else { return 1 }
            let me = try AudioProcessor.loadAudioAsFloatArray(fromPath: first)
            let others = args.count > 1 && args[1] != "silent" ? try AudioProcessor.loadAudioAsFloatArray(fromPath: args[1]) : []
            let speed = CommandLine.arguments.firstIndex(of: "--speed").flatMap { $0 + 1 < CommandLine.arguments.count ? Double(CommandLine.arguments[$0 + 1]) : nil } ?? 1
            guard speed.isFinite, speed > 0, speed <= 100 else { print("speed must be above 0 and at most 100"); return 2 }
            let control = LiveWordsControl()
            let loadStart = Date()
            _ = try await LiveWordsEngine.shared.load()
            let loaded = Date().timeIntervalSince(loadStart)
            if CommandLine.arguments.contains("--dictation-check") {
                return try await dictationCheck(me, control: control)
            }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("redpen-live-test-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: folder) }
            let tracks: [LiveWordsTrack: TrackWriter] = [
                .me: try TrackWriter(url: folder.appendingPathComponent("me.pcm")),
                .others: try TrackWriter(url: folder.appendingPathComponent("others.pcm"))
            ]
            defer { tracks.values.forEach { $0.close() } }
            let length = max(me.count, others.count)
            let input: [LiveWordsTrack: [Float]] = [.me: me, .others: others]
            let feed = LiveWordsTestFeed()
            let window = LiveWordsWindow()
            await window.prepareForTest()
            defer { window.clearAndClose() }
            let source = LiveWordsPCMSource(starts: [.me: 0, .others: 0]) {
                tracks.mapValues { .init(url: $0.url, frames: $0.frames, offset: 0) }
            }
            let start = Date()
            let observations = LiveWordsTestObservations()
            let waits = Task.detached(priority: .background) {
                guard CommandLine.arguments.contains("--exercise-waits") else { return }
                try await Task.sleep(for: .seconds(1))
                control.setPaused(true)
                try await Task.sleep(for: .milliseconds(100))
                let paused = observations.requested, pausedDone = observations.delivered
                try await Task.sleep(for: .milliseconds(400))
                print("pause wait: submitted \(paused) -> \(observations.requested), completed \(pausedDone) -> \(observations.delivered)")
                observations.check(observations.requested == paused)
                control.setPaused(false)
                try await Task.sleep(for: .milliseconds(800))
                let dictation = LiveWordsPriority.shared.begin()
                defer { dictation.end() }
                try await Task.sleep(for: .milliseconds(100))
                let blocked = observations.requested, blockedDone = observations.delivered
                try await Task.sleep(for: .milliseconds(400))
                print("dictation wait: submitted \(blocked) -> \(observations.requested), completed \(blockedDone) -> \(observations.delivered)")
                observations.check(observations.requested == blocked)
            }
            defer { waits.cancel() }
            let writer = Task.detached(priority: .utility) {
                var i = 0
                // End with quiet so the last line uses the real pause rule too.
                while i < length + 16_000 {
                    try Task.checkCancellation()
                    for track in LiveWordsTrack.allCases {
                        let audio = input[track]!
                        let end = min(audio.count, i + 1_600)
                        tracks[track]!.write(mono: i < end ? Array(audio[i..<end]) : [Float](repeating: 0, count: 1_600), rate: 16_000)
                    }
                    i += 1_600
                    let due = Double(i) / 16_000 / speed
                    let wait = due - Date().timeIntervalSince(start)
                    if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                }
                tracks.values.forEach { $0.close() }
                feed.finish()
            }
            defer { writer.cancel(); control.cancel() }
            var delays: [Double] = [], workerDelays: [Double] = [], callbackLags: [Double] = [], previews = 0, maxBuffer = 0, lineCount = 0
            var expectedFinals = 0, viewFailures = 0
            var all = LiveWordsLines()
            try await LiveWordsRunner.run(control: control, starts: [.me: 0, .others: 0], next: { track, n in
                var value = try await source.next(track, maximum: n)
                value.ended = feed.done && value.samples.isEmpty
                return value
            }, onLine: { line in
                // As in the real window's receive method, recheck after hopping back to its actor. Count when an
                // update is submitted, not its WebKit completion: an earlier submission can finish during a pause.
                guard (try? await control.wait()) != nil else { return }
                observations.request()
                all.put(line)
                if line.final, !line.text.isEmpty { expectedFinals += 1 }
                let workerDelay = Date().timeIntervalSince(start) - line.end / speed
                // Match production: submit the view update without blocking audio on WebKit. Its completion still
                // measures appearance, separately, and the final flush below waits for every submitted update.
                window.update(all.lines, elapsed: line.end, status: "Listening…", paused: false, onCall: !others.isEmpty) { applied in
                    guard let applied else { viewFailures += 1; print("live words page did not apply line"); return }
                    let delay = applied.timeIntervalSince(start) - line.end / speed
                    let callbackLag = Date().timeIntervalSince(applied)
                    observations.deliver()
                    if line.final, !line.text.isEmpty {
                        delays.append(delay); workerDelays.append(workerDelay); callbackLags.append(callbackLag); lineCount += 1
                        // Explicit CLI test output. Production writes no live words to any log or file.
                        print("[\(Meeting.clockShort(line.start))] \(line.track.rawValue) final delay \(String(format: "%.3f", delay))s, worker \(String(format: "%.3f", workerDelay))s, reply \(String(format: "%.3f", callbackLag))s | \(line.text)")
                    } else { previews += 1 }
                }
            }, onBuffer: { maxBuffer = max(maxBuffer, $0) })
            try await writer.value
            try await waits.value
            guard await window.render(all.lines, elapsed: Double(length) / 16_000, onCall: !others.isEmpty) else { return 1 }
            let sorted = delays.sorted()
            let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            print("live words test: \(lineCount) finished lines, \(previews) previews, speed \(speed)x, \(String(format: "%.3f", loaded))s engine load")
            print("speech-end to finished line applied in WebKit, wall seconds: median \(String(format: "%.3f", median)), max \(String(format: "%.3f", sorted.last ?? 0))")
            let workerSorted = workerDelays.sorted()
            print("speech-end to worker output, wall seconds: median \(String(format: "%.3f", workerSorted.isEmpty ? 0 : workerSorted[workerSorted.count / 2])), max \(String(format: "%.3f", workerSorted.last ?? 0))")
            print("WebKit reply after DOM application, max \(String(format: "%.3f", callbackLags.max() ?? 0))s")
            print("memory: peak RSS \(MeetingTest.peakMemory()) bytes, max live audio buffers \(maxBuffer) samples (\(maxBuffer * 4) bytes), text \(all.lines.reduce(0) { $0 + $1.text.utf8.count }) bytes")
            all.clear()
            print("cleared lines \(all.lines.count), temporary PCM removed at exit")
            print("view applied finished lines \(lineCount) of \(expectedFinals), failures \(viewFailures)")
            if viewFailures > 0 || lineCount != expectedFinals { return 1 }
            if CommandLine.arguments.contains("--exercise-waits") {
                print("live wait checks: \(observations.passed) passed, \(observations.failed) failed; recording continued and backlog was read afterward")
                if observations.failed > 0 { return 1 }
            }
            return lineCount > 0 || (me + others).allSatisfy({ abs($0) < 0.006 }) ? 0 : 1
        } catch {
            print("live words test failed, \(MeetingNotes.code(error))")
            return 1
        }
    }

    /// The real mic handoff, with synthetic PCM and no AVCaptureSession. Dictation stop must leave the meeting on.
    private static func captureChecks() -> Bool {
        let recorder = Recorder()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
        buffer.frameLength = 480
        buffer.floatChannelData![0].initialize(repeating: 0.1, count: 480)
        var meeting = 0, dictation = 0, checks = 0, failures = 0
        func check(_ ok: Bool) { checks += 1; if !ok { failures += 1 } }
        recorder.beginMeeting { meeting += Int($0.frameLength) }
        recorder.receive(buffer); check(meeting == 480 && dictation == 0)
        recorder.begin(onBuffer: { dictation += Int($0.frameLength) }, onLevel: { _ in })
        recorder.receive(buffer); check(meeting == 960 && dictation == 480)
        recorder.end(); recorder.receive(buffer); check(meeting == 1_440 && dictation == 480)
        recorder.begin(onBuffer: { dictation += Int($0.frameLength) }, onLevel: { _ in })
        recorder.endMeeting(); recorder.receive(buffer); check(meeting == 1_440 && dictation == 960)
        recorder.end(); recorder.receive(buffer); check(meeting == 1_440 && dictation == 960)
        check(!recorder.isRunning)
        var config = Config(); config.liveWords = true
        check(config.meetingLiveWords != true && config.whileTalking == .box)
        config.meetingLiveWords = false
        check(config.liveWords == true && config.whileTalking == .box)
        let data = try! JSONEncoder().encode(config)
        let decoded = try! JSONDecoder().decode(Config.self, from: data)
        check(decoded.meetingLiveWords == false && decoded.liveWords == true)
        var old = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        old.removeValue(forKey: "meetingLiveWords")
        let legacy = try! JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: old))
        check(legacy.meetingLiveWords == nil && legacy.liveWords == true)
        let priority = Transcriber.Session()
        check(LiveWordsPriority.shared.idleEpoch == nil)
        priority.cancel(); check(LiveWordsPriority.shared.idleEpoch != nil)
        print("live capture/config/priority checks: \(checks - failures) passed, \(failures) failed")
        return failures == 0
    }

    /// Balanced off/on repeats of the same short synthetic utterance. Uses a real dictation session, including
    /// streaming and the normal 100/500 ms post-release audio, but no Accessibility, clipboard, history, or keys.
    private static func dictationCheck(_ audio: [Float], control: LiveWordsControl) async throws -> Int32 {
        let engine = Transcriber()
        var config = Config(); config.engine = "whisper"; config.draftMode = CommandLine.arguments.contains("--drafts"); config.riskMarks = false
        print("dictation probe: Whisper, drafts \(config.draftMode == true ? "on" : "off"), no text insertion")
        await engine.prepare(config)
        guard engine.state == .ready else { print("Whisper not ready"); return 1 }
        let sample = Array(audio.prefix(5 * 16_000))
        // Warm the two engines before timing either condition.
        _ = try await engine.liveWordsDictationProbe(sample, config: config)
        _ = try await LiveWordsEngine.shared.text(sample, control: control)
        var off: [Int] = [], on: [Int] = [], offDone: [Int] = [], onDone: [Int] = []
        for enabled in [false, true, true, false, false, true, true, false] {
            let pressure = Task.detached(priority: .background) {
                guard enabled else { return }
                while !Task.isCancelled {
                    _ = try await LiveWordsEngine.shared.text(sample, control: control)
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            // Enter a live prediction before key-down, exercising the nonpreemptible edge too.
            if enabled { try await Task.sleep(for: .milliseconds(40)) }
            let result = try await engine.liveWordsDictationProbe(sample, config: config)
            pressure.cancel(); _ = await pressure.result
            if enabled { on.append(result.engine); onDone.append(result.done) }
            else { off.append(result.engine); offDone.append(result.done) }
            print("dictation live \(enabled ? "on" : "off"): engine \(result.engine)ms, key up to done \(result.done)ms, \(result.words) words")
        }
        func median(_ values: [Int]) -> Double { let v = values.sorted(); return Double(v[1] + v[2]) / 2 }
        print("dictation medians: engine off \(median(off))ms, on \(median(on))ms; key up to done off \(median(offDone))ms, on \(median(onDone))ms")
        print("dictation samples off \(off), on \(on); key up to done off \(offDone), on \(onDone)")
        return 0
    }
}

private final class LiveWordsTestFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    var done: Bool { lock.withLock { finished } }
    func finish() { lock.withLock { finished = true } }
}

private final class LiveWordsTestObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0, submissions = 0, ok = 0, bad = 0
    var requested: Int { lock.withLock { submissions } }
    var delivered: Int { lock.withLock { count } }
    var passed: Int { lock.withLock { ok } }
    var failed: Int { lock.withLock { bad } }
    func deliver() { lock.withLock { count += 1 } }
    func request() { lock.withLock { submissions += 1 } }
    func check(_ value: Bool) { lock.withLock { if value { ok += 1 } else { bad += 1 } } }
}
