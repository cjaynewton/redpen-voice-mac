import AVFoundation
import Foundation
import FoundationModels
import VoiceCore

/// After a meeting stops (D-951): both tracks written with the engine chosen in Settings, merged by time, saved as
/// Markdown in the meetings folder, the audio kept beside it, then a summary from Apple's on-device model added
/// below. The transcript is saved before anything that can fail later, and the recording's folder is removed only
/// once the notes and audio are safe, so a quit at any point can be finished on the next launch.
enum MeetingNotes {
    /// How much of a track is written at a time: a couple of minutes, cut in the quietest moment of the last ten
    /// seconds, so memory stays small however long the meeting ran and a dictation never waits long for Whisper.
    static let pieceSeconds = 120.0
    static let searchSeconds = 10.0
    /// Where unfinished meetings wait: one folder each, removed once their notes and audio are saved.
    static let workDir = Config.dir.appendingPathComponent("Meetings in progress", isDirectory: true)

    struct Result {
        let file: URL
        let seconds: Double
        let meLines: Int
        let othersLines: Int
        let echoDropped: Int
        let summary: String
    }

    static func save(_ m: MeetingManifest, in folder: URL) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        let url = folder.appendingPathComponent(MeetingManifest.file)
        try enc.encode(m).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func load(_ folder: URL) -> MeetingManifest? {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: folder.appendingPathComponent(MeetingManifest.file))).flatMap { try? dec.decode(MeetingManifest.self, from: $0) }
    }

    /// Meetings whose notes were never finished (a quit, a crash, a failure), oldest first. `except` is the one
    /// recording now.
    static func unfinished(except: URL? = nil) -> [URL] {
        let dir = workDir
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.standardizedFileURL != except?.standardizedFileURL && load($0) != nil }
            .sorted { (load($0)?.started ?? .distantPast) < (load($1)?.started ?? .distantPast) }
    }

    /// Seconds of audio a track holds.
    static func seconds(_ track: URL) -> Double {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: track.path)[.size] as? Int) ?? 0
        return Double(MeetingManifest.samples(bytes: bytes)) / Double(MeetingManifest.rate)
    }

    static func engineName(_ e: String) -> String {
        switch e {
        case "whisper": return "Whisper (Most accurate)"
        case "live": return "Parakeet (Instant)"
        case "transcription": return "Apple's general engine (Mac built-in)"
        default: return "Apple's dictation engine (Mac built-in)"
        }
    }

    /// Reads `count` samples from `offset` in a raw track, as floats.
    static func read(_ h: FileHandle, from offset: Int, count: Int) throws -> [Float] {
        try h.seek(toOffset: UInt64(offset * 2))
        guard let d = try h.read(upToCount: count * 2), !d.isEmpty else { return [] }
        return d.withUnsafeBytes { raw in raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 } }
    }

    /// One track as timed lines, in seconds from the meeting's start. `done` hears seconds finished.
    static func transcribe(_ track: URL, offset: Double, engine: Transcriber, config: Config, done: (Double) -> Void) async throws -> (lines: [MeetingSegment], peak: Float) {
        guard let h = try? FileHandle(forReadingFrom: track) else { return ([], 0) }
        defer { try? h.close() }
        let rate = MeetingManifest.rate
        let total = MeetingManifest.samples(bytes: Int((try? h.seekToEnd()) ?? 0))
        let piece = Int(pieceSeconds * Double(rate)), search = Int(searchSeconds * Double(rate))
        var at = 0, out: [MeetingSegment] = [], loudest: Float = 0
        while at < total {
            let chunk = try read(h, from: at, count: min(total - at, piece + search))
            guard !chunk.isEmpty else { break }
            let end = at + chunk.count >= total ? chunk.count : Meeting.cutPoint(chunk, target: piece, search: search)
            let audio = Array(chunk[0..<max(1, end)])
            // A stretch where nothing at all was heard (a muted mic, a silent call) is skipped: no engine time, and
            // nothing for Whisper to invent from silence.
            let peak = audio.map(abs).max() ?? 0
            loudest = max(loudest, peak)
            if peak >= 0.003 {
                let start = offset + Double(at) / Double(rate)
                let segs = try await engine.meetingSegments(audio, config: config)
                out += segs.map { MeetingSegment(start: $0.start + start, end: $0.end + start, text: $0.text) }
            }
            at += audio.count
            done(Double(audio.count) / Double(rate))
        }
        return (out, loudest)
    }

    /// A raw track to a small .m4a beside the notes (AAC, 32 kbit/s, about 14 MB an hour).
    static func exportAudio(_ track: URL, to out: URL) throws {
        let rate = Double(MeetingManifest.rate)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        try? FileManager.default.removeItem(at: out)
        do {
            let file = try AVAudioFile(forWriting: out, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let h = try FileHandle(forReadingFrom: track)
            defer { try? h.close() }
            let step = Int(rate) * 30
            var at = 0
            while true {
                let s = try read(h, from: at, count: step)
                if s.isEmpty { break }
                let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(s.count))!
                b.frameLength = AVAudioFrameCount(s.count)
                s.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: s.count) }
                try file.write(from: b)
                at += s.count
            }
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: out.path)
    }

    /// Writes the notes for one recorded meeting. `progress` hears 0 to 100 and a few words for the bar.
    static func write(_ work: URL, engine: Transcriber, config: Config, names: Names, summarize: Bool = true,
                      progress: @escaping @MainActor (Int, String) -> Void) async throws -> Result {
        guard var manifest = load(work) else { throw NSError(domain: "RedpenVoice", code: 22, userInfo: [NSLocalizedDescriptionKey: "The recording's notes file is missing"]) }
        let fm = FileManager.default
        let folder = config.meetingsDir
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let meTrack = work.appendingPathComponent(MeetingManifest.meFile), othersTrack = work.appendingPathComponent(MeetingManifest.othersFile)
        let meSecs = seconds(meTrack), othersSecs = seconds(othersTrack)
        let length = max(meSecs + (manifest.meOffset ?? 0), othersSecs + (manifest.othersOffset ?? 0), 0)
        let keepAudio = config.keepMeetingAudio ?? true

        // A notes file already saved by an earlier try is finished, never written twice.
        var file: URL, transcript: String, result: (me: Int, others: Int, echo: Int) = (0, 0, 0)
        if let saved = manifest.notesFile, fm.fileExists(atPath: saved) {
            file = URL(fileURLWithPath: saved)
            transcript = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            Log.note("meeting: notes already saved, finishing the audio and summary")
        } else {
            let total = max(1, meSecs + othersSecs)
            var heard = 0.0
            await progress(0, "Writing notes…")
            let tick: (Double) -> Void = { s in
                heard += s
                let pct = Int(heard / total * 80)
                Task { @MainActor in progress(pct, "Writing notes…") }
            }
            let t0 = Date()
            let (others, othersPeak) = try await transcribe(othersTrack, offset: manifest.othersOffset ?? 0, engine: engine, config: config, done: tick)
            let mine = try await transcribe(meTrack, offset: manifest.meOffset ?? 0, engine: engine, config: config, done: tick).lines
            let echo = Meeting.dropEcho(me: mine, others: others)
            let fix = { (s: MeetingSegment) in MeetingSegment(start: s.start, end: s.end, text: names.apply(s.text)) }
            let lines = Meeting.merge(me: echo.kept.map(fix), others: others.map(fix))
            Log.note("meeting: wrote \(Log.int(meSecs + othersSecs))s of audio in \(Log.int(Date().timeIntervalSince(t0)))s, me \(echo.kept.count) lines (\(echo.dropped) echo), others \(others.count) lines")
            result = (echo.kept.count, others.count, echo.dropped)
            let base = Meeting.uniqueBase(Meeting.baseName(manifest.started)) { b in
                ["", " Me", " Others"].contains { fm.fileExists(atPath: folder.appendingPathComponent(b + $0 + ($0.isEmpty ? ".md" : ".m4a")).path) }
            }
            file = folder.appendingPathComponent(base + ".md")
            let audio = keepAudio ? [base + " Me.m4a", base + " Others.m4a"] : []
            transcript = Meeting.markdown(start: manifest.started, seconds: length, lines: lines, audio: audio, echoDropped: echo.dropped,
                                          engine: engineName(config.engine), notes: othersPeak == 0 && othersSecs > 30 ? [Meeting.silentMacNote] : [])
            try transcript.write(to: file, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            manifest.notesFile = file.path
            try? save(manifest, in: work)
        }

        // The audio beside the notes (wherever they were saved, even if the folder setting changed since).
        await progress(82, "Saving the audio…")
        let base = file.deletingPathExtension().lastPathComponent, beside = file.deletingLastPathComponent()
        if keepAudio {
            do {
                try exportAudio(othersTrack, to: beside.appendingPathComponent(base + " Others.m4a"))
                try exportAudio(meTrack, to: beside.appendingPathComponent(base + " Me.m4a"))
            } catch {
                Log.note("meeting: audio not saved, \(error.localizedDescription); the raw tracks stay in the recording folder")
                throw error
            }
        }
        var summaryNote = "skipped"
        if summarize, !transcript.contains("\n## Summary\n") {
            await progress(85, "Writing the summary…")
            let said = transcript.components(separatedBy: "\n").filter { $0.hasPrefix("[") }.joined(separator: "\n")
            let section = await MeetingSummary.section(for: said) { p in Task { @MainActor in progress(85 + p * 14 / 100, "Writing the summary…") } }
            summaryNote = section.note
            if let h = try? FileHandle(forWritingTo: file) {
                h.seekToEndOfFile(); h.write(Data(("\n" + section.text).utf8)); try? h.close()
            }
        }
        // Only now does the recording's own folder go: a quit before this finishes the same notes next launch.
        try? fm.removeItem(at: work)
        await progress(100, "Notes saved")
        return Result(file: file, seconds: length, meLines: result.me, othersLines: result.others, echoDropped: result.echo, summary: summaryNote)
    }
}

