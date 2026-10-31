import Foundation

/// Where a finished dictation's words go (D-965, Oct 30 2026). The text box the cursor is in when it finishes takes
/// them, whichever app. Not in a text box (a web page, a video, a control): nothing is typed there, and the words
/// wait for the next click into one. This replaced sending the words back to the box you started in.
public enum DictationEnding {
    public enum Plan: Equatable, Sendable {
        /// Still in the box Voice typed into, and it reads exactly as Voice left it: the ending goes in there
        /// (drafts swapped for the checked text, or the rest after the pieces already typed).
        case inPlace
        /// Moved away, and the first box reads exactly as Voice left it: Voice's words come back out of it, and the
        /// whole checked dictation goes where you are.
        case takeBackThenDeliver
        /// Nothing of this dictation's typed into the first box, or you edited or sent it, or it can't be checked:
        /// it is left alone, and the whole checked dictation goes where you are.
        case deliver
    }

    /// `typedInStartBox`: words of this dictation were typed into the box you started in while you talked.
    /// `startBoxAsLeft`: that box still reads exactly as Voice left it (same window and conversation, the text Voice
    /// expects, no key of yours typed in it). A key or click elsewhere doesn't change it; an edit or a send does.
    /// `inStartBox`: it is the focused box in the app in front now.
    public static func plan(typedInStartBox: Bool, startBoxAsLeft: Bool, inStartBox: Bool) -> Plan {
        guard typedInStartBox, startBoxAsLeft else { return .deliver }
        return inStartBox ? .inPlace : .takeBackThenDeliver
    }

    /// Back in, or still in, the box this dictation typed into after it changed: only a sent box (empty, or the one
    /// stray character some apps leave) takes the whole dictation. An edited box still holds Voice's words, so typing
    /// the whole dictation there would repeat them.
    public static func sentBoxTakesWhole(_ value: String?) -> Bool {
        guard let value else { return false }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).count <= 1
    }

    /// Words waiting for a click wait this long. A new dictation ends the wait sooner; Paste last keeps them.
    public static let waitSeconds: TimeInterval = 600

    /// The bar while words wait (D-987, Oct 31 2026). It stays up the whole wait and asks, with two buttons. Copy puts
    /// the words on the clipboard; Throw away types them nowhere. Either way Paste last still has them. It was a
    /// 3 second note, then nothing for 10 minutes.
    public static let waitQuestion = "No box here. Click where your words go"
    public static let copyButton = "Copy"
    public static let throwAwayButton = "Throw away"
    public static let copiedNote = "Copied"
    public static let thrownAwayNote = "Not typed. ⌃⌥V still has them"

    /// Straight after a dictation: anything but a page, a control or Voice's own window takes the words now.
    public static func typesNow(kind: FocusKind, ownWindow: Bool) -> Bool { !ownWindow && kind != .notText }

    /// While words wait, a place that never takes them: Voice's own windows, a page or a control, and in a browser
    /// anything short of a real text box (a failed read on a page must never release the words).
    public static func waitRefuses(kind: FocusKind, inBrowser: Bool, ownWindow: Bool) -> Bool {
        ownWindow || kind == .notText || (kind == .unknown && inBrowser)
    }

    /// A real text box takes waiting words at once. A box Accessibility can't name (Electron apps) must be seen in
    /// the same app twice in a row, so the moment between two apps doesn't count.
    public static func waitTakes(kind: FocusKind, seenInARow: Int) -> Bool { kind == .text || seenInARow >= 2 }
}
