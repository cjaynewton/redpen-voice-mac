import AVFoundation
import FluidAudio
import Foundation
import MLX
import VoiceCore

/// `--meeting-test me.wav others.wav out-folder [--engine whisper] [--no-summary]`: the whole after-stop pipeline on
/// two files, without a microphone or tap. Each file goes through the same track writer a meeting uses, 0.1 s at a
/// time, into a recording folder inside `out-folder`, then the notes are written there. `silent` as the first file
/// is a muted microphone as long as the other track; `echo` is the other track heard again by the microphone, a
/// little later and quieter, as on laptop speakers. Everything stays in `out-folder`.
enum MeetingTest {
    static func run(_ args: [String], engine: Transcriber, config base: Config, names: Names) async -> Int32 {
        guard args.count >= 3 else { print("usage: --meeting-test me.wav|silent others.wav|silent out-folder [--room] [--voice my.wav]"); return 2 }
        let out = URL(fileURLWithPath: args[2], isDirectory: true)
        var config = base
        if let e = CommandLine.arguments.firstIndex(of: "--engine"), e + 1 < CommandLine.arguments.count { config.engine = CommandLine.arguments[e + 1] }
        config.meetingsFolder = out.path
        config.keepMeetingAudio = true
        // Only the engine the notes use is loaded, so the memory figure is the meeting's own.
        config.draftMode = false; config.riskMarks = false
        // `--room`: voices in the room told apart on the microphone track (D-1034). `--voice my.wav` first learns
        // that voice as the user's, from pieces of it as dictations would give; run with REDPEN_VOICE_DIR set, so
        // the voiceprint goes into the test's own folder.
        if CommandLine.arguments.contains("--room") { config.roomVoices = true }
        if let v = CommandLine.arguments.firstIndex(of: "--voice"), v + 1 < CommandLine.arguments.count {
            guard ProcessInfo.processInfo.environment["REDPEN_VOICE_DIR"] != nil else { print("--voice needs REDPEN_VOICE_DIR"); return 2 }
            config.knowMyVoice = true
            Voiceprint.forget()
            if let all = try? AudioConverter().resampleAudioFile(URL(fileURLWithPath: CommandLine.arguments[v + 1])) {
                let piece = 16_000 * 8
                for i in 0..<Voiceprint.enough where (i + 1) * piece <= all.count { await Voiceprint.learn(from: Array(all[(i * piece)..<((i + 1) * piece)])) { true } }
            }
            print("voice learned from \(Voiceprint.load()?.count ?? 0) pieces")
        }
        let summarize = !CommandLine.arguments.contains("--no-summary")
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            let work = out.appendingPathComponent("recording-\(UUID().uuidString.prefix(8))", isDirectory: true)
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let t0 = Date()
            await engine.prepare(config)
            guard engine.state == .ready else { print("engine not ready: \(engine.state)"); return 1 }
            let loaded = Date().timeIntervalSince(t0)
            let rssLoaded = peakMemory()
            // Feed both files as a recording would. A silent Others is a meeting in one room.
            let othersURL = URL(fileURLWithPath: args[1])
            let others = try TrackWriter(url: work.appendingPathComponent(MeetingManifest.othersFile))
            let othersSecs = args[1] == "silent" ? feedSilence(seconds: (try? AVAudioFile(forReading: URL(fileURLWithPath: args[0])))
                .map { Double($0.length) / $0.fileFormat.sampleRate } ?? 0, into: others) : try feed(othersURL, into: others)
            let me = try TrackWriter(url: work.appendingPathComponent(MeetingManifest.meFile))
            let meSecs: Double
            switch args[0] {
            case "silent": meSecs = feedSilence(seconds: othersSecs, into: me)
            case "echo":
                // Laptop speakers: the microphone hears the others a little later and quieter.
                _ = feedSilence(seconds: 0.04, into: me)
                meSecs = try feed(othersURL, into: me, gain: 0.3) + 0.04
            default: meSecs = try feed(URL(fileURLWithPath: args[0]), into: me)
            }
            others.close(); me.close()
            var m = MeetingManifest(started: Date()); m.meOffset = 0; m.othersOffset = 0; m.stopped = Date()
            try MeetingNotes.save(m, in: work)
            let t1 = Date()
            var marks: [Int: Double] = [:]
            let r = try await MeetingNotes.write(work, engine: engine, config: config, names: names, summarize: summarize) { pct, _ in
                for step in [80, 100] where pct >= step && marks[step] == nil { marks[step] = Date().timeIntervalSince(t1) }
            }
            let total = Date().timeIntervalSince(t1)
            let written = marks[80] ?? total
            let audioHours = (meSecs + othersSecs) / 3600
            let gb = { (b: Int) in String(format: "%.2f GB", Double(b) / 1_073_741_824) }
            print("""
            meeting-test
              file: \(r.file.path)
              engine: \(config.engine), loaded in \(String(format: "%.1f", loaded)) s
              audio: me \(String(format: "%.1f", meSecs)) s, others \(String(format: "%.1f", othersSecs)) s, meeting \(Meeting.length(r.seconds))
              lines: me \(r.meLines), others \(r.othersLines), echo dropped \(r.echoDropped)
              transcribe both tracks: \(String(format: "%.1f", written)) s (\(String(format: "%.0f", written / max(audioHours, 0.0001))) s per hour of audio)
              audio saved + summary: \(String(format: "%.1f", total - written)) s, summary \(r.summary)
              total after stop: \(String(format: "%.1f", total)) s
              memory: \(gb(rssLoaded)) with the engine loaded, peak \(gb(peakMemory()))
            """)
            return 0
        } catch {
            print("meeting-test failed: \(error.localizedDescription)")
            return 1
        }
    }

    /// `--diarize-test audio.wav out.json [--voice my.wav] [--step 0.2] [--threshold 0.6]` (D-1034): speakers in
    /// the room on one track, for scoring against a reference. Writes the turns and prints how many speakers, how
    /// long it took, and, with `--voice`, how close each speaker is to that voice.
    static func diarize(_ args: [String]) async -> Int32 {
        guard args.count >= 2 else { print("usage: --diarize-test audio.wav out.json [--voice my.wav]"); return 2 }
        func option(_ name: String) -> String? {
            CommandLine.arguments.firstIndex(of: name).flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
        }
        let config = RoomSpeakers.config(step: option("--step").flatMap(Double.init), threshold: option("--threshold").flatMap(Double.init))
        do {
            let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: args[0]))
            let t0 = Date()
            let split = try await RoomSpeakers.split(samples, config: config)
            let seconds = Date().timeIntervalSince(t0)
            var talk = [Double](repeating: 0, count: split.voices.count)
            for t in split.turns { talk[t.speaker] += t.end - t.start }
            print("diarize-test: \(split.voices.count) speakers in \(String(format: "%.1f", seconds)) s for \(Int(Double(samples.count) / 16000)) s of audio")
            print("  talk seconds: " + talk.map { String(Int($0)) }.joined(separator: ", "))
            var out: [String: Any] = ["turns": split.turns.map { ["start": $0.start, "end": $0.end, "speaker": $0.speaker] },
                                      "speakers": split.voices.count, "seconds": seconds]
            if let v = option("--voice") {
                let mine = try await RoomSpeakers.split(try AudioConverter().resampleAudioFile(URL(fileURLWithPath: v)), config: config)
                var own = [Double](repeating: 0, count: mine.voices.count)
                for t in mine.turns { own[t.speaker] += t.end - t.start }
                let main = own.indices.max { own[$0] < own[$1] } ?? 0
                let sims = split.voices.map { RoomSpeakers.cosine($0, mine.voices.isEmpty ? [] : mine.voices[main]) }
                print("  voice sample: \(mine.voices.count) speakers found in it; similarity to each: " + sims.map { String(format: "%.3f", $0) }.joined(separator: ", "))
                out["voice"] = sims
            }
            let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted])
            try data.write(to: URL(fileURLWithPath: args[1]))
            return 0
        } catch {
            print("diarize-test failed: \(error.localizedDescription)")
            return 1
        }
    }

    /// `--summary-test notes.md out.md [--better claude|chatgpt|gemini|cursor|mac | --better command --command "..."] [--no-apple]`
    /// (D-956, D-1012): the summary on an existing notes
    /// file's transcript, without transcribing again. Writes the notes with the summary to `out.md`, and the
    /// models' own answers before the check beside it (`out.apple-raw.md`, `out.<helper>-raw.md`), then prints
    /// what the check did. The better summary is sent only when `--better` is given.
    static func summary(_ args: [String]) async -> Int32 {
        guard args.count >= 2, let text = try? String(contentsOfFile: args[0], encoding: .utf8) else { print("usage: --summary-test notes.md out.md [--better claude]"); return 2 }
        let out = URL(fileURLWithPath: args[1])
        let said = Meeting.transcript(inFile: text).components(separatedBy: "\n").filter { $0.hasPrefix("[") }.joined(separator: "\n")
        func report(_ who: String, _ c: Meeting.Checked?, _ raw: Meeting.Summary?, seconds: Double) {
            guard let c, let raw else { print("\(who): no summary"); return }
            let s = c.summary
            print("""
              \(who): \(String(format: "%.1f", seconds)) s
                written: \(raw.points.count) points, \(raw.decisions.count) decisions, \(raw.todos.count) to-dos
                kept: \(s.points.count) points, \(s.decisions.count) decisions, \(s.todos.count) to-dos
                check: uncited \(c.uncited), time moved \(c.moved), left out \(c.dropped), not tasks \(c.notTasks)
            """)
            let rawFile = out.deletingPathExtension().appendingPathExtension("\(who)-raw.md")
            try? Meeting.summaryMarkdown(Meeting.Checked(summary: raw), transcript: said).write(to: rawFile, atomically: true, encoding: .utf8)
        }
        print("summary-test")
        var t0 = Date()
        // `--no-apple`: the better summary alone, for testing a helper without waiting on Apple's model.
        var notes = text
        if !CommandLine.arguments.contains("--no-apple") {
            let free = await MeetingSummary.section(for: said) { _ in }
            report("apple", free.checked, free.raw, seconds: Date().timeIntervalSince(t0))
            if free.checked == nil { print("    \(free.note)") }
            notes = Meeting.placing(free.text, in: text)
        }
        do {
            if !FileManager.default.fileExists(atPath: out.path) { FileManager.default.createFile(atPath: out.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            try MeetingNotes.savePrivately(notes, to: out)
        } catch { print("can't write \(out.path)"); return 1 }
        if let b = CommandLine.arguments.firstIndex(of: "--better"), b + 1 < CommandLine.arguments.count {
            let helper = CommandLine.arguments[b + 1]
            let command = CommandLine.arguments.firstIndex(of: "--command").flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
            t0 = Date()
            let r = BetterSummary.write(file: out, helper: helper, command: command)
            if r.ok { report(helper, r.checked, r.raw, seconds: Date().timeIntervalSince(t0)) } else { print("\(helper): \(r.message)") }
        }
        print("  file: \(out.path)")
        return 0
    }

    /// `--writer-test model-folder notes.md out.md` (D-1010): Better summary on this Mac from a writer's folder (Redpen's
    /// copy or Hugging Face's cache), on an existing notes file's transcript, with the same rules the CLI helpers get.
    /// Prints the load and write times, the prompt's tokens and the memory used; writes the checked summary to
    /// `out.md` and the writer's own answer beside it (`out.local-raw.md`). Given an answer file in place of the
    /// folder, it checks that answer instead (a writer's notes from elsewhere). Everything stays on this Mac.
    static func writer(_ args: [String]) async -> Int32 {
        guard args.count >= 3, let text = try? String(contentsOfFile: args[1], encoding: .utf8) else {
            print("usage: --writer-test model-folder|answer.md notes.md out.md"); return 2
        }
        let out = URL(fileURLWithPath: args[2])
        let said = Meeting.transcript(inFile: text).components(separatedBy: "\n").filter { $0.hasPrefix("[") }.joined(separator: "\n")
        let gb = { (b: Int) in String(format: "%.2f GB", Double(b) / 1_073_741_824) }
        var isFolder: ObjCBool = false
        FileManager.default.fileExists(atPath: args[0], isDirectory: &isFolder)
        print("writer-test")
        let answer: String
        if isFolder.boolValue {
            let before = footprint()
            do {
                let w = try await LocalNotes.write(prompt: BetterSummary.prompt, input: said, folder: URL(fileURLWithPath: args[0], isDirectory: true))
                let peak = footprint().peak
                // The system takes a moment to reclaim what the GPU held.
                try? await Task.sleep(for: .seconds(3))
                print("""
                  load: \(String(format: "%.1f", w.loadSeconds)) s
                  prompt: \(w.promptTokens) tokens
                  write: \(String(format: "%.1f", w.writeSeconds)) s: reading \(String(format: "%.1f", w.promptSeconds)) s, then \(w.tokens) tokens in \(String(format: "%.1f", w.answerSeconds)) s
                  memory: \(gb(before.now)) before, peak \(gb(peak)), \(gb(footprint().now)) after unloading (MLX: peak \(gb(Memory.peakMemory)), now \(gb(Memory.activeMemory)) active, \(gb(Memory.cacheMemory)) kept)
                """)
                answer = w.text
            } catch {
                print("  failed: \(error)")
                return 1
            }
            try? answer.write(to: out.deletingPathExtension().appendingPathExtension("local-raw.md"), atomically: true, encoding: .utf8)
        } else {
            guard let a = try? String(contentsOfFile: args[0], encoding: .utf8) else { print("  can't read the answer"); return 2 }
            answer = a
        }
        guard let parsed = Meeting.parse(written: answer) else { print("  answer not in the expected form"); return 1 }
        let c = Meeting.check(parsed, transcript: said)
        let s = c.summary
        print("""
          written: \(parsed.points.count) points, \(parsed.decisions.count) decisions, \(parsed.todos.count) to-dos
          kept: \(s.points.count) points, \(s.decisions.count) decisions, \(s.todos.count) to-dos
          check: uncited \(c.uncited), time moved \(c.moved), left out \(c.dropped), not tasks \(c.notTasks)
          file: \(out.path)
        """)
        try? Meeting.summaryMarkdown(c, transcript: said, label: Meeting.localLabel("the writer")).write(to: out, atomically: true, encoding: .utf8)
        return 0
    }

    /// `--writer-download-test` (D-1010), run with REDPEN_VOICE_DIR set to an empty test folder: Gemma's small files
    /// (settings and tokenizer, 32 MB, never the 5 GB model) downloaded into Redpen's models folder there, then each
    /// checked against its hash, a second run that downloads nothing, a damaged file fetched again, a cancel part way,
    /// and Remove. Prints PASS or FAIL for each.
    static func download() async -> Int32 {
        guard ProcessInfo.processInfo.environment["REDPEN_VOICE_DIR"] != nil else { print("set REDPEN_VOICE_DIR to an empty test folder"); return 2 }
        let w = LocalWriter.gemma, small = w.files.filter { !$0.name.hasSuffix(".safetensors") }
        let folder = LocalNotes.own(w)
        var failed = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") { print("\(ok ? "PASS" : "FAIL") \(name) \(detail)"); if !ok { failed += 1 } }
        final class Seen: @unchecked Sendable { var calls = 0; var last: Int64 = 0 }
        // 1. Everything small, from nothing.
        let seen = Seen()
        let t0 = Date()
        do { try await WriterFetch(writer: w, files: small, folder: folder).run { n in seen.calls += 1; seen.last = n } } catch { check("download", false, WriterFetch.code(error)) }
        let total = small.reduce(Int64(0)) { $0 + $1.size }
        check("download", small.allSatisfy { LocalWriter.matches($0, at: folder.appendingPathComponent($0.name)) },
              "\(LocalWriter.gb(total)) in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        check("download.progress", seen.calls > 0 && seen.last == total, "\(seen.calls) reports, last \(seen.last) of \(total)")
        check("download.inRedpensFolder", folder.path.hasPrefix(Transcriber.modelsDir.path + "/notes-writers/"))
        // 2. Again: every file is already there and matches, so nothing comes down.
        let again = Seen()
        let t1 = Date()
        try? await WriterFetch(writer: w, files: small, folder: folder).run { n in again.calls += 1; again.last = n }
        check("resume.downloadsNothing", again.last == total && Date().timeIntervalSince(t1) < 5, String(format: "%.1f s", Date().timeIntervalSince(t1)))
        // 3. A damaged file fails its hash and is fetched again.
        let tok = folder.appendingPathComponent("tokenizer_config.json")
        try? Data(repeating: 65, count: Int(small.first { $0.name == "tokenizer_config.json" }!.size)).write(to: tok)
        check("damaged.detected", !LocalWriter.matches(small.first { $0.name == "tokenizer_config.json" }!, at: tok))
        try? await WriterFetch(writer: w, files: small, folder: folder).run { _ in }
        check("damaged.fetchedAgain", LocalWriter.matches(small.first { $0.name == "tokenizer_config.json" }!, at: tok))
        // 4. Cancel part way through the 32 MB tokenizer.
        let big = small.filter { $0.name == "tokenizer.json" }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("tokenizer.json"))
        let f = WriterFetch(writer: w, files: big, folder: folder)
        let part = Seen()
        var cancelled = false
        do {
            try await f.run { n in part.last = n; if n > 0 { f.cancel() } }
        } catch { cancelled = (error as? WriterFetch.Failure) == .cancelled }
        check("cancel.stops", cancelled && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("tokenizer.json").path),
              "stopped at \(LocalWriter.gb(part.last)) of \(LocalWriter.gb(big[0].size))")
        // 5. Remove deletes Redpen's copy and the folders it leaves empty, and nothing in Hugging Face's cache.
        let hubBefore = (try? FileManager.default.contentsOfDirectory(atPath: LocalNotes.hub.path))?.count
        LocalNotes.removeOwn(w)
        check("remove.deletesCopy", !FileManager.default.fileExists(atPath: folder.path))
        check("remove.leavesNoEmptyFolders", !FileManager.default.fileExists(atPath: Transcriber.modelsDir.appendingPathComponent("notes-writers").path))
        check("remove.leavesHubCache", (try? FileManager.default.contentsOfDirectory(atPath: LocalNotes.hub.path))?.count == hubBefore)
        // 6. Never outside Redpen's models folder.
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("rv-d1010-keep-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        LocalNotes.removeOwn(at: outside)
        check("remove.refusesOutside", FileManager.default.fileExists(atPath: outside.path))
        try? FileManager.default.removeItem(at: outside)
        print("\(failed == 0 ? "all passed" : "\(failed) failed")")
        return failed == 0 ? 0 : 1
    }

    /// This process's memory now and at its highest, as Activity Monitor counts it (the physical footprint, which
    /// includes what the GPU holds), in bytes.
    static func footprint() -> (now: Int, peak: Int) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        guard r == KERN_SUCCESS else { return (0, 0) }
        return (Int(info.phys_footprint), Int(info.ledger_phys_footprint_peak))
    }

    /// The highest memory this process has used, in bytes.
    static func peakMemory() -> Int {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Int(u.ru_maxrss)
    }

    /// A file into a track writer, a tenth of a second at a time. Returns its seconds.
    private static func feed(_ url: URL, into w: TrackWriter, gain: Float = 1) throws -> Double {
        let f = try AVAudioFile(forReading: url)
        let step = AVAudioFrameCount(f.processingFormat.sampleRate / 10)
        while f.framePosition < f.length {
            guard let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: step) else { break }
            try f.read(into: b, frameCount: min(step, AVAudioFrameCount(f.length - f.framePosition)))
            if b.frameLength == 0 { break }
            if gain != 1, let d = b.floatChannelData {
                for c in 0..<Int(b.format.channelCount) { for i in 0..<Int(b.frameLength) { d[c][i] *= gain } }
            }
            // More than one channel: the first, as the mic path reads one channel.
            if f.processingFormat.channelCount > 1, let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: f.processingFormat.sampleRate, channels: 1, interleaved: false),
               let m = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: b.frameLength), let src = b.floatChannelData?[0] {
                m.frameLength = b.frameLength
                m.floatChannelData![0].update(from: src, count: Int(b.frameLength))
                w.write(m)
            } else { w.write(b) }
        }
        return Double(f.length) / f.processingFormat.sampleRate
    }

    private static func feedSilence(seconds: Double, into w: TrackWriter) -> Double {
        let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        var left = Int(seconds * 16000)
        while left > 0 {
            let n = min(1600, left)
            let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(n))!
            b.frameLength = AVAudioFrameCount(n)
            for i in 0..<n { b.floatChannelData![0][i] = 0 }
            w.write(b); left -= n
        }
        return seconds
    }
}
