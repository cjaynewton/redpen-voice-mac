import Foundation

/// Words worth a second look (D-817, a test, off unless switched on): where the second engine heard a "not", a
/// number, a name from your list, or the first or last three words differently. Ordinary disagreements are left
/// alone; they happen in about half of all dictations.
public struct RiskyMark: Equatable, Sendable {
    /// "negation", "number", "name" or "edge".
    public let kind: String
    /// The words as they went in, and as the other engine heard them.
    public let heard: String
    public let other: String
    /// The dictation with the other hearing swapped in at that place.
    public let swapped: String
}

public enum RiskyWords {
    static func key(_ w: Substring) -> String {
        w.lowercased().replacingOccurrences(of: "’", with: "'").filter { $0.isLetter || $0.isNumber || $0 == "'" }
    }

    /// The marks, most important kind first. `names`: your word list's spellings.
    public static func find(final: String, other: String, names: Set<String>) -> [RiskyMark] {
        let a = final.split(whereSeparator: \.isWhitespace), b = other.split(whereSeparator: \.isWhitespace)
        let ka = a.map(key), kb = b.map(key)
        guard !ka.isEmpty, !kb.isEmpty, ka.count <= 400, kb.count <= 400 else { return [] }
        let nameWords = Set(names.flatMap { $0.split(separator: " ").map { key($0) } })
        // Longest common subsequence, then the stretches between matches are the disagreements.
        var lcs = Array(repeating: Array(repeating: 0, count: kb.count + 1), count: ka.count + 1)
        for i in stride(from: ka.count - 1, through: 0, by: -1) {
            for j in stride(from: kb.count - 1, through: 0, by: -1) {
                lcs[i][j] = ka[i] == kb[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var spans: [(Range<Int>, Range<Int>)] = []
        var i = 0, j = 0, si = 0, sj = 0
        func close() { if i > si || j > sj { spans.append((si..<i, sj..<j)) } }
        while i < ka.count || j < kb.count {
            if i < ka.count, j < kb.count, ka[i] == kb[j] { close(); i += 1; j += 1; si = i; sj = j }
            else if j < kb.count, i == ka.count || lcs[i][j + 1] >= lcs[i + 1][j] { j += 1 }
            else { i += 1 }
        }
        close()
        var marks: [RiskyMark] = []
        for (ra, rb) in spans {
            let wa = ra.map { ka[$0] }, wb = rb.map { kb[$0] }
            let both = wa + wb
            let kind: String
            if both.contains(where: { Meaning.negations.contains($0) || $0.hasSuffix("n't") }) { kind = "negation" }
            else if both.contains(where: { $0.first?.isNumber == true || Meaning.numberWords[$0] != nil }) { kind = "number" }
            else if both.contains(where: { nameWords.contains($0) }) { kind = "name" }
            else if ra.lowerBound < 3 || ra.upperBound > ka.count - 3 { kind = "edge" }
            else { continue }
            var out = a.map(String.init)
            out.replaceSubrange(ra, with: rb.map { String(b[$0]) })
            marks.append(RiskyMark(kind: kind, heard: ra.map { String(a[$0]) }.joined(separator: " "),
                                   other: rb.map { String(b[$0]) }.joined(separator: " "), swapped: out.joined(separator: " ")))
        }
        let order = ["negation": 0, "number": 1, "name": 2, "edge": 3]
        return marks.sorted { order[$0.kind]! < order[$1.kind]! }
    }
}