/// The summary, from Apple's on-device model, never sent anywhere (D-951). Long meetings are summarised in pieces
/// that fit the model's window, then the pieces' notes are combined. Names come only from the transcript.
enum MeetingSummary {
    @Generable
    struct Notes {
        @Guide(description: "The most important points discussed, each one short sentence.", .maximumCount(8))
        var points: [String]
        @Guide(description: "Decisions the people on the call agreed on, each one short sentence. Empty when none were made.", .maximumCount(6))
        var decisions: [String]
        @Guide(description: "Things someone said they would do. Empty when nobody said they would do anything.", .maximumCount(10))
        var todos: [ToDo]
    }

    @Generable
    struct ToDo {
        @Guide(description: "Who said they would do it: Me, Others, or a name that is said in the transcript.")
        var who: String
        @Guide(description: "What they said they would do, one short sentence.")
        var task: String
    }

    static let instructions = """
    You write meeting notes from a transcript. Each line starts with a time and a speaker. "Me" is the person taking \
    the notes. "Others" is everyone else on the call. Use only what is in the transcript. Never invent names: write \
    Me or Others unless a person's name is said in the transcript. A to-do belongs to Me only when a line marked Me \
    says they will do it. List only things someone clearly said they would do. Do not add advice or opinions.
    """

