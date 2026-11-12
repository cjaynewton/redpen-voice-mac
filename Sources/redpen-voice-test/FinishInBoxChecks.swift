import CoreGraphics
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

    // D-1603 (Nov 12 2026): words always land where the cursor is. Synthetic words only.
    func land(_ typed: String, _ checked: String, _ actual: String, late: String = "", same: Bool = true) -> FinishInBox.Landing {
        FinishInBox.landing(typed: typed, late: late, checked: checked, actual: actual, sameBox: same)
    }
    // 1. Back in the box you started in: one span of the early words swaps in place, with your edits around it kept.
    check("d1603.swapUniqueSpan", land(" one two", "One two three.", "Mine one two") == .swap(NSRange(location: 4, length: 8)))
    check("d1603.swapKeepsEditsAround", land(" one two", "One two three.", "Edited one two tail") == .swap(NSRange(location: 6, length: 8)))
    check("d1603.rebuiltWhitespaceBoxSwaps", land("one two", "One two three.", "one two ") == .swap(NSRange(location: 0, length: 7)))
    // Edited early words: only the words said after them go in. Never the whole dictation after them.
    check("d1603.editedLandsOnlyTheRest", land("one two three", "One two three four five.", "one TWO, three") == .rest("four five."))
    check("d1603.editedAlignsOnLastWords", land("won two three", "One, two three four five.", "one two three") == .rest("four five."))
    check("d1603.editedNothingAfter", land("one two three", "One two three.", "one two  three!") == .already)
    check("d1603.editedCheckedDroppedAWord", land("one two two three", "One two three four.", "one two two, three") == .rest("four."))
    // None of the early words left: the whole checked text goes in.
    check("d1603.draftsDeletedLandsWhole", land("one two three", "One two three four.", "Mine only") == .whole)
    check("d1603.fewCommonWordsLandsWhole", land("the plan for today is", "The plan for today is set.", "the") == .whole)
    // Never twice: the checked text is already there, after a swap Voice couldn't confirm or a late draft.
    check("d1603.alreadyAfterSwap", land(" one two", "One two three.", "Mine One two three.") == .already)
    check("d1603.alreadySameWords", land(" one two", "one two", "Mine one two") == .already)
    check("d1603.alreadyNotAPrefixOfAWord", land("one", "one two", "one twofold") == .swap(NSRange(location: 0, length: 3)))
    check("d1603.repeatedSpanHolds", land("one two", "One two three.", "one two and one two") == .hold)
    // A draft that arrived unseen sits right after the confirmed words: it is swapped with them, in full or in part.
    check("d1603.lateDraftSwappedToo", land(" one", "One two three.", "Mine one two", late: " two") == .swap(NSRange(location: 4, length: 8)))
    check("d1603.latePartSwappedToo", land(" one", "One two three.", "Mine one tw", late: " two") == .swap(NSRange(location: 4, length: 7)))
    check("d1603.lateNotThereSwapsConfirmedOnly", land(" one", "One two.", "Mine one", late: " two") == .swap(NSRange(location: 4, length: 4)))
    check("d1603.lateOnlySwaps", land("", "One two.", "Mine one two", late: " one two") == .swap(NSRange(location: 4, length: 8)))
    check("d1603.lateOnlyAbsentLandsWhole", land("", "One two.", "Mine", late: " one two") == .whole)
    check("d1603.lateEndingInsideAWordHolds", land(" one", "One two.", "Mine one twx", late: " tw") == .hold)
    // D-998 kept for a send seen: the same conversation's box reads empty after words went in.
    check("d1603.sameBoxEmptyHolds", land("one two", "One two three.", "") == .hold && land("one two", "One two three.", "\n") == .hold)
    // 2. Another conversation or another box: only an exact span counts, otherwise the whole dictation lands there.
    check("d1603.otherBoxEmptyLandsWhole", land("one two", "One two three.", "", same: false) == .whole)
    check("d1603.otherBoxCommonWordsLandWhole", land("one two three", "One two three four.", "one TWO, three", same: false) == .whole)
    check("d1603.otherBoxWithExactSpanSwaps", land("one two", "One two three.", "one two", same: false) == .swap(NSRange(location: 0, length: 7)))
    check("d1603.nothingTypedEarlyLandsWhole", land("", "One two.", "Mine") == .whole && land("  ", "One two.", "") == .whole)
    check("d1603.switchWithNoSendDelivers", DictationEnding.plan(typedInStartBox: true, startBoxAsLeft: false, inStartBox: false, sent: false) == .deliver)
    let chatOne = BoxPrint(role: "AXTextArea", identifier: "box", frame: nil, text: "one two", title: "Chat", url: "chat://one")
    let chatTwo = BoxPrint(role: "AXTextArea", identifier: "box", frame: nil, text: nil, title: "Chat", url: "chat://two")
    check("d1603.reusedBoxOtherChatIsAnotherPlace", !DictationEnding.sameConversation(start: chatOne, now: chatTwo)
          && DictationEnding.sameConversation(start: chatOne, now: chatOne))
    let noteOne = BoxPrint(role: "AXTextArea", identifier: "box", frame: nil, text: nil, title: "A")
    let noteTwo = BoxPrint(role: "AXTextArea", identifier: "box", frame: nil, text: nil, title: "B")
    check("d1603.noAddressTitleIsTheConversation", !DictationEnding.sameConversation(start: noteOne, now: noteTwo)
          && DictationEnding.sameConversation(start: noteOne, now: noteOne))
    check("d1603.earlyWordsNoteSaysWhere", DictationEnding.earlyWordsNote.contains("other screen"))
    // 3 and 5. A swap or a long talk's erase that wasn't confirmed: one read decides.
    check("d1603.swapReadShowsChecked", FinishInBox.afterFailedSwap(wanted: "Mine One two.", asLeft: "Mine one two", actual: "Mine One two.", retried: false) == .landed)
    check("d1603.swapReadAllowsBoxSpacing", FinishInBox.afterFailedSwap(wanted: "Mine One two.", asLeft: "Mine one two", actual: "Mine One two.\n", retried: false) == .landed)
    check("d1603.swapUntouchedRetriesOnce", FinishInBox.afterFailedSwap(wanted: "Mine One two.", asLeft: "Mine one two", actual: "Mine one two", retried: false) == .retry
          && FinishInBox.afterFailedSwap(wanted: "Mine One two.", asLeft: "Mine one two", actual: "Mine one two", retried: true) == .hold)
    check("d1603.swapHalfDoneNeverRetried", FinishInBox.afterFailedSwap(wanted: "Mine One two.", asLeft: "Mine one two", actual: "Mine on", retried: false) == .hold)
    check("d1603.swapSpacingChangedNotRetried", FinishInBox.afterFailedSwap(wanted: "Mine One two.", asLeft: "Mine one two", actual: "Mine one  two", retried: false) == .hold)
    check("d1603.swapUnreadableHolds", FinishInBox.afterFailedSwap(wanted: "x", asLeft: "y", actual: nil, retried: false) == .hold)
    check("d1603.swapSentHolds", FinishInBox.afterFailedSwap(wanted: "Mine One two.", asLeft: "Mine one two", actual: "", retried: false) == .hold)
    check("d1603.swapNeverStartedRetries", FinishInBox.afterFailedSwap(wanted: nil, asLeft: "Mine one two", actual: "Mine one two", retried: false) == .retry)
    // 4. A finishing attempt Voice couldn't confirm in time counts on one exact read.
    check("d1603.finishReadShowsWords", FinishInBox.landedOnRead(expected: "old One two.", actual: "old One two."))
    check("d1603.finishReadPartIsNotLanded", !FinishInBox.landedOnRead(expected: "old One two.", actual: "old One"))
    check("d1603.finishReadUnreadableIsNotLanded", !FinishInBox.landedOnRead(expected: "old One two.", actual: nil)
          && !FinishInBox.landedOnRead(expected: nil, actual: "old"))
    // 6. A click stopped the attempt before any word arrived: once more where the cursor is. A key never.
    func again(first: String? = "old", settled: String? = "old", keys: Bool = true, part: Bool = false,
               clicked: Bool = true, retried: Bool = false) -> Bool {
        FinishInBox.mayRetryAfterClick(before: "old", first: first, settled: settled, keysQuiet: keys, partArrived: part,
                                       clickedOrMoved: clicked, retried: retried)
    }
    check("d1603.clickRetriesOnce", again() && !again(retried: true))
    check("d1603.keyNeverRetries", !again(keys: false))
    check("d1603.partArrivedNeverRetries", !again(part: true) && !again(first: "old On") && !again(settled: "old One two."))
    check("d1603.unreadableNeverRetries", !again(first: nil) && !again(settled: nil))
    check("d1603.noClickUsesThePasteRule", !again(clicked: false))
    // Unchecked start box with words typed early (widening D-1565): only a send seen keeps the dictation out.
    check("d1603.uncheckedStartLands", !DictationEnding.holdsUncheckedStart(typedEarly: true, enterSeen: false, earlyBoxReadsEmpty: false))
    check("d1603.uncheckedStartEnterHolds", DictationEnding.holdsUncheckedStart(typedEarly: true, enterSeen: true, earlyBoxReadsEmpty: false))
    check("d1603.uncheckedStartEmptyBoxHolds", DictationEnding.holdsUncheckedStart(typedEarly: true, enterSeen: false, earlyBoxReadsEmpty: true))
    check("d1603.uncheckedStartNothingEarlyLands", !DictationEnding.holdsUncheckedStart(typedEarly: false, enterSeen: true, earlyBoxReadsEmpty: true))
    // Not in a text box still waits for a click; a text box takes the words at once.
    check("d1603.noBoxStillWaits", !DictationEnding.typesNow(kind: .notText, ownWindow: false) && DictationEnding.typesNow(kind: .text, ownWindow: false))
    // The 07:11:21 rebuilt composer: same window and conversation, text off by whitespace only, matches and is followed.
    let rebuiltStart = BoxPrint(role: "AXTextArea", identifier: nil, frame: CGRect(x: 10, y: 500, width: 600, height: 40),
                                text: "x one two ", title: "Chat", url: "chat://one")
    let rebuiltNow = BoxPrint(role: "AXTextArea", identifier: nil, frame: CGRect(x: 10, y: 480, width: 600, height: 60),
                              text: nil, title: "Chat", url: "chat://one")
    check("d1603.rebuiltComposerMatches", BoxMatch.failure(start: rebuiltStart, now: rebuiltNow, nowText: "x one two",
          sameElement: false, sameWindow: true, userEdited: false) == nil)
    check("d1603.rebuiltOtherWindowNotFollowed", BoxMatch.failure(start: rebuiltStart, now: rebuiltNow, nowText: "x one two",
          sameElement: false, sameWindow: false, userEdited: false) == .window)
}
