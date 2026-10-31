import FluidAudio
import Foundation
import VoiceCore

/// Speakers in the room (D-1034): who spoke when on the microphone track, when several people share one mic. Runs
/// FluidAudio's offline pipeline (pyannote community-1 segmentation, WeSpeaker embeddings, VBx clustering) on this
/// Mac. The models download once from Hugging Face, only after the user asks.
enum RoomSpeakers {
    /// One stretch of one speaker's talking, in seconds from the start of the track.
    struct Turn: Codable, Equatable { var start: Double; var end: Double; var speaker: Int }

    /// The turns, and each speaker's voice as one embedding (index = speaker), for telling who is who.
    struct Split { var turns: [Turn]; var voices: [[Float]] }

    /// The pipeline's settings: the published community-1 recipe unless a test asks otherwise.
    static func config(step: Double? = nil, threshold: Double? = nil) -> OfflineDiarizerConfig {
        var c = OfflineDiarizerConfig()
        if let step { c.segmentation.stepRatio = step }
        if let threshold { c.clustering.threshold = threshold }
        return c
    }

    /// Who spoke when in 16 kHz mono samples. Speakers are numbered by when they first talk.
    static func split(_ samples: [Float], config: OfflineDiarizerConfig = config()) async throws -> Split {
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        return split(from: try await manager.process(audio: samples))
    }

    static func mean(_ vs: [[Float]]) -> [Float] {
        guard let n = vs.first?.count, n > 0 else { return [] }
        var m = [Float](repeating: 0, count: n)
        for v in vs where v.count == n { for i in 0..<n { m[i] += v[i] } }
        return m.map { $0 / Float(max(vs.count, 1)) }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var d: Float = 0, x: Float = 0, y: Float = 0
        for i in a.indices { d += a[i] * b[i]; x += a[i] * a[i]; y += b[i] * b[i] }
        return x > 0 && y > 0 ? d / (x.squareRoot() * y.squareRoot()) : 0
    }

    // MARK: Models

    /// Where FluidAudio keeps the speaker models (about 21 MB): its own models folder, shared with Instant.
    static var modelsFolder: URL { OfflineDiarizerModels.defaultModelsDirectory().appendingPathComponent("speaker-diarization", isDirectory: true) }

    /// The models are on this Mac. Nothing downloads unless the user asks in Settings: meetings check this first.
    static var modelsReady: Bool {
        // Every file FluidAudio checks before it uses the cache; one missing would make it download again.
        ["Segmentation.mlmodelc", "Embedding.mlmodelc", "FBank.mlmodelc", "PldaRho.mlmodelc", "plda-parameters.json",
         "xvector-transform.json", ".fluidaudio-revision"].allSatisfy {
            FileManager.default.fileExists(atPath: modelsFolder.appendingPathComponent($0).path)
        }
    }

    /// Downloads the models from Hugging Face, once, when the user turns on Voices in the room.
    static func download() async throws {
        let m = OfflineDiarizerManager(config: config())
        try await m.prepareModels()
    }

    // MARK: A meeting's microphone track

