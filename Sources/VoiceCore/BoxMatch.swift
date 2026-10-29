import CoreGraphics
import Foundation

/// The box a dictation started in. Window titles describe a window, not a conversation: a web app's URL
/// identifies the conversation. Text is the full expected value, updated only by edits Voice itself made.
public struct BoxPrint: Equatable, Sendable {
    public let role: String?
    public let identifier: String?
    public let frame: CGRect?
    public private(set) var text: String?
    public let title: String?
    public let url: String?
    public init(role: String?, identifier: String?, frame: CGRect?, text: String?, title: String? = nil, url: String? = nil) {
        self.role = role; self.identifier = identifier; self.frame = frame; self.text = text; self.title = title; self.url = url
    }

    /// Advance only from the text we expected, by a known Voice edit. Never adopt arbitrary Accessibility text.
    @discardableResult
    public mutating func recordEdit(before: String, range: NSRange, replacement: String) -> Bool {
        guard text == before, range.location >= 0, range.length >= 0,
              range.location <= before.utf16.count, range.length <= before.utf16.count - range.location else { return false }
        text = (before as NSString).replacingCharacters(in: range, with: replacement)
        return true
    }

    /// Draft checks delete and retype a known suffix, including any later drafts.
    public mutating func replaceBeforeCursor(_ old: String, with new: String, cursor: Int) {
        guard let before = text, cursor >= old.utf16.count, cursor <= before.utf16.count else { return }
        let range = NSRange(location: cursor - old.utf16.count, length: old.utf16.count)
        guard (before as NSString).substring(with: range) == old else { return }
        recordEdit(before: before, range: range, replacement: new)
    }
}

public enum BoxMatch {
    public enum Failure: String, Sendable {
        case window, url, title, element, frame
        case text = "text prefix/value"
    }

    public static func same(start: BoxPrint, now: BoxPrint, nowText: String?, sameElement: Bool, sameWindow: Bool = true, userEdited: Bool = false) -> Bool {
        failure(start: start, now: now, nowText: nowText, sameElement: sameElement, sameWindow: sameWindow, userEdited: userEdited) == nil
    }

    /// Check the conversation even for a nonempty box and even when the app reuses the same AX element.
    /// A changed title is harmless when the URL and actual window still match. Without a URL an empty box
    /// needs an unchanged title; there is no other evidence that it belongs to the same conversation.
    public static func failure(start: BoxPrint, now: BoxPrint, nowText: String?, sameElement: Bool, sameWindow: Bool = true, userEdited: Bool = false) -> Failure? {
        guard sameWindow else { return .window }
        if start.url != now.url { return .url }
        if userEdited { return .text }
        if start.url == nil, start.title != now.title { return .title }
        if let text = start.text {
            guard nowText == text else { return .text }
        } else if !sameElement { return .text }
        if (start.text ?? "").isEmpty, start.url == nil {
            guard let title = start.title, !title.isEmpty, title == now.title else { return .title }
        }
        // The same AX element in the same window can grow or move. Geometry is only a fallback for a recreated element.
        if sameElement { return nil }
        guard start.role != nil, start.role == now.role else { return .element }
        if let a = start.identifier, !a.isEmpty, a == now.identifier { return nil }
        if let a = start.frame, let b = now.frame, abs(a.minX - b.minX) <= 12, abs(a.width - b.width) <= 12,
           abs(a.minY - b.minY) <= 12 || abs(a.maxY - b.maxY) <= 12 { return nil }
        return .frame
    }

    /// Names only, never text, titles or URLs, for diagnostics on both rejected and tolerated changes.
    public static func differences(start: BoxPrint, now: BoxPrint, nowText: String?, sameElement: Bool) -> [String] {
        var parts: [String] = []
        if start.frame != now.frame { parts.append("frame") }
        if start.title != now.title { parts.append("title") }
        if start.url != now.url { parts.append("url") }
        if start.text != nowText { parts.append("text prefix/value") }
        if !sameElement { parts.append("element") }
        return parts
    }
}
