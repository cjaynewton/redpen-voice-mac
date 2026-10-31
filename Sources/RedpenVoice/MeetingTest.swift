import AVFoundation
import Foundation
import VoiceCore

/// `--meeting-test me.wav others.wav out-folder [--engine whisper] [--no-summary]`: the whole after-stop pipeline on
/// two files, without a microphone or tap. Each file goes through the same track writer a meeting uses, 0.1 s at a
/// time, into a recording folder inside `out-folder`, then the notes are written there. `silent` as the first file
/// is a muted microphone as long as the other track; `echo` is the other track heard again by the microphone, a
/// little later and quieter, as on laptop speakers. Everything stays in `out-folder`.
enum MeetingTest {
    static func run(_ args: [String], engine: Transcriber, config base: Config, names: Names) async -> Int32 {
        guard args.count >= 3 else { print("usage: --meeting-test me.wav|silent others.wav out-folder"); return 2 }
        let out = URL(fileURLWithPath: args[2], isDirectory: true)
        var config = base
        if let e = CommandLine.arguments.firstIndex(of: "--engine"), e + 1 < CommandLine.arguments.count { config.engine = CommandLine.arguments[e + 1] }
        config.meetingsFolder = out.path
        config.keepMeetingAudio = true
        // Only the engine the notes use is loaded, so the memory figure is the meeting's own.
        config.draftMode = false; config.riskMarks = false
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
            // Feed both files as a recording would.
            let othersURL = URL(fileURLWithPath: args[1])
            let others = try TrackWriter(url: work.appendingPathComponent(MeetingManifest.othersFile))
            let othersSecs = try feed(othersURL, into: others)
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

    /// `--summary-test notes.md out.md [--better claude|chatgpt|gemini]` (D-956): the summary on an existing notes
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
        let free = await MeetingSummary.section(for: said) { _ in }
        report("apple", free.checked, free.raw, seconds: Date().timeIntervalSince(t0))
        if free.checked == nil { print("    \(free.note)") }
        do {
            if !FileManager.default.fileExists(atPath: out.path) { FileManager.default.createFile(atPath: out.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
            try MeetingNotes.savePrivately(Meeting.placing(free.text, in: text), to: out)
        } catch { print("can't write \(out.path)"); return 1 }
        if let b = CommandLine.arguments.firstIndex(of: "--better"), b + 1 < CommandLine.arguments.count {
            let helper = CommandLine.arguments[b + 1]
            t0 = Date()
            let r = BetterSummary.write(file: out, helper: helper)
            if r.ok { report(helper, r.checked, r.raw, seconds: Date().timeIntervalSince(t0)) } else { print("\(helper): \(r.message)") }
        }
        print("  file: \(out.path)")
        return 0
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
