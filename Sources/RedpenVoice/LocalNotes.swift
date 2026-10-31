import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
import VoiceCore

/// Better summary on this Mac (D-1010): the writer this Mac's memory allows (VoiceCore's LocalWriter), downloaded
/// once into Redpen's models folder, or read in place from Hugging Face's own cache when it is already there. It runs
/// inside the app with Apple's MLX, only when asked, and is unloaded as soon as the notes are written. The transcript
/// never leaves the Mac.
enum LocalNotes {
    /// Hugging Face's cache, where its own tools put downloads: HF_HUB_CACHE, else HF_HOME/hub, else ~/.cache.
    static var hub: URL {
        let env = ProcessInfo.processInfo.environment
        if let h = env["HF_HUB_CACHE"], !h.isEmpty { return URL(fileURLWithPath: h, isDirectory: true) }
        if let h = env["HF_HOME"], !h.isEmpty { return URL(fileURLWithPath: h, isDirectory: true).appendingPathComponent("hub", isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    /// The writer this Mac gets, by its memory; nil when it has too little.
    static var writer: LocalWriter? { LocalWriter.forMac(memory: ProcessInfo.processInfo.physicalMemory) }

    /// Redpen's own copy, beside the speech models.
    static func own(_ w: LocalWriter) -> URL { w.ownFolder(models: Transcriber.modelsDir) }

    /// Written in Redpen's copy once every file has been checked against its hash, so a half-finished download is
    /// never loaded.
    static let checkedMark = ".redpen-checked"

    /// Where the writer can be loaded from: Redpen's checked copy, else a complete copy in Hugging Face's cache. Nil
    /// when neither is there. Reads no file, so it is quick enough for Settings.
    static func folder(_ w: LocalWriter) -> URL? {
        let mine = own(w)
        if FileManager.default.fileExists(atPath: mine.appendingPathComponent(checkedMark).path), w.complete(in: mine) { return mine }
        let cached = w.cacheSnapshot(hub: hub)
        if w.complete(in: cached) { return cached }
        return nil
    }

    /// The copy in use is Hugging Face's, not Redpen's: Remove leaves it alone.
    static func inHubCache(_ w: LocalWriter) -> Bool {
        guard let f = folder(w) else { return false }
        return f.standardizedFileURL != own(w).standardizedFileURL
    }

    /// This Mac has a writer and it is ready to load.
    static var ready: Bool { writer.flatMap(folder) != nil }

    // MARK: Writing

    private static let lock = NSLock()
    nonisolated(unsafe) private static var writing = false

    /// Better summary's answer, as the CLI helpers give it: the notes, or a plain reason they weren't written. One at
    /// a time, so two writers are never in memory together. Waits up to `limit` seconds: never on the main thread.
    static func answer(_ transcript: String, limit: TimeInterval = 600) -> (ok: Bool, text: String) {
        guard let w = writer else { return (false, "This Mac doesn't have enough memory for a writer of its own.") }
        guard let folder = folder(w) else { return (false, "Download \(w.name) in Settings first, under Meeting notes.") }
        let free = lock.withLock { if writing { return false }; writing = true; return true }
        guard free else { return (false, "A summary is already being written on this Mac. Try again when it's done.") }
        defer { lock.withLock { writing = false } }
        final class Box: @unchecked Sendable { var result: Result<Written, Error>? }
        let box = Box(), done = DispatchSemaphore(value: 0)
        let task = Task.detached {
            do { box.result = .success(try await write(prompt: BetterSummary.prompt, input: transcript, folder: folder)) }
            catch { box.result = .failure(error) }
            done.signal()
        }
        if done.wait(timeout: .now() + limit) == .timedOut {
            task.cancel()
            Log.note("notes writer: no answer within \(Int(limit))s (\(w.id))")
            return (false, "\(w.name) didn't finish within \(Int(limit / 60)) minutes. Your notes are unchanged.")
        }
        switch box.result {
        case .success(let r)?:
            Log.note("notes writer: \(w.id) loaded in \(Log.int(r.loadSeconds))s, \(r.promptTokens) tokens in, \(r.tokens) out in \(Log.int(r.writeSeconds))s")
            return r.text.isEmpty ? (false, "\(w.name) wrote nothing. Your notes are unchanged.") : (true, r.text)
        case .failure(Failure.tooLong)?:
            Log.note("notes writer: meeting too long (\(w.id))")
            return (false, "This meeting is too long for \(w.name). Apple's summary is kept.")
        default:
            Log.note("notes writer: \(w.id) failed to load or write")
            return (false, "\(w.name) couldn't start. Remove it in Settings and download it again.")
        }
    }

    struct Written {
        let text: String
        let promptTokens: Int
        let tokens: Int
        let loadSeconds: Double
        let writeSeconds: Double
        /// Of the write: reading the transcript, then writing the notes.
        let promptSeconds: Double
        let answerSeconds: Double
    }

    enum Failure: Error { case tooLong }

    /// About 75 minutes of talk: 18 minutes came to 8,000 tokens and 56 minutes to 23,000 (D-1010). Longer meetings
    /// weren't tried, so past this Apple's summary stays.
    static let maxPromptTokens = 32_000

    /// Loads the writer from `folder`, writes notes for `input` with `prompt`, and unloads it. Thinking off, greedy
    /// (the same answer each time, as in the D-1007 test). Runs for a minute or so: never on the main thread.
    static func write(prompt: String, input: String, folder: URL, maxTokens: Int = 1400) async throws -> Written {
        // The writer is let go when `load` returns; then MLX hands back the buffers it kept for reuse.
        defer { Memory.clearCache() }
        // At most 2 GB of freed buffers kept for reuse. With no limit, a 56-minute meeting took Qwen to 38 GB and
        // twice as long; with 2 GB it peaked at 21.5 GB (D-1010).
        Memory.cacheLimit = 2 << 30
        return try await load(prompt: prompt, input: input, folder: folder, maxTokens: maxTokens)
    }

    private static func load(prompt: String, input: String, folder: URL, maxTokens: Int) async throws -> Written {
        let t0 = Date()
        let container = try await LLMModelFactory.shared.loadContainer(from: folder, using: TokenizersLoader())
        let loaded = Date().timeIntervalSince(t0)
        // The CLI helpers get the transcript on stdin; here it follows the rules in the same message, as Gemini's does.
        let message = prompt + "\n\n<stdin>\n" + input + "\n</stdin>"
        let user = UserInput(chat: [.user(message)], additionalContext: ["enable_thinking": false])
        let lm = try await container.prepare(input: user)
        let promptTokens = lm.text.tokens.size
        guard promptTokens <= maxPromptTokens else { throw Failure.tooLong }
        let t1 = Date()
        var text = "", info: GenerateCompletionInfo?
        // MLX's own steps for reading the transcript: 2,048 tokens at a time, as Python's mlx-lm reads, was slower
        // here and used 1.5 GB more (D-1010).
        for await g in try await container.generate(input: lm, parameters: GenerateParameters(maxTokens: maxTokens, temperature: 0)) {
            switch g {
            case .chunk(let s): text += s
            case .info(let i): info = i
            default: break
            }
        }
        return Written(text: LocalWriter.answer(text), promptTokens: promptTokens, tokens: info?.generationTokenCount ?? 0,
                       loadSeconds: loaded, writeSeconds: Date().timeIntervalSince(t1),
                       promptSeconds: info?.promptTime ?? 0, answerSeconds: info?.generateTime ?? 0)
    }
}

/// Hugging Face's tokenizers in the shape MLX asks for: the same bridge MLX's own Hugging Face macros write.
private struct TokenizersLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer
    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] { upstream.encode(text: text, addSpecialTokens: addSpecialTokens) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens) }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
