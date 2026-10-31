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

    /// An error for the log: its kind and number only. macOS's own wording can name the meeting's file or folder.
    static func code(_ e: Error) -> String { let n = e as NSError; return "\(n.domain) \(n.code)" }

    /// Replaces a notes file with `text`, readable only by this account from the first byte.
    static func savePrivately(_ text: String, to file: URL) throws {
        let fm = FileManager.default
        let tmp = file.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).md")
        guard fm.createFile(atPath: tmp.path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do { _ = try fm.replaceItemAt(file, withItemAt: tmp) } catch { try? fm.removeItem(at: tmp); throw error }
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
            // The tap delivers nothing at all while the Mac is quiet, so a silent meeting can leave no Others audio:
            // the note goes by the meeting's length, not the track's.
            let (others, othersPeak) = try await transcribe(othersTrack, offset: manifest.othersOffset ?? 0, engine: engine, config: config, done: tick)
            let mine = try await transcribe(meTrack, offset: manifest.meOffset ?? 0, engine: engine, config: config, done: tick).lines
            let echo = Meeting.dropEcho(me: mine, others: others)
            let fix = { (s: MeetingSegment) in MeetingSegment(start: s.start, end: s.end, text: names.apply(s.text)) }
            // Whisper's own repeats out, then one paragraph per turn, so it reads like people talking.
            // Pauses marked where they began; anything written inside one (silence) goes.
            let pauses = (manifest.pauses ?? MeetingPauses()).all(closingAt: length)
            let lines = Meeting.withPauses(Meeting.paragraphs(Meeting.dropRepeats(Meeting.merge(me: echo.kept.map(fix), others: others.map(fix)))), pauses)
            Log.note("meeting: wrote \(Log.int(meSecs + othersSecs))s of audio in \(Log.int(Date().timeIntervalSince(t0)))s, me \(echo.kept.count) lines (\(echo.dropped) echo), others \(others.count) lines")
            result = (echo.kept.count, others.count, echo.dropped)
            let base = Meeting.uniqueBase(Meeting.baseName(manifest.started)) { b in
                ["", " Me", " Others"].contains { fm.fileExists(atPath: folder.appendingPathComponent(b + $0 + ($0.isEmpty ? ".md" : ".m4a")).path) }
            }
            file = folder.appendingPathComponent(base + ".md")
            let audio = keepAudio ? [base + " Me.m4a", base + " Others.m4a"] : []
            transcript = Meeting.markdown(start: manifest.started, seconds: length, lines: lines, audio: audio, echoDropped: echo.dropped,
                                          engine: engineName(config.engine), notes: othersPeak == 0 && length > 15 ? [Meeting.silentMacNote] : [],
                                          paused: pauses.reduce(0) { $0 + $1.seconds })
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
                Log.note("meeting: audio not saved, \(code(error)); the raw tracks stay in the recording folder")
                throw error
            }
        }
        var summaryNote = "skipped"
        if summarize, !transcript.contains("\n## Summary\n") {
            await progress(85, "Writing the summary…")
            let said = Meeting.transcript(inFile: transcript).components(separatedBy: "\n").filter { $0.hasPrefix("[") }.joined(separator: "\n")
            let section = await MeetingSummary.section(for: said) { p in Task { @MainActor in progress(85 + p * 14 / 100, "Writing the summary…") } }
            summaryNote = section.note
            // Above the transcript, where it's read first (D-956); the transcript was saved on its own already.
            if let now = try? String(contentsOf: file, encoding: .utf8) {
                do { try savePrivately(Meeting.placing(section.text, in: now), to: file) }
                catch { Log.note("meeting: summary not saved, \(code(error))") }
            }
        }
        // Only now does the recording's own folder go: a quit before this finishes the same notes next launch.
        try? fm.removeItem(at: work)
        await progress(100, "Notes saved")
        return Result(file: file, seconds: length, meLines: result.me, othersLines: result.others, echoDropped: result.echo, summary: summaryNote)
    }
}

