import Foundation
import VoiceCore

func finishInBoxChecks(_ check: (String, Bool) -> Void) {
    // Replay the incident lengths using synthetic words only, never log or retain real dictation.
    for (label, length, draft) in [("T3", 54, " more words!!"), ("Chrome", 555, String(repeating: " word", count: 15) + " end")] {
        let confirmed = " early words"
        let prefix = String(repeating: "x", count: length - confirmed.utf16.count)
        let before = prefix + confirmed, actual = before + draft
        let start = BoxPrint(role: "AXTextArea", identifier: "box", frame: nil, text: before, title: "Chat", url: "chat://one")
        let attempt = DictationEnding.LateDraft(before: before, range: NSRange(location: length, length: 0), text: draft)
        func recover(actual value: String? = nil, focused: Bool = false, cursor: NSRange? = nil,
                     edited: Bool = false, sent: Bool = false, window: Bool = true, element: Bool = true,
                     now: BoxPrint? = nil, relaxed: Bool = true) -> (box: BoxPrint, text: String)? {
            DictationEnding.reconcileLateDraft(attempt, confirmedDrafts: confirmed, start: start, now: now ?? start,
                actual: value ?? actual, cursor: cursor, sameElement: element, sameWindow: window, userEdited: edited,
                inStartBox: focused, observedSend: sent, allowUnfocused: relaxed)
        }
        let match = recover()
        check("finish.\(label).incidentLength", actual.utf16.count == (label == "T3" ? 67 : 634))
        check("finish.\(label).unfocusedExactAdopted", match?.box.text == actual && match?.text == draft)
        check("finish.\(label).strictStillRequiresFocus", recover(relaxed: false) == nil)
        check("finish.\(label).focusedMovedCaretNotAdoptedYet", recover(focused: true, cursor: NSRange(location: 2, length: 0)) == nil)
        check("finish.\(label).focusedConfirmedCaretAdopted", recover(focused: true, cursor: NSRange(location: actual.utf16.count, length: 0)) != nil)
        check("finish.\(label).userKeyKeepsOldRule", recover(edited: true) == nil)
        check("finish.\(label).sendBlocksAdoption", recover(sent: true) == nil)
        check("finish.\(label).windowBlocksAdoption", recover(window: false) == nil)
        check("finish.\(label).elementBlocksAdoption", recover(element: false) == nil)
        check("finish.\(label).partialNotAdopted", recover(actual: before + String(draft.dropLast())) == nil)
        check("finish.\(label).editedPrefixNotAdopted", recover(actual: "edited " + actual) == nil)
        let switched = BoxPrint(role: "AXTextArea", identifier: "box", frame: nil, text: before, title: "Chat", url: "chat://two")
        check("finish.\(label).reusedConversationNotAdopted", recover(now: switched) == nil)
        let typed = confirmed + draft
        let range = FinishInBox.span(of: typed, in: actual)!
        let edit = DraftReplacement(expectedBox: actual, actual: actual, cursor: NSRange(location: NSMaxRange(range), length: 0),
                                    draft: typed, replacement: " All the checked words.", exactRange: range)
        check("finish.\(label).movedCaretEndingInPlace", edit?.expected == prefix + " All the checked words.")
        check("finish.\(label).elsewherePlanTakesBack", DictationEnding.plan(typedInStartBox: true, startBoxAsLeft: true, inStartBox: false) == .takeBackThenDeliver)
        check("finish.\(label).editedFirstBoxStillDelivers", DictationEnding.plan(typedInStartBox: true, startBoxAsLeft: false, inStartBox: false) == .deliver)
        check("finish.\(label).sentNeverDelivers", DictationEnding.plan(typedInStartBox: true, startBoxAsLeft: false, inStartBox: false, sent: true) == .keep)
    }
    let typed = " Voice words", checked = "Voice words are checked."
    let actual = "My edited heading. " + typed + " My pasted tail."
    let range = FinishInBox.span(of: typed, in: actual)!
    let replacement = DraftReplacement(expectedBox: actual, actual: actual,
        cursor: NSRange(location: NSMaxRange(range), length: 0), draft: typed,
        replacement: " " + checked, exactRange: range)
    check("finish.outsideEditsAndExtraSpacePreserved", replacement?.expected == "My edited heading.  Voice words are checked. My pasted tail.")
    check("finish.duplicateKeeps", FinishInBox.ending(typed: typed, checked: checked, actual: typed + typed, sent: false) == .keep)
    check("finish.overlappingDuplicateKeeps", FinishInBox.span(of: "...", in: "....") == nil)
    check("finish.uncertainKeeps", FinishInBox.ending(typed: typed, checked: checked, actual: actual, sent: false, uncertain: true) == .keep)
    check("finish.sentKeeps", FinishInBox.ending(typed: typed, checked: checked, actual: actual, sent: true) == .keep)
    check("finish.safeRemainingWords", FinishInBox.ending(typed: typed, checked: checked, actual: "Voice changed words", sent: false) == .append("are checked."))
    check("finish.noGuessAfterChangedCheckedPrefix", FinishInBox.remaining(typed: "I said last", checked: "We said last today") == nil)
    check("finish.noGuessAtRepeatedLastWord", FinishInBox.remaining(typed: "one end", checked: "some end one end more") == nil)
    check("finish.punctuationMustMatch", FinishInBox.remaining(typed: "Voice words.", checked: checked) == nil)
    check("finish.noExtraWhenAllTyped", FinishInBox.remaining(typed: "Voice words", checked: "Voice words") == nil)
    check("finish.unicodeLiteral", FinishInBox.span(of: "Café", in: "Cafe\u{0301}") == nil)
    check("finish.whitespaceLiteral", FinishInBox.span(of: "one two", in: "one  two") == nil)
    check("finish.noPartialWord", FinishInBox.span(of: "word", in: "sword") == nil)
    check("finish.noPartialGrapheme", FinishInBox.span(of: "👩", in: "👩‍💻") == nil)
    let emoji = "Mine 🎉 Voice words tail"
    check("finish.utf16Span", FinishInBox.span(of: " Voice words", in: emoji) == NSRange(location: 7, length: 12))
    func resumes(focused: Bool = true, sent: Bool = false, edited: Bool = false, key: Bool = false,
                 uncertain: Bool = false, long: Bool = false, age: Double = 0.15, cursor: Int = 15,
                 value: String = "old Voice words") -> Bool {
        FinishInBox.mayResume(typed: typed, expected: "old Voice words", actual: value, cursor: NSRange(location: cursor, length: 0),
            focused: focused, sent: sent, userEdited: edited, keyPressed: key, uncertain: uncertain, longTalk: long, mouseAge: age)
    }
    check("finish.resumeAtOwnEnd", resumes())
    check("finish.noResumeElsewhere", !resumes(focused: false))
    check("finish.noResumeMovedCursor", !resumes(cursor: 3))
    check("finish.noResumeKey", !resumes(key: true))
    check("finish.noResumeEdited", !resumes(edited: true))
    check("finish.noResumeSent", !resumes(sent: true))
    check("finish.noResumeUncertain", !resumes(uncertain: true))
    check("finish.noResumeLong", !resumes(long: true))
    check("finish.noResumeBeforeSettle", !resumes(age: 0.149))
    check("finish.noResumeChangedValue", !resumes(value: "old Voice words more"))
    let caret = NSRange(location: 3, length: 0)
    func paste(_ first: String?, _ settled: String?, same: Bool = true, pasted: Bool = false, cursor: NSRange? = nil) -> Bool {
        FinishInBox.mayPaste(before: "old", first: first, settled: settled, range: caret,
            currentRange: cursor ?? caret, sameTarget: same, alreadyPasted: pasted)
    }
    check("finish.ChromeUnchangedPastesOnce", paste("old", "old"))
    check("finish.noSecondPaste", !paste("old", "old", pasted: true))
    check("finish.partialNoPaste", !paste("old a", "old a"))
    check("finish.lateArrivalNoPaste", !paste("old", "old all words"))
    check("finish.partialThenRevertedNoPaste", !paste("old a", "old"))
    check("finish.unreadableNoPaste", !paste(nil, "old"))
    check("finish.movedFocusNoPaste", !paste("old", "old", same: false))
    check("finish.movedCursorNoPaste", !paste("old", "old", cursor: NSRange(location: 0, length: 0)))
    check("finish.selectionNoPaste", !FinishInBox.mayPaste(before: "old", first: "old", settled: "old",
        range: NSRange(location: 0, length: 3), currentRange: NSRange(location: 0, length: 3), sameTarget: true))
    check("finish.FnCompanionTalk", DraftInput.isTalkKey(179, configured: [63]))
    check("finish.FnCompanionNotBlanketExemption", !DraftInput.isTalkKey(179, configured: [61]))
    check("finish.actualTalkKey", DraftInput.isTalkKey(61, configured: [61]))
    check("finish.realLetterStillTyping", !DraftInput.isTalkKey(0, configured: [63]))
    check("finish.pausedCaptionTruthful", TalkingWords.stoppedLine(.paused, words: 17) == "Typing paused. 17 words so far. Return to keep typing.")
}
