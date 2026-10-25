import AVFoundation
import Speech
import WhisperKit
import VoiceCore

/// Apple's on-device speech engine, or Whisper, downloaded once and run on this Mac. The model stays loaded while
/// the app runs, so the second dictation is as quick as the first. Words from the names list are passed to Apple's
/// engine as context so it can get them right itself; for Whisper the names list only corrects afterwards.
final class Transcriber {
    enum State: Equatable { case checking, downloading(Int), ready, unsupported, failed(String) }
    private(set) var state: State = .checking
    var onState: (State) -> Void = { _ in }
    private var locale = Locale(identifier: "en-CA")
    private var format: AVAudioFormat?
    private var whisper: WhisperKit?

    /// Whisper large-v3 turbo, compressed by Argmax to 626 MB. 8.3% words wrong on WildSpeech-Bench (Apple 12.0%).
    static let whisperModel = "openai_whisper-large-v3-v20240930_626MB"
    static let modelsDir = Config.dir.appendingPathComponent("Models")
    private static var whisperFolder: URL {
        modelsDir.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(whisperModel)")
    }
    /// Whisper's options: English, no timestamps. Only audio longer than Whisper's 30-second window is split at
    /// pauses; splitting a short dictation dropped quiet ones entirely (3 of 1,100 WildSpeech clips came back empty).
    private static func whisperOptions(seconds: Double) -> DecodingOptions {
        DecodingOptions(language: "en", detectLanguage: false, skipSpecialTokens: true, withoutTimestamps: true,
                        chunkingStrategy: seconds > 29 ? .vad : nil)
    }

    /// `prompt`: words Whisper should expect (names from your list and the screen, the words just before), passed as
    /// Whisper's own "previous text" so it spells them the same way. Never typed out.
    static func whisperText(_ whisper: WhisperKit, _ audio: [Float], prompt: String? = nil) async throws -> String {
        guard !audio.isEmpty else { return "" }
        let seconds = Double(audio.count) / 16000
        let peak = audio.map { abs($0) }.max() ?? 0
        var options = whisperOptions(seconds: seconds)
        if let prompt, !prompt.isEmpty, let tokens = whisper.tokenizer?.encode(text: " " + prompt.trimmingCharacters(in: .whitespaces)) {
            options.promptTokens = tokens
        }
        let text = Silence.clean(joined(try await whisper.transcribe(audioArray: audio, decodeOptions: options)), peak: peak)
        // Whisper skips a stretch it judges to be silence. A short, quiet sentence can be skipped whole (3 of 1,100
        // WildSpeech clips), so when nothing came back but the audio has real sound, ask again without that skip.
        guard text.isEmpty, peak > Silence.quietPeak else { return text }
        var retry = options
        retry.noSpeechThreshold = nil
        retry.logProbThreshold = nil
        retry.firstTokenLogProbThreshold = nil
        Log.note("engine: whisper heard nothing in sound, asked again")
        return Silence.clean(joined(try await whisper.transcribe(audioArray: audio, decodeOptions: retry)), peak: peak)
    }

    private func module(_ config: Config) -> any SpeechModule {
        if config.engine == "transcription" {
            return SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        }
        return DictationTranscriber(locale: locale, contentHints: [.shortForm], transcriptionOptions: [.punctuation], reportingOptions: [], attributeOptions: [])
    }

