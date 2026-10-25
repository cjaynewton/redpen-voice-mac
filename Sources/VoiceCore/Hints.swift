import Foundation

/// The words Whisper is told to expect at the start of a dictation: names from your list and names on screen near
/// the cursor (the box you're typing in and the window title). Used once as a hint, never stored or logged.
public enum Hints {
    /// Names-like words in on-screen text: a capital after the first letter of a sentence, a digit, or code-like
    /// marks (Claude Code, GitHub, v0.11, file_name.swift). Newest last, at most `limit`.
    public static func fromScreen(_ text: String, limit: Int = 25) -> [String] {
        let tail = String(text.suffix(3000))
        var out: [String] = []
        var seen = Set<String>()
        var sentenceStart = true
        for raw in tail.split(whereSeparator: { $0.isWhitespace }) {
            let w = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’()[]{}<>,;:!?."))
            defer { sentenceStart = raw.last.map { ".!?\n".contains($0) } ?? false }
            guard w.count >= 3, w.count <= 40, w.first?.isLetter == true else { continue }
            let codeLike = w.contains(where: { "_/.".contains($0) })
            let capital = (w.first?.isUppercase == true && !sentenceStart) || w.dropFirst().contains(where: \.isUppercase)
            guard capital || w.contains(where: \.isNumber) || codeLike else { continue }
            if seen.insert(w.lowercased()).inserted { out.append(w) }
        }
        return Array(out.suffix(limit))
    }

    /// One prompt line: your list's names first (they are yours for good), then what's on screen.
    public static func line(names: [String], screen: [String], limit: Int = 40) -> String {
        var seen = Set<String>(), out: [String] = []
        for w in names + screen where seen.insert(w.lowercased()).inserted { out.append(w) }
        return out.prefix(limit).joined(separator: ", ")
    }
}
