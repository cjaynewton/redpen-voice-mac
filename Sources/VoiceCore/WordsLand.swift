import Foundation

/// D-1603 (Nov 12 2026): when you finish, the words go where the cursor is, the way Monologue and Wispr Flow do. They
/// are held for Paste last in two cases only. One: the cursor is not in a text box, and they wait for a click into
/// one. Two: Voice saw Enter or a send go into the box this dictation's words were in. No other check holds them:
/// not a changed window, title or address, not a start box Voice couldn't check, not a click or key while you talked,
/// not a draft it couldn't confirm, not a box that reads empty. Pure decisions, so a logged failure can be replayed.
public enum WordsLand {
    public enum Outcome: Equatable {
        /// The cursor is not in a text box: the words wait for a click into one.
        case waitForClick
        /// A send was seen in the box the early words went into: nothing is typed again. Paste last has the words.
        case hold
        /// The words go into the cursor's box, in the way `FinishInBox.landing` names.
        case land(FinishInBox.Landing)
    }

    /// `focus`, `ownWindow`: what the cursor is in now. `sendSeen`: Enter or a send was seen going into the box this
    /// dictation's early words went into. `typed`, `late`: those early words, confirmed and not. `sameBox`: the
    /// cursor is in that box and conversation. `boxText`: what the cursor's box reads, nil when it won't say.
    public static func decide(focus: FocusKind, ownWindow: Bool = false, sendSeen: Bool, typed: String, late: String = "",
                              sameBox: Bool, boxText: String?, checked: String, canSwap: Bool = true) -> Outcome {
        func blank(_ t: String) -> Bool { t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let inBox = DictationEnding.typesNow(kind: focus, ownWindow: ownWindow)
        // A send holds only words that went out with it. Nothing typed early: nothing was sent, the words land.
        if sendSeen, !blank(typed) || !blank(late) {
            // Enter after the words were in (07:11:31, Nov 12): the box already holds the checked text. Landed.
            if inBox, sameBox, let boxText,
               FinishInBox.landing(typed: typed, late: late, checked: checked, actual: boxText, sameBox: true) == .already {
                return .land(.already)
            }
            return .hold
        }
        guard inBox else { return .waitForClick }
        // A box that won't say what it holds still takes the words.
        guard let boxText else { return .land(.whole) }
        return .land(FinishInBox.landing(typed: typed, late: late, checked: checked, actual: boxText,
                                         sameBox: sameBox, canSwap: canSwap))
    }

    /// Why a finishing attempt left the words out of the box, and what happens to them.
    public enum NotLanded: Equatable {
        /// Escape threw the dictation away.
        case discarded
        /// A newer press owns the bar. Paste last has these words.
        case newerPress
        /// Enter or a send was seen in the box while the words were going in.
        case sendSeen
        /// Nothing arrived and the cursor is not in a real text box: the words wait for a click into one.
        case waitForClick
        /// Typing was tried, and the one paste where the two reads allowed it, and the box didn't confirm. The bar
        /// says to check the box, and Paste last has the words.
        case checkTheBox
    }

    /// `leftNothing`: the attempt was refused before typing, or two reads show the box exactly as it was. `focus`:
    /// what the cursor is in after the attempt. A place Accessibility can't name (an Electron app's page) gets one
    /// try, as at release; when nothing arrives there the words wait for a click into a real text box.
    public static func notLanded(cancelled: Bool, newer: Bool, sendSeen: Bool, leftNothing: Bool, focus: FocusKind) -> NotLanded {
        if cancelled { return .discarded }
        if newer { return .newerPress }
        if sendSeen { return .sendSeen }
        if leftNothing, focus != .text { return .waitForClick }
        return .checkTheBox
    }

    public static let checkNote = "Didn't see it land. Check the box. ⌃⌥V has it"
}
