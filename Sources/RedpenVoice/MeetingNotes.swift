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
        /// Claude was chosen but didn't write the notes: its plain reason, for the bar (D-1272). Nil otherwise.
        var claudeFailed: String? = nil
        /// Claude wrote the notes.
        var byClaude = false
        /// Notes of some kind were written (Claude's or Apple's), not only a line saying why there are none.
        var wrote = false
    }

    /// Who writes the notes after a meeting (D-1272): the user's own Claude account once they said yes, else Apple's
    /// model on this Mac.
    enum Writer: String { case apple, claude }

    /// Puts notes above the transcript of a saved notes file: Claude's when chosen, with Apple's as the labelled
    /// backup when Claude fails or times out, never notes that look real but aren't (D-1272). Returns a word for the
    /// log and the test, and Claude's reason when it was chosen and didn't write them.
    static func summarize(_ file: URL, writer: Writer, progress: @escaping (Int, String) -> Void) async -> (note: String, claudeFailed: String?, wrote: Bool) {
        var label = Meeting.summaryLabel, claudeFailed: String?
        if writer == .claude {
            progress(85, "Writing the notes with Claude…")
            let r = await Task.detached { BetterSummary.write(file: file, helper: "claude") }.value
            if r.ok { return ("claude", nil, true) }
            // Better summary's own "Your notes are unchanged" isn't true here: basic notes are being written now.
            claudeFailed = r.message.replacingOccurrences(of: " Your notes are unchanged.", with: "")
            label = Meeting.fallbackLabel(claudeFailed ?? "")
            Log.note("meeting: Claude didn't write the notes, Apple's basic notes instead")
        }
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return ("unreadable", claudeFailed, false) }
        progress(85, "Writing basic notes…")
        let said = Meeting.transcript(inFile: text).components(separatedBy: "\n").filter { $0.hasPrefix("[") }.joined(separator: "\n")
        let section = await MeetingSummary.section(for: said, label: label) { p in progress(85 + p * 14 / 100, "Writing basic notes…") }
        // Read again: the file may have changed while the model worked.
        if let now = try? String(contentsOf: file, encoding: .utf8) {
            do { try savePrivately(Meeting.placing(section.text, in: now), to: file) }
            catch { Log.note("meeting: summary not saved, \(code(error))") }
        }
        return (section.note, claudeFailed, section.checked != nil)
    }

    /// An error for the log: its kind and number only. macOS's own wording can name the meeting's file or folder.
    static func code(_ e: Error) -> String { let n = e as NSError; return "\(n.domain) \(n.code)" }

    /// Replaces a notes file with `text`, readable only by this account from the first byte.
    static func savePrivately(_ text: String, to file: URL) throws {
        do { try MeetingFiles.save(Data(text.utf8), to: file) }
        catch { Log.note("meeting: private notes save failed, \(code(error))"); throw error }
    }

    static func privateFolder(_ folder: URL) throws {
        do { try MeetingFiles.createFolder(folder) }
        catch { Log.note("meeting: private folder failed, \(code(error))"); throw error }
    }

    static func save(_ m: MeetingManifest, in folder: URL) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        do { try MeetingFiles.save(enc.encode(m), to: folder.appendingPathComponent(MeetingManifest.file)) }
        catch { Log.note("meeting: private manifest save failed, \(code(error))"); throw error }
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
    static func transcribe(_ track: URL, offset: Double, engine: Transcriber, config: Config, limit: Double? = nil, done: (Double) -> Void) async throws -> (lines: [MeetingSegment], peak: Float) {
        guard let h = try? FileHandle(forReadingFrom: track) else { return ([], 0) }
        defer { try? h.close() }
        let rate = MeetingManifest.rate
        let saved = MeetingManifest.samples(bytes: Int((try? h.seekToEnd()) ?? 0))
        let total = limit.map { min(saved, max(0, Int($0 * Double(rate)))) } ?? saved
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
    static func exportAudio(_ track: URL, to out: URL, offset: Double = 0, limit: Double? = nil) throws {
        let rate = Double(MeetingManifest.rate)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let scratch: URL
        do { scratch = try MeetingFiles.scratch(in: out.deletingLastPathComponent()) }
        catch { Log.note("meeting: private audio folder failed, \(code(error))"); throw error }
        defer { try? FileManager.default.removeItem(at: scratch) }
        let temp = scratch.appendingPathComponent("audio.m4a")
        do {
            let file = try AVAudioFile(forWriting: temp, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let h = try FileHandle(forReadingFrom: track)
            defer { try? h.close() }
            let step = Int(rate) * 30
            guard offset.isFinite, abs(offset * rate) < Double(Int.max) else { throw CocoaError(.fileReadCorruptFile) }
            let shift = Int((offset * rate).rounded())
            func append(_ samples: [Float]) throws {
                let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(samples.count))!
                b.frameLength = AVAudioFrameCount(samples.count)
                samples.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
                try file.write(from: b)
            }
            // Export on the meeting clock: delayed tracks begin with silence; microphone pre-roll is removed.
            var padding = max(0, shift)
            while padding > 0 {
                let n = min(padding, step)
                try append([Float](repeating: 0, count: n)); padding -= n
            }
            var at = max(0, -shift)
            let total = limit.map { max(0, Int($0 * rate)) } ?? Int.max
            while at < total {
                let s = try read(h, from: at, count: min(step, total - at))
                if s.isEmpty { break }
                try append(s)
                at += s.count
            }
        }
        do { try MeetingFiles.place(temp, at: out) }
        catch { Log.note("meeting: private audio save failed, \(code(error))"); throw error }
    }

    /// Writes the notes for one recorded meeting. `progress` hears 0 to 100 and a few words for the bar.
    /// `writer` is asked only once the transcript is saved, so a question about it never holds up the transcript.
    static func write(_ work: URL, engine: Transcriber, config: Config, names: Names, summarize: Bool = true,
                      writer: @escaping () async -> Writer = { .apple },
                      progress: @escaping @MainActor (Int, String) -> Void) async throws -> Result {
        guard var manifest = load(work) else { throw NSError(domain: "RedpenVoice", code: 22, userInfo: [NSLocalizedDescriptionKey: "The recording's notes file is missing"]) }
        let fm = FileManager.default
        let folder = config.meetingsDir
        try privateFolder(folder)
        let meTrack = work.appendingPathComponent(MeetingManifest.meFile), othersTrack = work.appendingPathComponent(MeetingManifest.othersFile)
        let cutoff = manifest.savingStopped.map { max(0, $0.timeIntervalSince(manifest.started)) }
        let meLimit = cutoff.map { max(0, $0 - (manifest.meOffset ?? 0)) }
        let othersLimit = cutoff.map { max(0, $0 - (manifest.othersOffset ?? 0)) }
        let meSecs = min(seconds(meTrack), meLimit ?? .infinity), othersSecs = min(seconds(othersTrack), othersLimit ?? .infinity)
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
            let (others, othersPeak) = try await transcribe(othersTrack, offset: manifest.othersOffset ?? 0, engine: engine, config: config, limit: othersLimit, done: tick)
            let mine = try await transcribe(meTrack, offset: manifest.meOffset ?? 0, engine: engine, config: config, limit: meLimit, done: tick).lines
            let echo = Meeting.dropEcho(me: mine, others: others)
            // Voices in the room (D-1034): the microphone's lines told apart by voice, on this Mac, when chosen, the
            // models are here, and the Mac played nothing, so it was a meeting in one room. On a call through the
            // speakers the microphone hears the others too, and its own lines must stay Me. Any failure leaves them
            // all Me, as before.
            var room: (voices: [Speaker], names: [Speaker])? = nil
            if config.roomVoices == true, !echo.kept.isEmpty, others.isEmpty {
                await progress(80, "Telling voices apart…")
                room = await RoomSpeakers.label(track: meTrack, rate: MeetingManifest.rate, offset: manifest.meOffset ?? 0,
                                                lines: echo.kept, knowMe: config.knowMyVoice == true)
            }
            let fix = { (s: MeetingSegment) in MeetingSegment(start: s.start, end: s.end, text: names.apply(s.text)) }
            // Whisper's own repeats out, then one paragraph per turn, so it reads like people talking.
            // Pauses marked where they began; anything written inside one (silence) goes.
            let pauses = (manifest.pauses ?? MeetingPauses()).all(closingAt: length)
            let lines = Meeting.withPauses(Meeting.paragraphs(Meeting.dropRepeats(Meeting.merge(me: echo.kept.map(fix), others: others.map(fix), voices: room?.voices))), pauses)
            Log.note("meeting: wrote \(Log.int(meSecs + othersSecs))s of audio in \(Log.int(Date().timeIntervalSince(t0)))s, me \(echo.kept.count) lines (\(echo.dropped) echo), others \(others.count) lines")
            result = (echo.kept.count, others.count, echo.dropped)
            let base = Meeting.uniqueBase(Meeting.baseName(manifest.started)) { b in
                ["", " Me", " Others"].contains { fm.fileExists(atPath: folder.appendingPathComponent(b + $0 + ($0.isEmpty ? ".md" : ".m4a")).path) }
            }
            file = folder.appendingPathComponent(base + ".md")
            let audio = keepAudio ? [base + " Me.m4a", base + " Others.m4a"] : []
            transcript = Meeting.markdown(start: manifest.started, seconds: length, lines: lines, audio: audio, echoDropped: echo.dropped,
                                          // In one room the Mac playing nothing is expected, so the warning is softer then.
                                          engine: engineName(config.engine),
                                          notes: (manifest.savingStopped.map { [Meeting.savingNote(at: max(0, $0.timeIntervalSince(manifest.started)))] } ?? [])
                                            + (othersPeak == 0 && length > 15 ? [(room?.names.count ?? 0) >= 2 ? Meeting.roomSilentNote : Meeting.silentMacNote] : []),
                                          paused: pauses.reduce(0) { $0 + $1.seconds }, room: room?.names ?? [])
            try savePrivately(transcript, to: file)
            manifest.notesFile = file.path
            try? save(manifest, in: work)
        }

        // The audio beside the notes (wherever they were saved, even if the folder setting changed since).
        await progress(82, "Saving the audio…")
        let base = file.deletingPathExtension().lastPathComponent, beside = file.deletingLastPathComponent()
        if keepAudio {
            do {
                try exportAudio(othersTrack, to: beside.appendingPathComponent(base + " Others.m4a"), offset: manifest.othersOffset ?? 0, limit: othersLimit)
                try exportAudio(meTrack, to: beside.appendingPathComponent(base + " Me.m4a"), offset: manifest.meOffset ?? 0, limit: meLimit)
            } catch {
                Log.note("meeting: audio not saved, \(code(error)); the raw tracks stay in the recording folder")
                throw error
            }
        }
        var summaryNote = "skipped", claudeFailed: String?, wrote = false
        if summarize, !transcript.contains("\n## Summary\n") {
            // Above the transcript, where it's read first (D-956); the transcript was saved on its own already.
            let who = await writer()
            let r = await Self.summarize(file, writer: who) { p, w in Task { @MainActor in progress(p, w) } }
            summaryNote = r.note; claudeFailed = r.claudeFailed; wrote = r.wrote
        }
        // Only now does the recording's own folder go: a quit before this finishes the same notes next launch.
        try? fm.removeItem(at: work)
        await progress(100, "Notes saved")
        return Result(file: file, seconds: length, meLines: result.me, othersLines: result.others, echoDropped: result.echo, summary: summaryNote,
                      claudeFailed: claudeFailed, byClaude: summaryNote == "claude", wrote: wrote)
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
        @Guide(description: "Who will do it: Me, Others, a speaker as the transcript marks it (Person 2), or a name that is said in the transcript.")
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
        @Guide(description: "Questions asked or problems raised that nobody settled by the end. Empty when everything was settled.", .maximumCount(6))
        var open: [Item]
    }

    static let instructions = """
    You write meeting notes from a transcript. Each line starts with its time in brackets and a speaker. "Me" is the \
    person taking the notes. "Others" is everyone else on the call. "Person 2", "Person 3" (or a name in that place) \
    are other people in the room, told apart by voice.
    Rules:
    - Use only what was said. Infer nothing. If you are not sure, leave it out.
    - Keep numbers, dates, amounts and goals exactly as they were said.
    - Give every point, decision and to-do the time of the transcript line that says it.
    - A decision is a plan or choice someone states that the others accept or don't push back on ("Okay, that's \
    fine", "Excellent"), or a plan the person responsible commits to for their own work ("we'll make some \
    assumptions and caveat them"). Leave out only a suggestion or one person's view that nobody took up. An agreed \
    date or plan that is also a to-do belongs in Decisions too.
    - A to-do is only a commitment or an ask: someone says they will do something ("I'll", "we'll", "I'm going to") \
    or asks someone to ("can you", "could you", "let's have Sam do"). Greetings, thanks and goodbyes are never to-dos.
    - Name a person, as an owner or as the one who said something, only when the transcript makes it unambiguous: \
    they say it about themselves on a line marked with their name, or someone speaks to them by name in that same \
    exchange. Otherwise write Others for anyone on the Others lines and Me for the Me lines, or Not clear for a to-do \
    nobody took on. Never work out a name from the topic, a role, or who usually does what.
    - A to-do belongs to a speaker only when a line marked with that speaker says they will do it.
    - "We can look into X" or "there are other options" with nobody taking it on is not a to-do: leave it out, or \
    put it in Still open.
    - Give a to-do a deadline only when one was said for that task. Never add a deadline, day or time that nobody \
    said, or one that was said about something else.
    - Copy money, numbers and percentages exactly as they were said. Never round them, merge two of them, or finish a \
    number that was cut off.
    - Still open is a question asked or a problem raised that nobody settled by the end.
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
    static func section(for transcript: String, label: String = Meeting.summaryLabel, progress: @escaping (Int) -> Void) async -> (text: String, note: String, checked: Meeting.Checked?, raw: Meeting.Summary?) {
        if let why = unavailable { return (Meeting.noSummary(why), "unavailable", nil, nil) }
        let lines = transcript.components(separatedBy: "\n").filter { $0.hasPrefix("[") }
        guard !lines.isEmpty else { return (Meeting.noSummary("Nothing was heard to summarise."), "empty", nil, nil) }
        // With a silent microphone every line is Others, and with the room's voices told apart but none of them known
        // to be the user's, no line is Me; the model is told, so it never writes Me.
        let noMe = !lines.contains { $0.contains("] Me: ") }
        // Room for the transcript in the model's window: about two and a half characters a token, after the
        // instructions, the shape of the answer and the answer itself.
        let budget = max(2000, (SystemLanguageModel.default.contextSize - 1800) * 5 / 2)
        let t0 = Date()
        do {
            let parts = Meeting.pieces(lines, maxChars: budget)
            var notes: [Notes] = [], skipped = 0, lastError: Error?
            for (i, p) in parts.enumerated() {
                let piece = p.components(separatedBy: "\n")
                // A piece that fails whatever its size (the model busy or missing, a language it doesn't take) is
                // left out and said; the notes from the other pieces are kept (D-1272).
                do { notes += try await fitting(piece, noMe: noMe, skipped: &skipped) }
                catch { lastError = error; skipped += piece.count; Log.note("meeting: summary left out a part of \(piece.count) lines (\(type(of: error)))") }
                progress((i + 1) * 90 / parts.count)
            }
            // Nothing written at all: the first failure's own message, as before (Apple Intelligence off, busy).
            if notes.isEmpty, let lastError { throw lastError }
            // Every piece refused: no notes, said plainly, never empty headings that look like notes.
            guard !notes.isEmpty else {
                Log.note("meeting: Apple's model declined every part of the meeting")
                return (Meeting.noSummary("Apple's model declined to summarise this meeting."), "declined", nil, nil)
            }
            let raw: Meeting.Summary
            if notes.count == 1 {
                raw = summary(notes[0])
            } else {
                // The overview of the whole is one more request, which can be refused too: then the parts' own first
                // sentences, in order, stand in for it.
                let overview: String
                do {
                    overview = plain(try await respond(overviewInstructions, notes.enumerated().map { "Part \($0.offset + 1): \($0.element.overview)" }.joined(separator: "\n")))
                } catch {
                    Log.note("meeting: overview failed (\(type(of: error))), using the parts' own")
                    // The start, the middle and the end, so the overview says where the meeting ended up.
                    let picks = Array(Set([0, notes.count / 2, notes.count - 1])).sorted()
                    overview = picks.compactMap { Meeting.sentences(plain(notes[$0].overview)).first }.joined(separator: " ")
                }
                raw = Meeting.merge(notes.map(summary), overview: overview)
            }
            progress(100)
            let checked = Meeting.check(raw, transcript: transcript)
            let s = checked.summary
            Log.note("meeting: summary from \(notes.count) pieces in \(Log.int(Date().timeIntervalSince(t0)))s, \(s.points.count) points, \(s.decisions.count) decisions, \(s.todos.count) to-dos; check moved \(checked.moved), left out \(checked.dropped), not tasks \(checked.notTasks), uncited \(checked.uncited); lines it wouldn't take \(skipped)")
            let gap = skipped == 0 ? "" : "\n\nApple's model couldn't summarise \(skipped) \(skipped == 1 ? "line" : "lines") of this meeting, so \(skipped == 1 ? "it isn't" : "they aren't") in these notes. \(skipped == 1 ? "It's" : "They're") still in the transcript."
            return (Meeting.summaryMarkdown(checked, transcript: transcript, label: label + gap), "\(notes.count) pieces" + (skipped > 0 ? ", \(skipped) lines refused" : ""), checked, raw)
        } catch {
            let text = "\(error)"
            if CommandLine.arguments.contains("--summary-test") { print("    model error: \(error)") }
            Log.note("meeting: summary failed (\(type(of: error)), \(MeetingNotes.code(error)))")
            if text.localizedCaseInsensitiveContains("guardrail") { return (Meeting.noSummary("Apple's model declined to summarise this meeting."), "declined", nil, nil) }
            return (Meeting.noSummary("Apple's model couldn't summarise this meeting."), "failed, \(MeetingNotes.code(error))", nil, nil)
        }
    }

    /// Notes for these lines. A piece the model can't take, too long for its window or refused by its safety check
    /// (GenerationError 2 on a 61-minute call, the whole meeting lost; D-1272), is split in two and tried again;
    /// a few lines it still refuses are left out and counted, so one stretch never costs the meeting its notes.
    /// A model that isn't there, or is busy, fails the summary as before: splitting wouldn't help.
    private static func fitting(_ lines: [String], noMe: Bool, skipped: inout Int) async throws -> [Notes] {
        do {
            return [try await summarise(lines.joined(separator: "\n"), noMe: noMe)]
        } catch let e as LanguageModelSession.GenerationError {
            // Splitting helps only a piece that's too long or that the safety check refused; these fail the same
            // way at any size, so they go up at once instead of one request per line.
            switch e {
            case .assetsUnavailable, .rateLimited, .concurrentRequests, .unsupportedLanguageOrLocale, .unsupportedGuide: throw e
            default: break
            }
            guard lines.count > 1 else {
                Log.note("meeting: summary left out \(lines.count) lines the model wouldn't take (\(kind(e)))")
                skipped += lines.count
                return []
            }
            Log.note("meeting: summary piece of \(lines.count) lines failed (\(kind(e))), splitting it")
            let half = lines.count / 2
            var out = try await fitting(Array(lines[..<half]), noMe: noMe, skipped: &skipped)
            out += try await fitting(Array(lines[half...]), noMe: noMe, skipped: &skipped)
            return out
        }
    }

    /// The kind of error, for the log: never its text, which can quote the meeting.
    static func kind(_ e: LanguageModelSession.GenerationError) -> String {
        switch e {
        case .exceededContextWindowSize: "too long"
        case .guardrailViolation: "safety check"
        case .refusal: "refused"
        case .decodingFailure: "unreadable answer"
        case .unsupportedLanguageOrLocale: "language"
        case .unsupportedGuide: "unsupported"
        default: "other"
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
                        todos: n.todos.map { Meeting.ToDo(who: $0.who, task: $0.task, at: Meeting.seconds($0.time)) },
                        open: n.open.map { Meeting.Cited($0.text, at: Meeting.seconds($0.time)) })
    }

    private static func summarise(_ piece: String, noMe: Bool) async throws -> Notes {
        let note = noMe ? "No line here is marked Me, so never write Me.\n\n" : ""
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