    /// Each microphone line's voice, and the labels used, for a recorded track of 16-bit samples at `rate`. The
    /// track is read from disk through a temporary WAV beside it, so an hour's meeting never sits in memory whole.
    /// Nil when the models aren't here, or on any failure: the lines then stay Me, as before.
    static func label(track: URL, rate: Int, offset: Double, lines: [MeetingSegment], knowMe: Bool) async -> (voices: [VoiceCore.Speaker], names: [VoiceCore.Speaker])? {
        guard modelsReady, !lines.isEmpty, let bytes = (try? FileManager.default.attributesOfItem(atPath: track.path))?[.size] as? Int, bytes > 0 else { return nil }
        let wav = track.deletingPathExtension().appendingPathExtension("wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        clearLeftovers()
        do {
            try writeWAV(track, bytes: bytes, rate: rate, to: wav)
            let t0 = Date()
            let manager = OfflineDiarizerManager(config: config())
            try await manager.prepareModels()
            let result = try await manager.process(wav)
            let split = split(from: result, offset: offset)
            var me: Int? = nil
            if knowMe, let print = Voiceprint.load(), print.count >= Voiceprint.least, split.voices.count > 1 {
                me = Meeting.whichIsMe(split.voices.map { cosine($0, print.voice) })
            }
            let names = Meeting.roomNames(count: split.voices.count, me: me)
            let turns = split.turns.map { RoomTurn(start: $0.start, end: $0.end, voice: $0.speaker) }
            Log.note("meeting: voices in the room \(split.voices.count), mine \(me == nil ? "not known" : "found") in \(Log.int(Date().timeIntervalSince(t0)))s")
            return (Meeting.voices(for: lines, turns: turns, names: names), names)
        } catch {
            Log.note("meeting: voices in the room not told apart, \((error as NSError).domain) \((error as NSError).code)")
            return nil
        }
    }

    /// Who spoke when, from the pipeline's answer: speakers numbered by when they first talk, times moved by `offset`.
    static func split(from result: DiarizationResult, offset: Double = 0) -> Split {
        var order: [String] = []
        for s in result.segments.sorted(by: { $0.startTimeSeconds < $1.startTimeSeconds }) where !order.contains(s.speakerId) {
            order.append(s.speakerId)
        }
        let turns = result.segments.map {
            Turn(start: Double($0.startTimeSeconds) + offset, end: Double($0.endTimeSeconds) + offset, speaker: order.firstIndex(of: $0.speakerId) ?? 0)
        }.sorted { $0.start < $1.start }
        let voices = order.map { id in
            result.speakerDatabase?[id] ?? mean(result.segments.filter { $0.speakerId == id }.map(\.embedding))
        }
        return Split(turns: turns, voices: voices)
    }

    /// FluidAudio reads a file through a float copy in the temporary folder and deletes it when done; a crash or a
    /// force quit midway leaves it. Copies more than an hour old are meeting audio nobody is using: they go.
    static func clearLeftovers() {
        let fm = FileManager.default, tmp = fm.temporaryDirectory
        for name in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [] where name.hasPrefix("fluidaudio-streaming-") && name.hasSuffix(".raw") {
            let url = tmp.appendingPathComponent(name)
            if let made = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, made < Date().addingTimeInterval(-3600) {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// A raw 16-bit mono track as a WAV file, copied a megabyte at a time.
    static func writeWAV(_ pcm: URL, bytes: Int, rate: Int, to out: URL) throws {
        var h = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; h.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; h.append(Data(bytes: &x, count: 2)) }
        h.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); h.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        h.append(contentsOf: Array("data".utf8)); u32(bytes)
        FileManager.default.createFile(atPath: out.path, contents: h, attributes: [.posixPermissions: 0o600])
        let w = try FileHandle(forWritingTo: out), r = try FileHandle(forReadingFrom: pcm)
        defer { try? w.close(); try? r.close() }
        try w.seekToEnd()
        while let d = try r.read(upToCount: 1 << 20), !d.isEmpty { try w.write(contentsOf: d) }
    }
}

/// The user's own voice as numbers (D-1034): the average of what the speaker model makes of their dictations, so
/// their lines in the room say Me. Never audio. Learned only while Know my voice is on, from at most `enough`
/// dictations of three seconds or more, kept in one file readable only by their account, and gone with Forget.
struct Voiceprint: Codable {
    var voice: [Float]
    var count: Int

    static let enough = 12
    /// Dictations before the voice is used to find Me: one alone is too little to trust.
    static let least = 3
    static var url: URL { Config.dir.appendingPathComponent("voiceprint.json") }

    static func load() -> Voiceprint? {
        guard let d = try? Data(contentsOf: url), let v = try? JSONDecoder().decode(Voiceprint.self, from: d), !v.voice.isEmpty else { return nil }
        return v
    }

    static func forget() { try? FileManager.default.removeItem(at: url) }

    /// One more dictation's worth, saved only if `keep` still says yes when it's ready: turning Know my voice off
    /// while this runs must not bring a deleted voiceprint back. The check and the save run together on the main
    /// actor, where Forget runs too. The audio is only read here, in memory, and never kept.
    static func learn(from samples: [Float], rate: Int = 16_000, keep: @escaping @MainActor () -> Bool) async {
        guard RoomSpeakers.modelsReady, samples.count >= rate * 3, (load()?.count ?? 0) < enough else { return }
        guard let mine = await voice(in: samples) else { return }
        await MainActor.run { if keep() { add(mine) } }
    }

    /// The main voice in some audio, as the speaker model sees it.
    static func voice(in samples: [Float]) async -> [Float]? {
        do {
            let manager = OfflineDiarizerManager(config: RoomSpeakers.config())
            try await manager.prepareModels()
            let split = RoomSpeakers.split(from: try await manager.process(audio: samples))
            var talk = [Double](repeating: 0, count: split.voices.count)
            for t in split.turns { talk[t.speaker] += t.end - t.start }
            guard let main = talk.indices.max(by: { talk[$0] < talk[$1] }), !split.voices[main].isEmpty else { return nil }
            return split.voices[main]
        } catch {
            Log.note("voice: not learned, \((error as NSError).domain) \((error as NSError).code)")
            return nil
        }
    }

    /// Adds one dictation's voice to the average, in a file readable only by this account.
    static func add(_ mine: [Float]) {
        do {
            var v = load() ?? Voiceprint(voice: [Float](repeating: 0, count: mine.count), count: 0)
            guard v.voice.count == mine.count, v.count < enough else { return }
            v.voice = zip(v.voice, mine).map { ($0 * Float(v.count) + $1) / Float(v.count + 1) }
            v.count += 1
            let data = try JSONEncoder().encode(v)
            // Made readable only by this account before anything is in it.
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            try data.write(to: url)
            Log.note("voice: learned from \(v.count) of \(enough) dictations")
        } catch {
            Log.note("voice: not saved, \((error as NSError).domain) \((error as NSError).code)")
        }
    }
}