    static let combineInstructions = """
    You combine notes from parts of one meeting into one set. Merge repeated items, keep the most important, and keep \
    who said they would do each thing exactly as written. Never invent names or anything not in the notes.
    """

    /// Why there is no summary, in plain words, or nil when the model can run.
    static var unavailable: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence is off on this Mac. Turn it on in System Settings to get summaries."
        case .unavailable(.deviceNotEligible): return "This Mac can't run Apple's on-device model."
        case .unavailable(.modelNotReady): return "Apple's on-device model is still downloading."
        default: return "Apple's on-device model isn't available right now."
        }
    }

    /// The section to add below the transcript, and a note for the log and the test.
    static func section(for transcript: String, progress: @escaping (Int) -> Void) async -> (text: String, note: String) {
        if let why = unavailable { return (Meeting.noSummary(why), "unavailable") }
        let lines = transcript.components(separatedBy: "\n").filter { $0.hasPrefix("[") }
        guard !lines.isEmpty else { return (Meeting.noSummary("Nothing was heard to summarise."), "empty") }
        // Room for the transcript in the model's window: about three characters a token, after the instructions, the
        // shape of the answer and the answer itself.
        var budget = max(2000, (SystemLanguageModel.default.contextSize - 1500) * 3)
        let t0 = Date()
        for attempt in 1...3 {
            do {
                let parts = Meeting.pieces(lines, maxChars: budget)
                var notes: [Notes] = []
                for (i, p) in parts.enumerated() {
                    notes.append(try await summarise(p))
                    progress((i + 1) * 80 / parts.count)
                }
                let one = try await combine(notes, budget: budget)
                progress(100)
                let s = Meeting.Summary(points: one.points, decisions: one.decisions, todos: one.todos.map { Meeting.ToDo(who: $0.who, task: $0.task) })
                Log.note("meeting: summary from \(parts.count) pieces in \(Log.int(Date().timeIntervalSince(t0)))s, \(s.points.count) points, \(s.decisions.count) decisions, \(s.todos.count) to-dos")
                return (Meeting.summaryMarkdown(s, transcript: transcript), "\(parts.count) pieces")
            } catch {
                let text = "\(error)"
                // Too long for the window: smaller pieces. Anything else (the model declined, a failure) ends it.
                if text.localizedCaseInsensitiveContains("context"), attempt < 3 {
                    budget /= 2; Log.note("meeting: summary piece too long, trying pieces of \(budget) characters"); continue
                }
                Log.note("meeting: summary failed (\(type(of: error)))")
                if text.localizedCaseInsensitiveContains("guardrail") { return (Meeting.noSummary("Apple's model declined to summarise this meeting."), "declined") }
                return (Meeting.noSummary("Apple's model couldn't summarise this meeting."), "failed")
            }
        }
        return (Meeting.noSummary("The meeting was too long for Apple's model."), "too long")
    }

    private static func summarise(_ piece: String) async throws -> Notes {
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(to: "Transcript:\n" + piece, generating: Notes.self, options: GenerationOptions(temperature: 0)).content
    }

    /// One set of notes from many, combined a few at a time until one is left.
    private static func combine(_ notes: [Notes], budget: Int) async throws -> Notes {
        var level = notes
        while level.count > 1 {
            let texts = level.map(render)
            var groups: [[String]] = [[]], size = 0
            for t in texts {
                if size + t.count > budget, !(groups.last?.isEmpty ?? true) { groups.append([]); size = 0 }
                groups[groups.count - 1].append(t); size += t.count
            }
            // Never stuck: when nothing could be grouped, pairs are combined.
            if groups.count == level.count { groups = stride(from: 0, to: texts.count, by: 2).map { Array(texts[$0..<min($0 + 2, texts.count)]) } }
            var next: [Notes] = []
            for g in groups {
                if g.count == 1, let i = texts.firstIndex(of: g[0]) { next.append(level[i]); continue }
                let session = LanguageModelSession(instructions: combineInstructions)
                let prompt = g.enumerated().map { "Part \($0.offset + 1):\n\($0.element)" }.joined(separator: "\n\n")
                next.append(try await session.respond(to: prompt, generating: Notes.self, options: GenerationOptions(temperature: 0)).content)
            }
            level = next
        }
        return level.first ?? Notes(points: [], decisions: [], todos: [])
    }

    private static func render(_ n: Notes) -> String {
        var s = "Key points:\n" + n.points.map { "- \($0)" }.joined(separator: "\n")
        s += "\nDecisions:\n" + n.decisions.map { "- \($0)" }.joined(separator: "\n")
        s += "\nTo-dos:\n" + n.todos.map { "- \($0.who): \($0.task)" }.joined(separator: "\n")
        return s
    }
}
