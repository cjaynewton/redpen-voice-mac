import AVFoundation
import Speech
import WhisperKit
import FluidAudio
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
    /// Parakeet v2 (NVIDIA, English), the Fast engine: a minute of talk in well under a second, a few more mistakes.
    private var parakeet: AsrManager?
    static let parakeetMarker = Config.dir.appendingPathComponent("parakeet-ready")
    static var parakeetOnDisk: Bool { FileManager.default.fileExists(atPath: parakeetMarker.path) }
    /// Parakeet Unified 0.6B (NVIDIA, English), the Instant engine (D-816): it writes while you talk, so the text is
    /// ready about 0.03 s after the audio ends. Oct 26 2026: 9.2% of words wrong on WildSpeech-Bench (Whisper 7.8%),
    /// 14.8% on Cedric's judged clips (Whisper 13.8%). One dictation uses it at a time (`liveGate`).
    private var live: StreamingUnifiedAsrManager?
    private let liveGate = Gate()
    static let liveMarker = Config.dir.appendingPathComponent("instant-ready")
    static var liveOnDisk: Bool { FileManager.default.fileExists(atPath: liveMarker.path) }

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
        // One job at a time: two dictations close together (a double tap right after talking) asked Whisper at once
        // and both crawled (41 s on a busy Mac, Oct 25). They now wait in line.
        let queued = Date()
        try await gate.acquire()
        let started = Date()
        let results: [TranscriptionResult]
        do {
            // The Mac's AI chip now and then refuses a job when another app is using it ("ANE op async execution
            // failed"); one more try a moment later almost always works.
            do { results = try await whisper.transcribe(audioArray: audio, decodeOptions: options) }
            catch {
                Log.note("engine: whisper failed once, trying again")
                try await Task.sleep(for: .milliseconds(150))
                results = try await whisper.transcribe(audioArray: audio, decodeOptions: options)
            }
        } catch { await gate.release(); throw error }
        lastJob = Date().timeIntervalSince(started)
        await gate.release()
        // Where the time goes, so slowness can be told apart: waiting in line, the encoder (fixed cost per 30 s
        // window), the decoder, and fallbacks (Whisper decoding again at a higher temperature).
        if let t = results.first?.timings {
            let ms = Log.ms
            Log.note("engine job: \(String(format: "%.1f", seconds))s audio, in line \(ms(started.timeIntervalSince(queued)))ms, whisper \(ms(lastJob))ms (encode \(ms(t.encoding))ms x\(Log.int(t.totalEncodingRuns)), decode \(ms(t.decodingLoop))ms, fallbacks \(Log.int(t.totalDecodingFallbacks)), first word \(ms(t.firstTokenTime - t.pipelineStart))ms)")
        }
        let text = Silence.clean(joined(results), peak: peak)
        // Whisper skips a stretch it judges to be silence. A short, quiet sentence can be skipped whole (3 of 1,100
        // WildSpeech clips), so when nothing came back but the audio has real sound, ask again without that skip.
        guard text.isEmpty, peak > Silence.quietPeak else { return text }
        var retry = options
        retry.noSpeechThreshold = nil
        retry.logProbThreshold = nil
        retry.firstTokenLogProbThreshold = nil
        Log.note("engine: whisper heard nothing in sound, asked again")
        try await gate.acquire()
        do {
            let again = try await whisper.transcribe(audioArray: audio, decodeOptions: retry)
            await gate.release()
            return Silence.clean(joined(again), peak: peak)
        } catch { await gate.release(); throw error }
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
        if config.engine == "whisper" {
            await prepareWhisper()
            if config.draftMode == true { await loadDraftEngine() }
            return
        }
        if config.engine == "parakeet" { await prepareParakeet(); return }
        if config.engine == "live" { await prepareLive(); return }
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

    /// Downloads Parakeet the first time (about 600 MB), then loads it. Later launches load it from disk.
    private func prepareParakeet() async {
        do {
            if parakeet == nil {
                if !Self.parakeetOnDisk { set(.downloading(0)) }
                let t = Date()
                let models = try await AsrModels.downloadAndLoad(version: .v2)
                let m = AsrManager(config: .default)
                try await m.loadModels(models)
                parakeet = m
                FileManager.default.createFile(atPath: Self.parakeetMarker.path, contents: nil)
                Log.note("engine: parakeet loaded in \(Log.int(Date().timeIntervalSince(t)))s")
            }
            format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
            set(.ready)
            Log.note("engine: ready, parakeet")
        } catch {
            set(.failed(error.localizedDescription)); Log.note("engine: parakeet failed \(error.localizedDescription)")
        }
    }

    /// Downloads the Instant engine the first time (about 600 MB), then loads it. Later launches load it from disk.
    private func prepareLive() async {
        do {
            if live == nil {
                if !Self.liveOnDisk { set(.downloading(0)) }
                let t = Date()
                let m = StreamingUnifiedAsrManager(config: UnifiedConfig(leftFrames: 70, chunkFrames: 7, rightFrames: 7))
                try await m.loadModels(to: nil, configuration: nil) { [weak self] p in
                    if !Self.liveOnDisk { self?.set(.downloading(min(99, Int(p.fractionCompleted * 100)))) }
                }
                live = m
                FileManager.default.createFile(atPath: Self.liveMarker.path, contents: nil)
                Log.note("engine: instant (parakeet unified) loaded in \(Log.int(Date().timeIntervalSince(t)))s")
            }
            format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)
            set(.ready)
            Log.note("engine: ready, instant")
        } catch {
            set(.failed(error.localizedDescription)); Log.note("engine: instant failed \(error.localizedDescription)")
        }
    }

    /// Fast draft, Whisper checks: Parakeet loaded beside Whisper, without changing the engine in use.
    private func loadDraftEngine() async {
        guard parakeet == nil else { return }
        do {
            let t = Date()
            let models = try await AsrModels.downloadAndLoad(version: .v2)
            let m = AsrManager(config: .default)
            try await m.loadModels(models)
            parakeet = m
            FileManager.default.createFile(atPath: Self.parakeetMarker.path, contents: nil)
            Log.note("engine: draft engine (parakeet) loaded in \(Log.int(Date().timeIntervalSince(t)))s")
        } catch { Log.note("engine: draft engine failed \(error.localizedDescription), Whisper alone") }
    }

    static func parakeetText(_ p: AsrManager, _ audio: [Float]) async throws -> String {
        guard audio.count > 1600 else { return "" }
        let peak = audio.map { abs($0) }.max() ?? 0
        var state = TdtDecoderState.make(decoderLayers: await p.decoderLayerCount)
        let t = Date()
        let r = try await p.transcribe(audio, decoderState: &state)
        Log.note("engine job: \(String(format: "%.1f", Double(audio.count) / 16000))s audio, parakeet \(Log.ms(Date().timeIntervalSince(t)))ms")
        return Silence.clean(r.text, peak: peak)
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

    /// Where each part of Whisper runs. `VOICE_COMPUTE` picks for a test: "ane" (WhisperKit's default, the Neural
    /// Engine for both), "gpudec" (decoder on the graphics chip), "gpu" (both on the graphics chip).
    static var computeOptions: ModelComputeOptions? {
        switch ProcessInfo.processInfo.environment["VOICE_COMPUTE"] {
        case "gpudec": return ModelComputeOptions(audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndGPU)
        case "gpu": return ModelComputeOptions(audioEncoderCompute: .cpuAndGPU, textDecoderCompute: .cpuAndGPU)
        default: return nil
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
                                                       computeOptions: Self.computeOptions,
                                                       verbose: false, logLevel: .error, prewarm: true, load: true, download: false))
        Log.note("engine: whisper loaded in \(Log.int(Date().timeIntervalSince(t)))s")
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

    /// Whisper's queue: one job at a time, first come first served.
    /// A cancelled job (a guess thrown away when you let go) leaves the line at once instead of holding up the ending.
    actor Gate {
        private var busy = false
        private var waiting: [(id: UUID, turn: CheckedContinuation<Bool, Never>)] = []
        func acquire() async throws {
            if !busy { busy = true; return }
            let id = UUID()
            let got = await withTaskCancellationHandler {
                await withCheckedContinuation { c in waiting.append((id, c)) }
            } onCancel: { Task { await self.drop(id) } }
            if !got { throw CancellationError() }
        }
        private func drop(_ id: UUID) {
            if let i = waiting.firstIndex(where: { $0.id == id }) { waiting.remove(at: i).turn.resume(returning: false) }
        }
        func release() {
            if waiting.isEmpty { busy = false } else { waiting.removeFirst().turn.resume(returning: true) }
        }
    }
    static let gate = Gate()
    /// How long the last Whisper job took. Over two seconds means the Mac is busy, and the head start is skipped so
    /// it doesn't add work that may be thrown away.
    nonisolated(unsafe) static var lastJob = 0.0

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
        /// True when the last part could not be written (the engine failed on it); what came before is kept.
        private(set) var endingLost = false
        /// Whisper's text for the ending (everything after the last check), for replacing the last drafts.
        private(set) var lastTail = ""
        /// Pass the last piece along as context for the next. Kept only if the test says it helps.
        var carry = false
        /// A head start: when you go quiet while still holding the key, what you said since the last piece is written
        /// straight away. If you let go without saying more, that text is the ending and nothing waits on Whisper.
        private var early: (end: Int, text: String)?
        private var napping: Task<Void, Error>?
        private var guessing: Task<String, Error>?

        // MARK: Fast draft, Whisper checks (D-764)
        /// A short stretch Parakeet wrote at a small pause, by its place in the audio.
        struct Draft { let start: Int; let end: Int; let text: String }
        /// The draft engine (Parakeet). When set, drafts are written at every short pause and Whisper rereads whole
        /// runs of drafts (4 s or more, cut where a draft ended), so each check covers drafts exactly.
        var drafter: AsrManager?
        var onDraft: ((Int, String) -> Void)?
        /// Whisper's text for drafts `range`, to replace what the draft typed.
        var onCheck: ((Range<Int>, String) -> Void)?
        private var drafts: [Draft] = []
        /// Drafts already covered by a Whisper check; the ending covers the rest.
        private(set) var checkedUpTo = 0
        private var draftLoop: Task<Void, Never>?
        private var draftNap: Task<Void, Error>?
        /// When the last audio arrived and how much there was, to place a sample in time (for the draft timing).
        private var lastPush = (at: Date(), count: 0)
        var draftCount: Int { lock.withLock { drafts.count } }

        // MARK: Leaving out the video's sound (Oct 26)
        /// Audio before this sample is blanked: what a video played into the mic before its pause took hold.
        private var silenceUntil = 0
        /// False while Voice is still deciding whether something is playing; drafts and pieces wait, so the video's
        /// words are never written. Counts as settled after 2 s whatever happens.
        private var mediaSettledFlag = true
        private var holdingSince = Date()
        func holdForMedia() { lock.withLock { mediaSettledFlag = false; holdingSince = Date() } }
        func mediaSettled() { lock.withLock { mediaSettledFlag = true } }
        fileprivate var settledForLoops: Bool {
            lock.withLock { mediaSettledFlag || Date().timeIntervalSince(holdingSince) > 2 }
        }

        /// The sample heard at `d` (later than the newest sample means one not yet arrived).
        func sampleAt(_ d: Date) -> Int {
            lock.withLock { max(0, lastPush.count + Int(d.timeIntervalSince(lastPush.at) * Double(Chunker.rate))) }
        }

        /// Blanks everything before sample `i`, including audio that hasn't arrived yet.
        func silence(upTo i: Int) {
            lock.withLock {
                silenceUntil = max(silenceUntil, i)
                for k in 0..<min(silenceUntil, samples.count) { samples[k] = 0 }
                if live != nil, fed > 0 { refeed = true }
            }
        }

        /// Where speech began in this dictation's audio (the first loud 30 ms), for timing the first draft.
        var speechOnset: Int {
            let a = recorded
            let levels = Chunker.levels(a, from: 0)
            guard !levels.isEmpty else { return 0 }
            let q = Chunker.quietLevel(levels)
            return (levels.firstIndex { $0 > q } ?? 0) * 480
        }

        /// The moment sample `i` was heard, give or take a buffer.
        func timeOf(_ i: Int) -> Date {
            let p = lock.withLock { lastPush }
            return p.at.addingTimeInterval(-Double(p.count - i) / Double(Chunker.rate))
        }

        /// Starts the draft loop: every quarter second, at a short pause, Parakeet writes what was said since the last
        /// draft. About a fifth of a second a stretch on an M1 Max.
        func streamDrafts() {
            guard let drafter else { return }
            let chunker = Chunker(minSeconds: 0.8, maxSeconds: 6, pauseSeconds: 0.2)
            draftLoop = Task.detached(priority: .userInitiated) { [self] in
                var from = 0
                while true {
                    let nap = Task { try await Task.sleep(for: .milliseconds(200)) }
                    if !lock.withLock({ if stopped { return false }; draftNap = nap; return true }) { nap.cancel() }
                    _ = try? await nap.value
                    let (audio, done) = lock.withLock { draftNap = nil; return (samples, stopped) }
                    if done { break }
                    if !settledForLoops { continue }
                    guard let c = chunker.cut(audio, from: from) else { continue }
                    let text = (try? await Transcriber.parakeetText(drafter, Array(audio[from..<c]))) ?? ""
                    // The draft and its callback go out together, so a Whisper check can never reach the app first.
                    lock.withLock {
                        drafts.append(Draft(start: from, end: c, text: text))
                        onDraft?(drafts.count - 1, text)
                    }
                    from = c
                }
            }
        }

        /// Where Whisper cuts in draft mode: the first draft end at least 4 s after the last check (never past 25 s).
        private func draftCheckCut(_ ds: [Draft], from: Int) -> (end: Int, upTo: Int)? {
            guard checkedUpTo < ds.count else { return nil }
            for i in checkedUpTo..<ds.count where ds[i].end - from >= 4 * Chunker.rate {
                if ds[i].end - from > 25 * Chunker.rate, i > checkedUpTo { return (ds[i - 1].end, i) }
                return (ds[i].end, i + 1)
            }
            return nil
        }

        /// Starts writing pieces as they finish. Whisper only.
        func stream(_ chunker: Chunker) {
            guard let whisper else { return }
            loop = Task.detached(priority: .userInitiated) { [self] in
                while true {
                    // A nap the ending can cut short: letting go never waits out the rest of it.
                    let nap = Task { try await Task.sleep(for: .milliseconds(400)) }
                    // Published only if not already stopped, in one step, so letting go can never miss it.
                    if !lock.withLock({ if stopped { return false }; napping = nap; return true }) { nap.cancel() }
                    _ = try? await nap.value
                    let (audio, done, ds) = lock.withLock { napping = nil; return (samples, stopped, drafts) }
                    if done { break }
                    if !settledForLoops { continue }
                    if drafter != nil {
                        // Draft mode: Whisper rereads whole runs of drafts; no head start (the drafts are the speed).
                        // Audio and drafts are read in one step, so a draft can't end past the audio in hand.
                        guard let d = draftCheckCut(ds, from: cut), d.end <= audio.count, d.end > cut else { continue }
                        do {
                            let text = try await Transcriber.whisperText(whisper, Array(audio[cut..<d.end]), prompt: Transcriber.prompt(hints, nil))
                            let range = checkedUpTo..<d.upTo
                            cut = d.end; checkedUpTo = d.upTo
                            if !text.isEmpty { pieces.append(text) }
                            onCheck?(range, text)
                        } catch { Log.note("engine: a check failed, the ending covers it") }
                        continue
                    }
                    guard let c = chunker.cut(audio, from: cut) else {
                        // Quiet for a moment with new words since the last piece: write them now, ahead of release.
                        // Once per quiet spell: again only after you have said more. Letting go cancels a guess still
                        // being written, so the ending never waits on work it may throw away.
                        let saidMore = early.map { Chunker.hasSpeech(audio, from: $0.end, reference: cut) } ?? true
                        if saidMore, Transcriber.lastJob < 2, audio.count - cut > Chunker.rate / 2, Chunker.endsQuiet(audio, from: cut) {
                            let from = cut, prompt = Transcriber.prompt(hints, carry ? pieces.last : nil)
                            let guess = Task { try await Transcriber.whisperText(whisper, Array(audio[from...]), prompt: prompt) }
                            if !lock.withLock({ if stopped { return false }; guessing = guess; return true }) { guess.cancel() }
                            let text = try? await guess.value
                            lock.withLock { guessing = nil }
                            if let text, !guess.isCancelled { early = (audio.count, text) }
                        }
                        continue
                    }
                    early = nil
                    // The cut moves only once the piece is written: a failed piece stays in the audio still to do,
                    // so the ending picks it up instead of losing it.
                    do {
                        let text = try await Transcriber.whisperText(whisper, Array(audio[cut..<c]), prompt: Transcriber.prompt(hints, carry ? pieces.last : nil))
                        cut = c
                        if !text.isEmpty { pieces.append(text); onPiece?(text) }
                    } catch { Log.note("engine: a piece failed, it will be written with the ending") }
                }
            }
        }

        /// The pieces already written while you talked, in order.
        var written: [String] { pieces }
        /// True when the last quarter second was quiet: you had already stopped talking when you let go.
        var endedQuiet: Bool { let a = recorded; return a.count > Chunker.rate / 2 && Chunker.endsQuiet(a, from: 0, seconds: 0.25) }

        /// This dictation's audio (Whisper only), for learning how you talk.
        var recorded: [Float] { lock.withLock { samples } }

        private let parakeet: AsrManager?

        // MARK: Instant engine (D-816)
        /// Writes while you talk: new audio goes in about every 80 ms and its words go to the bar (`onPartial`), so
        /// at the end only the last fraction of a second is left. The text goes into the box once, at the end.
        private let live: StreamingUnifiedAsrManager?
        private let liveGate: Gate?
        var onPartial: ((String) -> Void)?
        private var liveRun: Task<String, Error>?
        private var fed = 0
        private var cancelled = false
        /// Set when the video's sound is blanked after the Instant engine already heard some of it: it starts over
        /// from the cleaned audio (about 0.04 s per second of audio).
        private var refeed = false
        private var liveNap: Task<Void, Error>?

        init(whisper: WhisperKit? = nil, parakeet: AsrManager? = nil, live: StreamingUnifiedAsrManager? = nil, liveGate: Gate? = nil) {
            self.whisper = whisper
            self.parakeet = parakeet
            self.live = live
            self.liveGate = liveGate
            var c: AsyncStream<AnalyzerInput>.Continuation!
            input = AsyncStream<AnalyzerInput> { c = $0 }
            feed = c
        }

        /// Starts the Instant engine for this dictation. It waits for a dictation still finishing (about 0.03 s), then
        /// catches up from this one's saved audio, so nothing is lost. Like Whisper's pieces, it waits while Voice
        /// decides whether a video was playing, so the video's words are never written.
        func streamLive() {
            guard let live, let liveGate else { return }
            liveRun = Task.detached(priority: .userInitiated) { [self] in
                try await liveGate.acquire()
                do {
                    try await live.reset()
                    var shown = ""
                    while true {
                        let (done, again) = lock.withLock { () -> (Bool, Bool) in
                            defer { refeed = false }
                            if refeed { fed = 0 }
                            return (stopped, refeed)
                        }
                        if again { try await live.reset(); shown = ""; Log.note("engine: instant started over after the video's sound was left out") }
                        if done || settledForLoops {
                            try await feedLive(live)
                            if !done {
                                let partial = await live.getPartialTranscript()
                                if partial != shown { shown = partial; onPartial?(partial) }
                            }
                        }
                        if done { break }
                        // A nap letting go cuts short, so the ending never waits out the rest of it.
                        let nap = Task { try await Task.sleep(for: .milliseconds(80)) }
                        if !lock.withLock({ if stopped { return false }; liveNap = nap; return true }) { nap.cancel() }
                        _ = try? await nap.value
                    }
                    let quit = lock.withLock { cancelled }
                    let text = quit ? "" : try await live.finish()
                    try? await live.reset()
                    await liveGate.release()
                    return text
                } catch {
                    try? await live.reset()
                    await liveGate.release()
                    throw error
                }
            }
        }

        /// Hands the audio not yet given to the Instant engine over to it.
        private func feedLive(_ live: StreamingUnifiedAsrManager) async throws {
            let chunk: [Float] = lock.withLock {
                defer { fed = samples.count }
                return fed < samples.count ? Array(samples[fed...]) : []
            }
            guard !chunk.isEmpty, let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
                  let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(chunk.count)) else { return }
            b.frameLength = AVAudioFrameCount(chunk.count)
            chunk.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: chunk.count) }
            try await live.appendAudio(b)
            try await live.processBufferedAudio()
        }

        func push(_ buffer: AVAudioPCMBuffer) {
            guard whisper != nil || parakeet != nil || live != nil else { feed.yield(AnalyzerInput(buffer: buffer)); return }
            guard let ch = buffer.floatChannelData?[0] else { return }
            lock.withLock {
                let start = samples.count
                samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
                if silenceUntil > start { for k in start..<min(silenceUntil, samples.count) { samples[k] = 0 } }
                lastPush = (Date(), samples.count)
            }
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
            if let parakeet { return try await Transcriber.parakeetText(parakeet, lock.withLock { samples }) }
            if live != nil {
                lock.withLock { stopped = true; liveNap?.cancel() }
                let f0 = Date()
                let text = try await liveRun?.value ?? ""
                onPartial = nil
                let peak = lock.withLock { samples.map { abs($0) }.max() ?? 0 }
                Log.note("engine finish: instant \(Log.ms(Date().timeIntervalSince(f0)))ms")
                return Silence.clean(text, peak: peak)
            }
            if let whisper {
                let (nap, guess, dnap) = lock.withLock { stopped = true; return (napping, guessing, draftNap) }
                nap?.cancel(); guess?.cancel(); dnap?.cancel()
                let f0 = Date()
                await draftLoop?.value
                await loop?.value  // a piece being written finishes first, so the order holds
                let loopWait = Log.ms(Date().timeIntervalSince(f0))
                let t0 = Date()
                let audio = lock.withLock { samples }
                let tail: String
                if let e = early, e.end <= audio.count, !Chunker.hasSpeech(audio, from: e.end, reference: cut) {
                    tail = e.text  // nothing said after the head start: it is the ending
                    Log.note("engine: ending was written ahead of release")
                } else {
                    do { tail = try await Transcriber.whisperText(whisper, Array(audio[min(cut, audio.count)...]), prompt: Transcriber.prompt(hints, carry ? pieces.last : nil)) }
                    catch {
                        // Keep what was already written and say the ending is missing, so it is never lost quietly.
                        Log.note("engine: the ending failed, \(pieces.count) pieces kept")
                        if pieces.isEmpty { throw error }
                        tail = ""
                        endingLost = true
                    }
                }
                if !tail.isEmpty { pieces.append(tail) }
                lastTail = tail
                onPiece = nil; onDraft = nil; onCheck = nil
                Log.note("engine finish: waited \(loopWait)ms for the stream, ending \(Log.ms(Date().timeIntervalSince(t0)))ms, \(pieces.count) pieces")
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
            onPiece = nil; onDraft = nil; onCheck = nil; onPartial = nil
            lock.withLock { cancelled = true }
            draftLoop?.cancel()
            lock.withLock { stopped = true }
            loop?.cancel()
            feed.finish()
            collect?.cancel()
            Task { [analyzer] in await analyzer?.cancelAndFinishNow() }
        }
    }

    func session(_ config: Config) -> (Session, (any SpeechModule)?) {
        if config.engine == "whisper" {
            let s = Session(whisper: whisper)
            if config.draftMode == true { s.drafter = parakeet }
            return (s, nil)
        }
        if config.engine == "parakeet" { return (Session(parakeet: parakeet), nil) }
        if config.engine == "live" { return (Session(live: live, liveGate: liveGate), nil) }
        return (Session(), module(config))
    }

    private static func joined(_ results: [TranscriptionResult]) -> String {
        results.map(\.text).joined(separator: " ").replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The live path, timed: a recording fed in at talking speed (with `pause` seconds of quiet at the end, as when
    /// you stop talking before letting go), then released. Returns how long finish() took, which is what you wait for.
    func sessionTest(_ url: URL, pause: Double, engine: String = "whisper") async throws -> (ms: Int, text: String) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else { return (0, "") }
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path) + [Float](repeating: 0.0003, count: Int(pause * 16000))
        let s: Session
        if engine == "live" { guard live != nil else { return (0, "") }; s = Session(live: live, liveGate: liveGate) }
        else { guard let whisper else { return (0, "") }; s = Session(whisper: whisper) }
        // VOICE_SILENCE_AT=1.3: act as if a video was paused and went quiet at that second (the live path's cut).
        let silenceAt = ProcessInfo.processInfo.environment["VOICE_SILENCE_AT"].flatMap(Double.init)
        if silenceAt != nil { s.holdForMedia() }
        if engine == "live" { s.streamLive() } else { s.stream(Chunker()) }
        let step = 1600  // a tenth of a second
        var i = 0
        while i < audio.count {
            let n = min(step, audio.count - i)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n)) else { break }
            buf.frameLength = AVAudioFrameCount(n)
            for k in 0..<n { buf.floatChannelData![0][k] = audio[i + k] }
            s.push(buf)
            i += n
            if let t = silenceAt, Double(i) / 16000 >= t, Double(i - n) / 16000 < t {
                s.silence(upTo: s.sampleAt(Date().addingTimeInterval(0.15)))
                s.mediaSettled()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let t = Date()
        let text = try await s.finish()
        return (Log.ms(Date().timeIntervalSince(t)), text)
    }

    /// Speed test: one clip, five times warm, then again after `idle` seconds doing nothing. Timings go to the log.
    func speedTest(_ url: URL, idle: Double) async throws {
        guard let whisper else { return }
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        let prompt = ProcessInfo.processInfo.environment["VOICE_HINTS"]
        for i in 1...5 { let t = Date(); _ = try await Self.whisperText(whisper, audio, prompt: prompt); print("warm \(i): \(Log.ms(Date().timeIntervalSince(t))) ms") }
        try await Task.sleep(for: .seconds(idle))
        for i in 1...2 { let t = Date(); _ = try await Self.whisperText(whisper, audio, prompt: prompt); print("after \(Int(idle)) s idle \(i): \(Log.ms(Date().timeIntervalSince(t))) ms") }
    }

    /// Draft mode on a file, as it would run live: Parakeet drafts at short pauses, Whisper rereads runs of drafts
    /// (4 s or more, cut at a draft end), then the ending. Returns Whisper's final text, the drafts' text, and how many
    /// checks changed words.
    func draftTest(_ url: URL) async throws -> [String: Any] {
        guard let whisper, let parakeet else { throw NSError(domain: "RedpenVoice", code: 4, userInfo: [NSLocalizedDescriptionKey: "both engines needed"]) }
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        let dch = Chunker(minSeconds: 0.8, maxSeconds: 6, pauseSeconds: 0.2)
        var drafts: [(end: Int, text: String)] = [], dfrom = 0, wcut = 0, checked = 0
        var final: [String] = [], checks = 0, changed = 0, words = 0, draftSecs: [Double] = []
        var heard = 0
        while heard < audio.count {
            heard = min(audio.count, heard + 3200)
            let visible = Array(audio[0..<heard])
            if let c = dch.cut(visible, from: dfrom) {
                let t0 = Date()
                drafts.append((c, try await Self.parakeetText(parakeet, Array(audio[dfrom..<c]))))
                draftSecs.append(Date().timeIntervalSince(t0)); dfrom = c
            }
            if let i = (checked..<drafts.count).first(where: { drafts[$0].end - wcut >= 4 * Chunker.rate }) {
                let w = try await Self.whisperText(whisper, Array(audio[wcut..<drafts[i].end]))
                let d = drafts[checked...i].map(\.text).joined(separator: " ")
                checks += 1; let n = Corrections.wordsChanged(d, w); if n > 0 { changed += 1; words += n }
                final.append(w); wcut = drafts[i].end; checked = i + 1
            }
        }
        let t0 = Date()
        let w = try await Self.whisperText(whisper, Array(audio[wcut...]))
        let tailSecs = Date().timeIntervalSince(t0)
        let d = drafts[checked...].map(\.text).joined(separator: " ")
        checks += 1; let n = Corrections.wordsChanged(d, w); if n > 0 { changed += 1; words += n }
        final.append(w)
        return ["file": url.lastPathComponent, "seconds": Double(audio.count) / 16000, "hyp": final.filter { !$0.isEmpty }.joined(separator: " "),
                "hyp_draft": drafts.map(\.text).joined(separator: " "), "checks": checks, "changed": changed, "words_changed": words,
                "draft_ms_median": draftSecs.isEmpty ? 0 : Log.ms(draftSecs.sorted()[draftSecs.count / 2]), "tail_secs": tailSecs]
    }

    /// One file, written whole (as before streaming) and streamed, with the time each takes. For the streaming test.
    func streamTest(_ url: URL, chunker: Chunker, hints: String = "", carry: Bool = false) async throws -> [String: Any] {
        guard let whisper else { throw NSError(domain: "RedpenVoice", code: 4, userInfo: [NSLocalizedDescriptionKey: "Whisper is not loaded"]) }
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
        var t0 = Date()
        let skipWhole = ProcessInfo.processInfo.environment["VOICE_SKIP_WHOLE"] == "1"
        let whole = skipWhole ? "" : try await Self.whisperText(whisper, audio)
        let wholeSecs = Date().timeIntervalSince(t0)
        t0 = Date()
        let s = try await Self.simulateStream(whisper, audio, chunker: chunker, hints: hints, carry: carry)
        return ["file": url.lastPathComponent, "seconds": Double(audio.count) / 16000, "hyp_whole": whole, "whole_secs": wholeSecs,
                "hyp": s.text, "pieces": s.pieces.count, "tail_secs": s.tail, "stream_secs": Date().timeIntervalSince(t0)]
    }

    /// Runs the engine over an audio file and returns the text. For checking the engine without a microphone.
    func transcribeFile(_ url: URL, config: Config) async throws -> String {
        if config.engine == "parakeet", let parakeet {
            return try await Self.parakeetText(parakeet, try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path))
        }
        if config.engine == "live" {
            // Fed in 160 ms pieces as a microphone would, through a session, so the check runs the live path.
            let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: url.path)
            let s = Session(live: live, liveGate: liveGate)
            s.streamLive()
            let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
            for i in stride(from: 0, to: audio.count, by: 2560) {
                let n = min(2560, audio.count - i)
                let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(n))!
                b.frameLength = AVAudioFrameCount(n)
                audio.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress! + i, count: n) }
                s.push(b)
            }
            return try await s.finish()
        }
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
