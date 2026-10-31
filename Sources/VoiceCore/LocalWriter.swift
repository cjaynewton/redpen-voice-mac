import CryptoKit
import Foundation

/// Better summary on this Mac (D-1010): a writer downloaded once from Hugging Face and run inside the app, so the
/// transcript never leaves the Mac. Each Mac gets the best one its memory can hold: Qwen3.6 35B with 48 GB or more,
/// Gemma 4 small with 16 GB or more, none below that (Apple's summary stays). Pinned to exact revisions, and every
/// file is checked against the hash Hugging Face lists for it before it is used.
///
/// The cut-offs, from the peaks measured in the app on an 18-minute and a 56-minute meeting: Qwen 21.1 to 21.5 GB,
/// Gemma 7.0 to 7.2 GB. Qwen on 32 GB would take about two thirds of the Mac, the share macOS lets the GPU use by
/// default on smaller Macs, with Whisper and the call app still open, so it starts at 48 GB. Gemma leaves 16 GB Macs
/// about half free.
public struct LocalWriter: Equatable, Sendable {
    public struct File: Equatable, Sendable {
        public let name: String
        public let size: Int64
        /// SHA-256 of the file, for the large files Hugging Face keeps in LFS.
        public let sha256: String?
        /// Git's blob SHA-1, for the small files kept in the repo itself.
        public let gitSHA1: String?
        public init(_ name: String, _ size: Int64, sha256: String? = nil, git: String? = nil) {
            self.name = name; self.size = size; self.sha256 = sha256; self.gitSHA1 = git
        }
    }

    /// "qwen" or "gemma".
    public let id: String
    /// As Settings and the notes say it.
    public let name: String
    public let repo: String
    public let revision: String
    /// Only what loading and the tokenizer need: no README, no picture or video settings.
    public let files: [File]
    /// The least memory a Mac needs for this writer, in GB as Apple sells them.
    public let minimumGB: Int

    public init(id: String, name: String, repo: String, revision: String, files: [File], minimumGB: Int) {
        self.id = id; self.name = name; self.repo = repo; self.revision = revision; self.files = files; self.minimumGB = minimumGB
    }

    public var bytes: Int64 { files.reduce(0) { $0 + $1.size } }
    /// "20.4 GB", in the decimal gigabytes Finder shows.
    public var sizeText: String { Self.gb(bytes) }

    public static let qwen = LocalWriter(
        id: "qwen", name: "Qwen3.6 35B", repo: "mlx-community/Qwen3.6-35B-A3B-4bit",
        revision: "38740b847e4cb78f352aba30aa41c76e08e6eb46",
        files: [
            File("chat_template.jinja", 7764, git: "a8755d827c0a7b614c246c4060dfd58ab352a8ff"),
            File("config.json", 23591, git: "e3a2334ebf2df216742ef3ed4b784417bfffe6fc"),
            File("generation_config.json", 202, git: "023756cfadf88e5bf69eefeee3e172f38c448d64"),
            File("model.safetensors.index.json", 215755, git: "f714d295484e01790bad8b40c2ce49323d7d2598"),
            File("tokenizer.json", 19989343, sha256: "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
            File("tokenizer_config.json", 1139, git: "a068e2468cff426a9b105006e74e044030a6faf4"),
            File("model-00001-of-00004.safetensors", 5288196018, sha256: "09f3e6ecb0b7af6e6a38bc8169a134c821b0924c2679b2bb8f4426ad38d032b8"),
            File("model-00002-of-00004.safetensors", 5368472749, sha256: "31dcdb1c49eebdb1505bd14e3cb33f9cf900bd2546b638f2464694ae763a033f"),
            File("model-00003-of-00004.safetensors", 5368324139, sha256: "3e66de06a1f03dade16a612a368cfce4a4c9caa4efd7d28185454384082cec03"),
            File("model-00004-of-00004.safetensors", 4377211365, sha256: "a5d0cf03519c26f8b506df6b0ba60526e5c08c8cea22d0c21ce92950e58a5422"),
        ],
        minimumGB: 48)

    public static let gemma = LocalWriter(
        id: "gemma", name: "Gemma 4 small", repo: "mlx-community/gemma-4-e4b-it-4bit",
        revision: "475b9088d29754a3379866cf5aeb6b41acd313c2",
        files: [
            File("chat_template.jinja", 17336, git: "c19999a347da729cf62806a8ddb7eb8e315223b5"),
            File("config.json", 6628, git: "4ee08502c4f98810dd43800ec849bd69f94adc98"),
            File("generation_config.json", 208, git: "e605bb4523b1462ea9d9a3810b9e3ecf7ab7b1f6"),
            File("model.safetensors.index.json", 240961, git: "c03ce5f7086b735345038501f731634de064493b"),
            File("tokenizer.json", 32169626, sha256: "cc8d3a0ce36466ccc1278bf987df5f71db1719b9ca6b4118264f45cb627bfe0f"),
            File("tokenizer_config.json", 2740, git: "cf6235aee46a24bf71f251c0a4e7a0379948f7d2"),
            File("model.safetensors", 5146800534, sha256: "932b8271fc3fe65adcc78b96c10c6268bbfb13e8f67d1358727c0d6ee97e1eff"),
        ],
        minimumGB: 16)

    /// Best first.
    public static let all = [qwen, gemma]

    public static func named(_ id: String) -> LocalWriter? { all.first { $0.id == id } }

    /// The writer this Mac gets from its memory (`ProcessInfo.physicalMemory`), or nil when it has too little.
    /// A Mac sold as 16 GB reports 16 GiB, so the cut-offs are in GiB.
    public static func forMac(memory: UInt64) -> LocalWriter? {
        let gib = memory / (1 << 30)
        return all.first { gib >= UInt64($0.minimumGB) }
    }

    /// Where Hugging Face serves a file at the pinned revision. Always HTTPS.
    public func url(_ f: File) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(f.name)")!
    }

