import CoreGraphics
import Foundation

/// Whether the text box in front now is the one a dictation started in (D-817). Chat apps reuse their typing box and
/// T3 has several, so "a text box in the same window" sent words to the wrong one. A different element counts only
/// when it is clearly the same box; in every case the box must still start with the text it had at key-down (a sent
/// and cleared box fails). When in doubt the words wait, and Paste last has them.
public struct BoxPrint: Equatable, Sendable {
    public let role: String?
    public let identifier: String?
    public let frame: CGRect?
    /// The start of the box's text at key-down (up to 200 characters), nil when the box won't say.
    public let prefix: String?
    public init(role: String?, identifier: String?, frame: CGRect?, prefix: String?) {
        self.role = role; self.identifier = identifier; self.frame = frame; self.prefix = prefix
    }
}

public enum BoxMatch {
    public static let prefixLength = 200

    /// `sameElement`: Accessibility hands back the very element. `nowText`: the box's text now, nil when unreadable.
    public static func same(start: BoxPrint, now: BoxPrint, nowText: String?, sameElement: Bool) -> Bool {
        // The box was emptied or rewritten since key-down (a message sent, a different conversation): not the box.
        if let p = start.prefix {
            guard let t = nowText, t.hasPrefix(p) else { return false }
        } else if !sameElement {
            return false  // a different element whose text can't be compared: never guess
        }
        if sameElement { return true }
        guard start.role != nil, start.role == now.role else { return false }
        if let a = start.identifier, !a.isEmpty, a == now.identifier { return true }
        // Same left edge and width, and the same top or bottom: a chat box grows upward as you type, a document's
        // box grows downward.
        if let a = start.frame, let b = now.frame, abs(a.minX - b.minX) <= 2, abs(a.width - b.width) <= 2,
           abs(a.minY - b.minY) <= 2 || abs(a.maxY - b.maxY) <= 2 { return true }
        return false
    }
}
