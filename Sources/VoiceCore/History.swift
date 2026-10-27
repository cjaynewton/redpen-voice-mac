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
    /// The newest dictation that has words. A press that caught nothing is kept in the history but never pasted:
    /// Paste last used to land on those and paste nothing.
    public func lastSpoken() -> Entry? { all().last { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }

    /// Keeps the newest entries. Rewrites the file only when it is over the cap.
    public func trim(to cap: Int = History.cap) {
        let items = all()
        guard items.count > cap else { return }
        rewrite(Array(items.suffix(cap)))
    }

    /// Writes the file anew with these entries, readable only by you (the same as when it was first made).
    public func rewrite(_ items: [Entry]) {
        let enc = JSONEncoder()
        let body = items.compactMap { try? enc.encode($0) }.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")
        let data = Data((body.isEmpty ? "" : body + "\n").utf8)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Removes one dictation (D-825, the history window).
    public func remove(_ e: Entry) {
        var items = all()
        guard let i = items.firstIndex(of: e) else { return }
        items.remove(at: i)
        rewrite(items)
    }

    /// How long dictations are kept (D-825): "all" (the newest 2,000), "week" (the last seven days) or "none".
    public static func kept(_ items: [Entry], keep: String, now: Date = Date()) -> [Entry] {
        switch keep {
        case "none": return []
        case "week": return items.filter { now.timeIntervalSince($0.date) <= 7 * 24 * 3600 }
        default: return Array(items.suffix(cap))
        }
    }

    /// Applies the choice to the file now, rewriting it only when something goes.
    public func apply(keep: String, now: Date = Date()) {
        let items = all()
        let k = History.kept(items, keep: keep, now: now)
        if k.count != items.count { rewrite(k) }
    }
}