/// The summary, from Apple's on-device model, never sent anywhere (D-951, D-956). Long meetings are summarised in
/// pieces that fit the model's window, then the pieces' notes are combined. Each item carries the time of the line
/// that says it, and `Meeting.check` keeps only the items the transcript backs.
enum MeetingSummary {
    @Generable
    struct Item {
        @Guide(description: "One short sentence, in plain words, saying only what was said.")
        var text: String
        @Guide(description: "The time at the start of the transcript line that says it, exactly as written there, like 12:34.")
        var time: String
    }

    @Generable
    struct ToDo {
        @Guide(description: "Who will do it: Me, Others, or a name that is said in the transcript.")
        var who: String
        @Guide(description: "What they will do, one short sentence.")
        var task: String
        @Guide(description: "The time at the start of the transcript line where it was said, exactly as written there, like 12:34.")
        var time: String
    }

    @Generable
    struct Notes {
        @Guide(description: "Two or three plain sentences on what the meeting was about and where it ended up.")
        var overview: String
        @Guide(description: "The most important things said. Keep numbers, dates, amounts and goals exactly as said.", .maximumCount(8))
        var points: [Item]
        @Guide(description: "Things the people on the call agreed on. Empty when nothing was agreed.", .maximumCount(6))
        var decisions: [Item]
        @Guide(description: "Only things someone said they will do, or asked someone to do. Empty when there are none.", .maximumCount(10))
        var todos: [ToDo]
    }

    static let instructions = """
    You write meeting notes from a transcript. Each line starts with its time in brackets and a speaker. "Me" is the \
    person taking the notes. "Others" is everyone else on the call.
    Rules:
    - Use only what was said. Infer nothing. If you are not sure, leave it out.
    - Keep numbers, dates, amounts and goals exactly as they were said.
    - Give every point, decision and to-do the time of the transcript line that says it.
    - A decision is something the people on the call agreed on.
    - A to-do is only a commitment or an ask: someone says they will do something ("I'll", "we'll", "I'm going to") \
    or asks someone to ("can you", "could you", "let's have Sam do"). Greetings, thanks and goodbyes are never to-dos.
    - Never invent names. Write Me or Others unless a person's name is said in the transcript. A to-do belongs to Me \
    only when a line marked Me says they will do it.
    - Leave out small talk: greetings, health, weather, thanks and goodbyes.
    - Empty lists are fine. Do not add advice or opinions.
    """

