import Foundation

/// Editors trim edges, exchange NBSP for spaces and collapse whitespace. Word boundaries, letters,
/// punctuation and case still have to match. Removing the space between two words is a real change.
public enum BoxText {
    public static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func same(_ expected: String, _ actual: String) -> Bool {
        expected == actual || normalized(expected) == normalized(actual)
    }
}

/// A known draft suffix mapped onto the editor's actual characters. Never delete by the unnormalized
/// draft length: a trimmed space would delete a character belonging to the text before the dictation.
public struct DraftReplacement {
    public let before: String
    public let range: NSRange
    public let replacement: String
    public let expected: String

    public init?(expectedBox: String, actual: String, cursor: NSRange, draft: String, replacement: String) {
        guard BoxText.same(expectedBox, actual), cursor.length == 0, cursor.location >= 0,
              cursor.location <= actual.utf16.count else { return nil }
        let prefix = (actual as NSString).substring(to: cursor.location)
        let words = prefix.split(whereSeparator: \.isWhitespace)
        let wanted = draft.split(whereSeparator: \.isWhitespace)
        guard !wanted.isEmpty, words.count >= wanted.count,
              words.suffix(wanted.count).elementsEqual(wanted) else { return nil }
        var start = words[words.count - wanted.count].startIndex
        if draft.first?.isWhitespace == true {
            while start > prefix.startIndex {
                let previous = prefix.index(before: start)
                guard prefix[previous].isWhitespace else { break }
                start = previous
            }
        }
        let offset = start.utf16Offset(in: prefix)
        self.before = actual
        range = NSRange(location: offset, length: cursor.location - offset)
        self.replacement = replacement
        expected = (actual as NSString).replacingCharacters(in: range, with: replacement)
    }

    public func landed(_ value: String?) -> Bool {
        value.map { BoxText.same(expected, $0) } ?? false
    }
}