    /// The folder Hugging Face's own tools keep this revision in, under `hub` (normally ~/.cache/huggingface/hub).
    public func cacheSnapshot(hub: URL) -> URL {
        hub.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
    }

    /// Redpen's own copy, inside its models folder.
    public func ownFolder(models: URL) -> URL {
        models.appendingPathComponent("notes-writers", isDirectory: true)
            .appendingPathComponent(repo, isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
    }

    /// Every file is there at its listed size (links followed). Cheap: reads no file.
    public func complete(in folder: URL) -> Bool {
        files.allSatisfy { f in
            let path = folder.appendingPathComponent(f.name).resolvingSymlinksInPath().path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
            return size == f.size
        }
    }

    /// "20.4 GB", "850 MB".
    public static func gb(_ bytes: Int64) -> String {
        let g = Double(bytes) / 1e9
        if g >= 1 { return String(format: "%.1f GB", g) }
        return String(format: "%.0f MB", max(Double(bytes) / 1e6, bytes > 0 ? 1 : 0))
    }

    /// "3.1 of 20.4 GB".
    public func progressText(done: Int64) -> String {
        let total = Double(bytes) / 1e9
        return String(format: "%.1f of %.1f GB", min(Double(done) / 1e9, total), total)
    }

    /// Whether the file at `url` is the pinned one: its size, then its hash, read a few MB at a time.
    /// Seconds for a 5 GB file, so never on the main thread.
    public static func matches(_ f: File, at url: URL, cancelled: () -> Bool = { false }) -> Bool {
        let url = url.resolvingSymlinksInPath()
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value,
              size == f.size, let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        var sha256 = SHA256(), sha1 = Insecure.SHA1()
        if f.gitSHA1 != nil { sha1.update(data: Data("blob \(f.size)\0".utf8)) }
        while true {
            if cancelled() { return false }
            let chunk: Data?
            do { chunk = try h.read(upToCount: 8 << 20) } catch { return false }
            // Nil or empty at the end of the file.
            guard let chunk, !chunk.isEmpty else { break }
            if f.sha256 != nil { sha256.update(data: chunk) }
            if f.gitSHA1 != nil { sha1.update(data: chunk) }
        }
        func hex<D: Digest>(_ d: D) -> String { d.map { String(format: "%02x", $0) }.joined() }
        if let want = f.sha256, hex(sha256.finalize()) != want { return false }
        if let want = f.gitSHA1, hex(sha1.finalize()) != want { return false }
        return f.sha256 != nil || f.gitSHA1 != nil
    }

    /// The writer's answer without any thinking it wrote first (Qwen's `<think>` block, when thinking slips through).
    public static func answer(_ raw: String) -> String {
        var s = raw
        while let open = s.range(of: "<think>"), let close = s.range(of: "</think>", range: open.upperBound..<s.endIndex) {
            s.removeSubrange(open.lowerBound..<close.upperBound)
        }
        if let close = s.range(of: "</think>") { s.removeSubrange(s.startIndex..<close.upperBound) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