    /// Finds the language model, downloads it the first time, and remembers the audio format it wants.
    func prepare(_ config: Config) async {
        set(.checking)
        if config.engine == "whisper" { await prepareWhisper(); return }
        let wanted = Locale(identifier: config.locale)
        let supported = await DictationTranscriber.supportedLocale(equivalentTo: wanted)
        guard let supported else { set(.unsupported); Log.note("engine: locale \(config.locale) unsupported"); return }
        locale = supported
        let m = module(config)
        do {
            let status = await AssetInventory.status(forModules: [m])
            Log.note("engine: asset status \(status)")
            if status == .unsupported { set(.unsupported); return }
            if status != .installed {
                _ = try await AssetInventory.reserve(locale: locale)
                if let req = try await AssetInventory.assetInstallationRequest(supporting: [m]) {
                    set(.downloading(0))
                    let watch = Task { [weak self] in
                        while !Task.isCancelled {
                            self?.set(.downloading(Int(req.progress.fractionCompleted * 100)))
                            try? await Task.sleep(for: .seconds(1))
                        }
                    }
                    try await req.downloadAndInstall()
                    watch.cancel()
                }
            }
            format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [m])
            guard format != nil else { set(.failed("no audio format")); return }
            set(.ready)
            Log.note("engine: ready, \(locale.identifier), \(format!.sampleRate) Hz")
        } catch {
            set(.failed(error.localizedDescription)); Log.note("engine: failed \(error.localizedDescription)")
        }
    }

    /// Whether Whisper's files are already on this Mac.
    static var whisperOnDisk: Bool {
        FileManager.default.fileExists(atPath: whisperFolder.appendingPathComponent("AudioEncoder.mlmodelc").path)
    }

    /// Downloads Whisper the first time (626 MB), then loads it. Later launches load it from disk with no network.
    private func prepareWhisper() async {
        do {
            if !Self.whisperOnDisk { set(.downloading(0)) }
            try await fetchWhisper { [weak self] p in self?.set(.downloading(Int(p * 100))) }
            format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
            set(.ready)
            Log.note("engine: ready, whisper")
        } catch {
            set(.failed(error.localizedDescription)); Log.note("engine: whisper failed \(error.localizedDescription)")
        }
    }

    /// Downloads and loads Whisper without touching the engine in use, so the built-in one keeps taking dictation
    /// until Whisper is ready to switch to. Cancelling the task stops the download.
    func fetchWhisper(progress: @escaping (Double) -> Void) async throws {
        guard whisper == nil else { return }
        if !Self.whisperOnDisk {
            _ = try await WhisperKit.download(variant: Self.whisperModel, downloadBase: Self.modelsDir) { p in progress(p.fractionCompleted) }
        }
        try Task.checkCancellation()
        let t = Date()
        whisper = try await WhisperKit(WhisperKitConfig(model: Self.whisperModel, modelFolder: Self.whisperFolder.path,
                                                       verbose: false, logLevel: .error, prewarm: true, load: true, download: false))
        Log.note("engine: whisper loaded in \(Int(Date().timeIntervalSince(t)))s")
    }

    var audioFormat: AVAudioFormat? { format }

    private func set(_ s: State) {
        guard s != state || s == .checking else { return }
        state = s; DispatchQueue.main.async { self.onState(s) }
    }

    /// Streaming as a test: the same cuts a live dictation makes, run over a file as if it were being recorded.
    /// Returns the text, the pieces, and how long the last piece took, which is the wait after you let go.
    static func simulateStream(_ whisper: WhisperKit, _ audio: [Float], chunker: Chunker, hints: String = "", carry: Bool = false) async throws -> (text: String, pieces: [String], tail: Double) {
        var cut = 0, pieces: [String] = []
        var heard = 0
        let step = Int(0.4 * Double(Chunker.rate))
        while heard < audio.count {
            heard = min(audio.count, heard + step)
            let visible = Array(audio[0..<heard])
            if let c = chunker.cut(visible, from: cut) {
                let t = try await whisperText(whisper, Array(audio[cut..<c]), prompt: Self.prompt(hints, carry ? pieces.last : nil))
                if !t.isEmpty { pieces.append(t) }
                cut = c
            }
        }
        let t0 = Date()
        let tail = try await whisperText(whisper, Array(audio[cut...]), prompt: Self.prompt(hints, carry ? pieces.last : nil))
        let wait = Date().timeIntervalSince(t0)
        if !tail.isEmpty { pieces.append(tail) }
        return (pieces.joined(separator: " "), pieces, wait)
    }

    /// Hints first, then the end of the last piece (so a sentence cut at a pause carries on in the same style).
    static func prompt(_ hints: String, _ previous: String?) -> String {
        let tail = previous.map { String($0.suffix(160)) } ?? ""
        return [hints, tail].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// One dictation: audio in while the key is held, text out after release.
    final class Session: @unchecked Sendable {
        private let input: AsyncStream<AnalyzerInput>
        private let feed: AsyncStream<AnalyzerInput>.Continuation
        private var analyzer: SpeechAnalyzer?
        private var collect: Task<String, Error>?
        /// Whisper hears the whole dictation at once, so its audio is kept here until the key comes up.
        private let whisper: WhisperKit?
        private var samples: [Float] = []
        private let lock = NSLock()
        /// Whisper writes each finished stretch while you are still talking (cut at a pause), so only the last few
        /// seconds are left when you let go. `onPiece` hears each one as it is written.
        var onPiece: ((String) -> Void)?
        private var loop: Task<Void, Never>?
        private var cut = 0
        private var pieces: [String] = []
        private var stopped = false
        /// Words to expect (names), set when the dictation starts.
        var hints = ""
        /// Pass the last piece along as context for the next. Kept only if the test says it helps.
        var carry = false

        /// Starts writing pieces as they finish. Whisper only.
        func stream(_ chunker: Chunker) {
            guard let whisper else { return }
            loop = Task.detached(priority: .userInitiated) { [self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(400))
                    let (audio, done) = lock.withLock { (samples, stopped) }
                    if done { break }
                    guard let c = chunker.cut(audio, from: cut) else { continue }
                    let piece = Array(audio[cut..<c])
                    cut = c
                    let text = (try? await Transcriber.whisperText(whisper, piece, prompt: Transcriber.prompt(hints, carry ? pieces.last : nil))) ?? ""
                    if !text.isEmpty { pieces.append(text); onPiece?(text) }
                }
            }
        }

        /// The pieces already written while you talked, in order.
        var written: [String] { pieces }
        /// This dictation's audio (Whisper only), for learning how you talk.
        var recorded: [Float] { lock.withLock { samples } }

        init(whisper: WhisperKit? = nil) {
            self.whisper = whisper
            var c: AsyncStream<AnalyzerInput>.Continuation!
            input = AsyncStream<AnalyzerInput> { c = $0 }
            feed = c
        }

        func push(_ buffer: AVAudioPCMBuffer) {
            guard whisper != nil else { feed.yield(AnalyzerInput(buffer: buffer)); return }
            guard let ch = buffer.floatChannelData?[0] else { return }
            lock.withLock { samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength))) }
        }

        func start(module: (any SpeechModule)?, vocabulary: [String]) {
            guard let module else { return }
            let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)
            if let d = module as? DictationTranscriber {
                collect = Task {
                    var parts: [String] = []
                    do { for try await r in d.results { parts.append(String(r.text.characters)) } }
                    catch { Log.note("engine results error: \(error)"); throw error }
                    Log.note("engine: \(parts.count) results")
                    return parts.joined(separator: " ")
                }
            } else if let t = module as? SpeechTranscriber {
                collect = Task {
                    var parts: [String] = []
                    do { for try await r in t.results { parts.append(String(r.text.characters)) } }
                    catch { Log.note("engine results error: \(error)"); throw error }
                    Log.note("engine: \(parts.count) results")
                    return parts.joined(separator: " ")
                }
            }
            let a = SpeechAnalyzer(modules: [module], options: options)
            analyzer = a
            let input = self.input
            Task {
                do {
                    if !vocabulary.isEmpty { let ctx = AnalysisContext(); ctx.contextualStrings[.general] = vocabulary; try await a.setContext(ctx) }
                    try await a.start(inputSequence: input)
                } catch { Log.note("engine start error: \(error)") }
            }
        }

        /// Ends the audio and waits for the last words. Never longer than ten seconds: a stuck engine is cancelled
        /// and whatever it had is returned, so the app never hangs on "Writing".
        func finish() async throws -> String {
            feed.finish()
            if let whisper {
                lock.withLock { stopped = true }
                await loop?.value  // a piece being written finishes first, so the order holds
                let audio = lock.withLock { samples }
                let tail = try await Transcriber.whisperText(whisper, Array(audio[min(cut, audio.count)...]), prompt: Transcriber.prompt(hints, carry ? pieces.last : nil))
                if !tail.isEmpty { pieces.append(tail) }
                return pieces.joined(separator: " ")
            }
            let a = analyzer
            let c = collect
            let text: String = try await withThrowingTaskGroup(of: String?.self) { g in
                g.addTask {
                    try await a?.finalizeAndFinishThroughEndOfInput()
                    return try await c?.value ?? ""
                }
                g.addTask { try await Task.sleep(for: .seconds(10)); return nil }
                let first = try await g.next() ?? nil
                g.cancelAll()
                if let first { return first }
                Log.note("engine: timed out, cancelling")
                await a?.cancelAndFinishNow()
                c?.cancel()
                return ""
            }
            return text.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func cancel() {
            lock.withLock { stopped = true }
            loop?.cancel()
            feed.finish()
            collect?.cancel()
            Task { [analyzer] in await analyzer?.cancelAndFinishNow() }
        }
    }

    func session(_ config: Config) -> (Session, (any SpeechModule)?) {
        if config.engine == "whisper" { return (Session(whisper: whisper), nil) }
        return (Session(), module(config))
    }

    private static func joined(_ results: [TranscriptionResult]) -> String {
        results.map(\.text).joined(separator: " ").replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One file, written whole (as before streaming) and streamed, with the time each takes. For the streaming test.
    func streamTest(_ url: URL, chunker: Chunker, hints: String = "", carry: Bool = false) async throws -> [String: Any] {
        guard let whisper else { throw NSError(domain: "RedpenVoice", code: 4, userInfo: [NSLocalizedDescriptionKey: "Whisper is not loaded"]) }
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        var t0 = Date()
        let whole = try await Self.whisperText(whisper, audio)
        let wholeSecs = Date().timeIntervalSince(t0)
        t0 = Date()
        let s = try await Self.simulateStream(whisper, audio, chunker: chunker, hints: hints, carry: carry)
        return ["file": url.lastPathComponent, "seconds": Double(audio.count) / 16000, "hyp_whole": whole, "whole_secs": wholeSecs,
                "hyp": s.text, "pieces": s.pieces.count, "tail_secs": s.tail, "stream_secs": Date().timeIntervalSince(t0)]
    }

    /// Runs the engine over an audio file and returns the text. For checking the engine without a microphone.
    func transcribeFile(_ url: URL, config: Config) async throws -> String {
        if config.engine == "whisper" {
            guard let whisper else { throw NSError(domain: "RedpenVoice", code: 4, userInfo: [NSLocalizedDescriptionKey: "Whisper is not loaded"]) }
            return try await Self.whisperText(whisper, try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path))
        }
        let m = module(config)
        let file = try AVAudioFile(forReading: url)
        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
        var parts: [String] = []
        let collect: Task<Void, Error>
        if let d = m as? DictationTranscriber { collect = Task { for try await r in d.results { parts.append(String(r.text.characters)) } } }
        else if let t = m as? SpeechTranscriber { collect = Task { for try await r in t.results { parts.append(String(r.text.characters)) } } }
        else { return "" }
        let a = SpeechAnalyzer(modules: [m], options: options)
        try await a.analyzeSequence(from: file)
        try await a.finalizeAndFinishThroughEndOfInput()
        try await collect.value
        return parts.joined(separator: " ")
    }
}
