import Foundation

/// Makes a dictation fit the sentence it lands in (D-817). Mid-sentence, its first word starts lowercase ("and then
/// and we go", not "and then And we go"), except "I" and names. Right before a word, its closing full stop goes and
/// a space keeps the two apart. Used only when the box says what is around the cursor.
public enum Fit {
    /// `before`: a few characters just before the cursor ("" at the start of the box). `after`: the first character
    /// after the cursor or selection, nil at the end of the box. `keep`: names spelled as they must stay.
    public static func text(_ t: String, before: String, after: Character?, keep: Set<String>) -> String {
        var out = t
        if midSentence(before), let r = firstWord(out), shouldLower(String(out[r]), keep: keep) {
            out.replaceSubrange(r.lowerBound..<out.index(after: r.lowerBound), with: String(out[r.lowerBound]).lowercased())
        }
        if let a = after, a.isLetter || a.isNumber {
            let trimmed = out.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("."), !trimmed.hasSuffix("..") { out = String(trimmed.dropLast()) }
            if !(out.last?.isWhitespace ?? true) { out += " " }
        }
        return out
    }

    /// True when the text before the cursor ends inside a sentence: some text, and its last mark isn't . ! ? or a
    /// line break.
    static func midSentence(_ before: String) -> Bool {
        if before.last?.isNewline == true { return false }
        guard let last = before.last(where: { !$0.isWhitespace }) else { return false }
        if last.isNewline { return false }
        return !".!?…:".contains(last)
    }

    static func firstWord(_ s: String) -> Range<String.Index>? {
        guard let start = s.firstIndex(where: { $0.isLetter }) else { return nil }
        let end = s[start...].firstIndex(where: { !($0.isLetter || $0 == "'" || $0 == "’") }) ?? s.endIndex
        return start..<end
    }

    /// Lowercase only an ordinary capitalised word: not "I" and its forms, not a name from the list, not "NASA" or
    /// "iPhone"-style words.
    static func shouldLower(_ w: String, keep: Set<String>) -> Bool {
        guard let first = w.first, first.isUppercase else { return false }
        let bare = w.replacingOccurrences(of: "’", with: "'")
        if bare == "I" || bare.hasPrefix("I'") { return false }
        if keep.contains(where: { $0.split(separator: " ").first.map(String.init) == w }) { return false }
        if w.dropFirst().contains(where: { $0.isUppercase }) { return false }
        return true
    }
}
