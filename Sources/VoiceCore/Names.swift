import Foundation

/// Words the engine gets wrong on every model: names, products, your own terms. Each line in the list is
/// `heard = meant` ("claw code = Claude Code") or just a word to keep as written. Replacement is whole-word
/// and ignores case, so "claw code" in the middle of a sentence becomes "Claude Code" and "clawed" is left alone.
public struct Names: Equatable {
    public struct Entry: Equatable { public let heard: String; public let meant: String }
    public private(set) var entries: [Entry] = []

    public init(text: String) {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty { entries.append(Entry(heard: parts[0], meant: parts[1])) }
            else if parts.count == 1 { entries.append(Entry(heard: parts[0], meant: parts[0])) }
        }
    }

    /// The words the engine should listen for. Both halves of every entry, so the engine has a chance to
    /// get the real name first and the replacement is only a net.
    public var vocabulary: [String] { Array(Set(entries.flatMap { [$0.heard, $0.meant] })).sorted() }
    /// Only the right spellings, for Whisper's hint: telling it the misheard form would teach it the wrong one.
    public var spellings: [String] { var seen = Set<String>(); return entries.map(\.meant).filter { seen.insert($0.lowercased()).inserted } }

    public func apply(_ text: String) -> String {
        var out = text
        // Longest first, so "claw code" wins over "claw".
        for e in entries.sorted(by: { $0.heard.count > $1.heard.count }) {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: e.heard) + "(?![\\p{L}\\p{N}])"
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: e.meant))
        }
        return out
    }
}