    static let overviewInstructions = """
    You write the overview of one meeting from the overviews of its parts, in order. Two or three plain sentences on \
    what the meeting was about and where it ended up. Use only what the parts say. Keep numbers and dates exactly.
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

    /// The section to put above the transcript, a note for the log and the test, and the check's counts.
    /// Each piece of the transcript gets its own notes; a piece too long for the model's window is split in two and
    /// tried again. The pieces' items are merged in code, in turn from each piece, so every part of the meeting is
    /// heard; only the overview is combined by the model.
    static func section(for transcript: String, progress: @escaping (Int) -> Void) async -> (text: String, note: String, checked: Meeting.Checked?, raw: Meeting.Summary?) {
        if let why = unavailable { return (Meeting.noSummary(why), "unavailable", nil, nil) }
        let lines = transcript.components(separatedBy: "\n").filter { $0.hasPrefix("[") }
        guard !lines.isEmpty else { return (Meeting.noSummary("Nothing was heard to summarise."), "empty", nil, nil) }
        // With a silent microphone every line is Others; the model is told, so it never writes Me.
        let noMe = !lines.contains { $0.contains("] Me: ") }
        // Room for the transcript in the model's window: about two and a half characters a token, after the
        // instructions, the shape of the answer and the answer itself.
        let budget = max(2000, (SystemLanguageModel.default.contextSize - 1800) * 5 / 2)
        let t0 = Date()
        do {
            let parts = Meeting.pieces(lines, maxChars: budget)
            var notes: [Notes] = []
            for (i, p) in parts.enumerated() {
                notes += try await fitting(p.components(separatedBy: "\n"), noMe: noMe)
                progress((i + 1) * 90 / parts.count)
            }
            let raw: Meeting.Summary
            if notes.count == 1 {
                raw = summary(notes[0])
            } else {
                let overview = try await respond(overviewInstructions, notes.enumerated().map { "Part \($0.offset + 1): \($0.element.overview)" }.joined(separator: "\n"))
                raw = Meeting.merge(notes.map(summary), overview: plain(overview))
            }
            progress(100)
            let checked = Meeting.check(raw, transcript: transcript)
            let s = checked.summary
            Log.note("meeting: summary from \(notes.count) pieces in \(Log.int(Date().timeIntervalSince(t0)))s, \(s.points.count) points, \(s.decisions.count) decisions, \(s.todos.count) to-dos; check moved \(checked.moved), left out \(checked.dropped), not tasks \(checked.notTasks), uncited \(checked.uncited)")
            return (Meeting.summaryMarkdown(checked, transcript: transcript), "\(notes.count) pieces", checked, raw)
        } catch {
            let text = "\(error)"
            if CommandLine.arguments.contains("--summary-test") { print("    model error: \(error)") }
            Log.note("meeting: summary failed (\(type(of: error)), \(MeetingNotes.code(error)))")
            if text.localizedCaseInsensitiveContains("guardrail") { return (Meeting.noSummary("Apple's model declined to summarise this meeting."), "declined", nil, nil) }
            return (Meeting.noSummary("Apple's model couldn't summarise this meeting."), "failed, \(MeetingNotes.code(error))", nil, nil)
        }
    }

    /// Notes for these lines, split in two (and again) while they are too long for the model's window.
    private static func fitting(_ lines: [String], noMe: Bool) async throws -> [Notes] {
        do {
            return [try await summarise(lines.joined(separator: "\n"), noMe: noMe)]
        } catch where "\(error)".localizedCaseInsensitiveContains("context") && lines.count > 1 {
            Log.note("meeting: summary piece too long, splitting it")
            let half = lines.count / 2
            return try await fitting(Array(lines[..<half]), noMe: noMe) + fitting(Array(lines[half...]), noMe: noMe)
        }
    }

    /// Apple's model sometimes heads its overview "**Meeting Overview**"; that line goes, and the rest is one paragraph.
    static func plain(_ overview: String) -> String {
        overview.components(separatedBy: "\n").filter { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            return !(t.hasPrefix("**") && t.hasSuffix("**") && t.split(separator: " ").count <= 4) && !t.hasPrefix("#")
        }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func summary(_ n: Notes) -> Meeting.Summary {
        Meeting.Summary(overview: plain(n.overview),
                        points: n.points.map { Meeting.Cited($0.text, at: Meeting.seconds($0.time)) },
                        decisions: n.decisions.map { Meeting.Cited($0.text, at: Meeting.seconds($0.time)) },
                        todos: n.todos.map { Meeting.ToDo(who: $0.who, task: $0.task, at: Meeting.seconds($0.time)) })
    }

    private static func summarise(_ piece: String, noMe: Bool) async throws -> Notes {
        let note = noMe ? "Every line here is Others: the person taking the notes said nothing on their microphone. Never write Me.\n\n" : ""
        return try await once {
            let session = LanguageModelSession(instructions: instructions)
            return try await session.respond(to: note + "Transcript:\n" + piece, generating: Notes.self, options: GenerationOptions(temperature: 0)).content
        }
    }

    private static func respond(_ instructions: String, _ prompt: String) async throws -> String {
        try await once {
            let session = LanguageModelSession(instructions: instructions)
            return try await session.respond(to: prompt, options: GenerationOptions(temperature: 0)).content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The model's manager sometimes refuses a request outright (ModelManagerError 1001, seen on the bench and gone
    /// on a retry): one more try after a short wait.
    private static func once<T>(_ work: () async throws -> T) async throws -> T {
        do { return try await work() } catch where "\(error)".contains("ModelManager") {
            Log.note("meeting: summary model busy, trying again")
            try await Task.sleep(for: .seconds(15))
            return try await work()
        }
    }
}
