import Foundation

/// Finds the words you fixed by hand after a dictation went in: what Voice typed against what the box holds now.
/// Only small, word-for-word swaps count ("so well" became "Sowell"); a sentence you rewrote, or words you added
/// before or after, teach nothing. A swap is learned only after the same one happens twice (Learned).
public enum Corrections {
    public struct Fix: Equatable, Hashable, Codable, Sendable {
        public let heard: String
        public let fixed: String
        public init(heard: String, fixed: String) { self.heard = heard; self.fixed = fixed }
    }

    /// Words with their punctuation trimmed, for comparing; the originals are kept for what gets learned.
    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    static func key(_ w: String) -> String {
        w.trimmingCharacters(in: .punctuationCharacters.union(.symbols)).lowercased()
    }

    /// The swaps between what was typed and the box now. Nil-safe: an empty or unrelated box gives none.
    public static func find(typed: String, now box: String) -> [Fix] {
        let a = words(typed), b = words(box)
        guard a.count >= 2, !b.isEmpty, a.count <= 150, b.count <= 3000 else { return [] }
        // Where in the box the dictation sits now: the stretch that differs least from what was typed.
        let ka = a.map(key), kb = b.map(key)
        var starts = Set<Int>()
        for (j, w) in kb.enumerated() where w == ka[0] || w == ka[1] { starts.insert(j); starts.insert(max(0, j - 1)) }
        if starts.isEmpty { return [] }
        var best: (cost: Int, start: Int, end: Int)?
        for len in max(1, a.count - 3)...(a.count + 3) where len <= b.count {
            // Only where the dictation could start: its first or second word, or the word before it was fixed.
            for start in 0...(b.count - len) where starts.contains(start) {
                let c = distance(ka, Array(kb[start..<(start + len)]))
                if best == nil || c < best!.cost { best = (c, start, start + len) }
            }
        }
        guard let best, best.cost > 0 else { return [] }
        // Mostly the same words, or it's a rewrite and nothing should be learned from it.
        guard Double(best.cost) <= max(1, Double(a.count) * 0.3) else { return [] }
        return swaps(a, Array(b[best.start..<best.end]))
    }

    /// Word-level edit distance.
    static func distance(_ a: [String], _ b: [String]) -> Int {
        var prev = Array(0...b.count)
        for i in 1...max(1, a.count) where !a.isEmpty {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in stride(from: 1, through: b.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return a.isEmpty ? b.count : prev[b.count]
    }

    /// Runs of changed words between two matching words, one or two words on each side ("claw code" -> "Claude Code",
    /// "so well" -> "Sowell"). A change in case or punctuation alone is not a fix.
    static func swaps(_ a: [String], _ b: [String]) -> [Fix] {
        let ka = a.map(key), kb = b.map(key)
        // Longest common subsequence as anchors.
        var lcs = Array(repeating: Array(repeating: 0, count: kb.count + 1), count: ka.count + 1)
        for i in stride(from: ka.count - 1, through: 0, by: -1) {
            for j in stride(from: kb.count - 1, through: 0, by: -1) {
                lcs[i][j] = ka[i] == kb[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        // The alignment as steps: a word kept, a word kept with new capitals ("code" -> "Code"), or a changed run.
        enum Step { case same, recased(String, String), changed([String], [String]) }
        var steps: [Step] = []
        var i = 0, j = 0, gapA: [String] = [], gapB: [String] = []
        func close() { if !gapA.isEmpty || !gapB.isEmpty { steps.append(.changed(gapA, gapB)) }; gapA = []; gapB = [] }
        while i < ka.count || j < kb.count {
            if i < ka.count, j < kb.count, ka[i] == kb[j] {
                close()
                let x = a[i].trimmingCharacters(in: .punctuationCharacters), y = b[j].trimmingCharacters(in: .punctuationCharacters)
                steps.append(x == y ? .same : .recased(x, y))
                i += 1; j += 1
            }
            else if j < kb.count, (i == ka.count || lcs[i][j + 1] >= lcs[i + 1][j]) { gapB.append(b[j]); j += 1 }
            else { gapA.append(a[i]); i += 1 }
        }
        close()
        // A word re-capitalised right beside a change belongs to the name: "claw code" -> "Claude Code" is learned
        // whole, never "claw" -> "Claude" (which would change every claw).
        var out: [Fix] = []
        for (n, step) in steps.enumerated() {
            guard case .changed(var ga, var gb) = step else { continue }
            if n > 0, case .recased(let x, let y) = steps[n - 1] { ga.insert(x, at: 0); gb.insert(y, at: 0) }
            if n + 1 < steps.count, case .recased(let x, let y) = steps[n + 1] { ga.append(x); gb.append(y) }
            guard (1...3).contains(ga.count), (1...3).contains(gb.count) else { continue }
            let heard = ga.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
            let fixed = gb.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
            if !heard.isEmpty, !fixed.isEmpty, heard.lowercased() != fixed.lowercased() { out.append(Fix(heard: heard, fixed: fixed)) }
        }
        return out
    }
}

/// Fixes seen so far, counted, kept on this Mac (learned.json). The second time the same fix is seen it is learned:
/// it goes into your word list, where you can read it and delete it like any other line.
public struct Learned: Codable, Sendable {
    public var seen: [String: Int] = [:]
    public var learned: [String] = []
    public init() {}

    public static let times = 2

    static func id(_ f: Corrections.Fix) -> String { f.heard.lowercased() + " = " + f.fixed }

    /// Counts a fix. Returns it when this sighting is the one that teaches it.
    public mutating func see(_ f: Corrections.Fix) -> Bool {
        let k = Self.id(f)
        guard !learned.contains(k) else { return false }
        seen[k, default: 0] += 1
        guard seen[k]! >= Self.times else { return false }
        learned.append(k); seen[k] = nil
        return true
    }

    public static func load(_ url: URL) -> Learned {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Learned.self, from: $0) } ?? Learned()
    }

    public func save(_ url: URL) {
        guard let d = try? JSONEncoder().encode(self) else { return }
        try? d.write(to: url, options: .atomic)
    }
}
