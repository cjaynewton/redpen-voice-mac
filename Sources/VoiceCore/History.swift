import Foundation

/// Every dictation, kept on this Mac only, so nothing you said is ever lost to a paste that failed.
/// One JSON line per entry in history.jsonl. The file is trimmed to the newest 2,000 entries.
public struct Entry: Codable, Equatable {
    public var date: Date
    public var raw: String
    public var cleaned: String?
    public var seconds: Double
    public var app: String
    public var inserted: Bool
    public init(date: Date = Date(), raw: String, cleaned: String? = nil, seconds: Double, app: String, inserted: Bool) {
        self.date = date; self.raw = raw; self.cleaned = cleaned; self.seconds = seconds; self.app = app; self.inserted = inserted
    }
    /// What went into the app: the cleaned text when there is one, else the raw.
    public var text: String { cleaned ?? raw }
    public var words: Int { raw.split(whereSeparator: { $0.isWhitespace }).count }
}

public struct History {
    public let url: URL
    public static let cap = 2_000
    public init(url: URL) { self.url = url }

    public func append(_ e: Entry) {
        guard let data = try? JSONEncoder().encode(e) else { return }
        let line = data + Data("\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: line, attributes: [.posixPermissions: 0o600])
        }
    }

    public func all() -> [Entry] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return text.split(whereSeparator: \.isNewline).compactMap { try? dec.decode(Entry.self, from: Data($0.utf8)) }
    }

    public func last() -> Entry? { all().last }

    /// Keeps the newest entries. Rewrites the file only when it is over the cap.
    public func trim(to cap: Int = History.cap) {
        let items = all()
        guard items.count > cap else { return }
        let keep = items.suffix(cap)
        let enc = JSONEncoder()
        let body = keep.compactMap { try? enc.encode($0) }.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n") + "\n"
        try? body.write(to: url, atomically: true, encoding: .utf8)
    }
}
