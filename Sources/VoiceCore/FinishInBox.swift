import Foundation

/// Literal ownership proof for a finishing edit. No AX calls or input events.
public enum FinishInBox {
    public static let mouseSettle = 0.150

    public static func exact(_ a: String, _ b: String) -> Bool { a.utf16.elementsEqual(b.utf16) }

    /// Exactly one complete span, including its recorded whitespace. Never expand into a neighbour's space.
    public static func span(of typed: String, in actual: String) -> NSRange? {
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let haystack = Array(actual.utf16), needle = Array(typed.utf16)
        guard haystack.count >= needle.count else { return nil }
        var found: NSRange?
        for i in 0...(haystack.count - needle.count) where haystack[i..<(i + needle.count)].elementsEqual(needle) {
            let range = NSRange(location: i, length: needle.count)
            guard let r = Range(range, in: actual),
                  (r.lowerBound == actual.endIndex || actual.indices.contains(r.lowerBound)),
                  (r.upperBound == actual.endIndex || actual.indices.contains(r.upperBound)) else { return nil }
            // A whole word must not turn into the middle of another word.
            if typed.first?.isLetter == true || typed.first?.isNumber == true,
               r.lowerBound > actual.startIndex {
                let previous = actual[actual.index(before: r.lowerBound)]
                if previous.isLetter || previous.isNumber { continue }
            }
            if typed.last?.isLetter == true || typed.last?.isNumber == true,
               r.upperBound < actual.endIndex {
                let next = actual[r.upperBound]
                if next.isLetter || next.isNumber { continue }
            }
            guard found == nil else { return nil }
            found = range
        }
        return found
    }

    /// A missing span permits only an exact checked-word prefix. Matching a last word alone is ambiguous.
    public static func remaining(typed: String, checked: String) -> String? {
        let before = typed.split(whereSeparator: \.isWhitespace)
        let after = checked.split(whereSeparator: \.isWhitespace)
        guard !before.isEmpty, after.count > before.count,
              zip(before, after).allSatisfy({ exact(String($0.0), String($0.1)) }) else { return nil }
        return String(checked[after[before.count].startIndex...])
    }

    public enum Ending: Equatable { case replace(NSRange), append(String), keep }
    public static func ending(typed: String, checked: String, actual: String, sent: Bool,
                              uncertain: Bool = false) -> Ending {
        guard !sent, !uncertain else { return .keep }
        if let range = span(of: typed, in: actual) { return .replace(range) }
        // If the literal span is present but repeated, never turn ambiguity into an append.
        guard actual.range(of: typed, options: .literal) == nil,
              let rest = remaining(typed: typed, checked: checked) else { return .keep }
        return .append(rest)
    }

    public static func mayResume(typed: String, expected: String?, actual: String?, cursor: NSRange?,
                                 focused: Bool, sent: Bool, userEdited: Bool, keyPressed: Bool,
                                 uncertain: Bool, longTalk: Bool, mouseAge: Double) -> Bool {
        guard focused, !sent, !userEdited, !keyPressed, !uncertain, !longTalk,
              mouseAge >= mouseSettle, let expected, let actual, exact(expected, actual),
              let cursor, cursor.length == 0 else { return false }
        if typed.isEmpty { return cursor.location >= 0 && cursor.location <= actual.utf16.count }
        guard let span = span(of: typed, in: actual) else { return false }
        return cursor.location == NSMaxRange(span)
    }

    /// Two readable, unchanged values and the original insertion point are required. Any partial arrival vetoes.
    public static func mayPaste(before: String?, first: String?, settled: String?, range: NSRange?,
                                currentRange: NSRange?, sameTarget: Bool, alreadyPasted: Bool = false) -> Bool {
        guard sameTarget, !alreadyPasted, let before, let first, let settled, let range,
              range.length == 0, range == currentRange else { return false }
        return exact(before, first) && exact(before, settled)
    }
}
