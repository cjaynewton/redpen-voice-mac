import Foundation
import VoiceCore

func barClickChecks(_ check: (String, Bool) -> Void) {
    func failure(left: Double = 0.2, right: Double = 10, ownLeft: [Double] = [], ownRight: [Double] = [],
                 key: Double = 10, typing: Double? = nil, real: Double? = nil) -> DraftSafety.Failure? {
        DraftSafety.hardwareFailure(since: 1, at: 2, keyDownAgo: key, leftClickAgo: left, rightClickAgo: right,
            talkKeyDownTimes: [], typingKeyDownAt: typing, ownLeftClickTimes: ownLeft,
            ownRightClickTimes: ownRight, userClickAt: real)
    }
    check("barClick.dragDoesNotStopDraft", failure(ownLeft: [1.8]) == nil)
    check("barClick.menuDoesNotStopDraft", failure(left: 10, right: 0.2, ownRight: [1.8]) == nil)
    check("barClick.clockTolerance", failure(ownLeft: [1.849]) == nil)
    check("barClick.outsideTolerance", failure(ownLeft: [1.851]) == .hardwareClick)
    check("barClick.otherButtonNotExempt", failure(ownRight: [1.8]) == .hardwareClick)
    check("barClick.realClickStillStops", failure() == .hardwareClick)
    check("barClick.realKeyStillStops", failure(ownLeft: [1.8], key: 0.1) == .hardwareKey)
    check("barClick.observedKeyStillStops", failure(ownLeft: [1.8], typing: 1.5) == .hardwareKey)
    check("barClick.previousRealClickNotHidden", failure(ownLeft: [1.8], real: 1.4) == .hardwareClick)
    check("barClick.oldRealClickDoesNotBlockNewSession", failure(ownLeft: [1.8], real: 0.5) == nil)
    check("barClick.nanNeverMatches", !OwnWindowClicks.matches(.nan, times: [1]))
    let clicks = OwnWindowClicks()
    clicks.record(.left, at: 3)
    check("barClick.globalOwnEventIgnored", !clicks.recordExternal(.left, at: 3.01))
    check("barClick.globalRealEventRecorded", clicks.recordExternal(.right, at: 3.01))
    clicks.record(.left, at: 4)
    check("barClick.stickyExternalEvidence", clicks.snapshot().userClickAt == 3.01)
    check("barClick.menuAndButtonTimesRetained", clicks.snapshot().left == [3, 4])
    for i in 0..<100 { clicks.record(.other, at: Double(i)) }
    check("barClick.otherButtonRecorded", clicks.contains(.other, at: 99))
    check("barClick.storageBounded", !clicks.contains(.other, at: 0))

    let prior = "My heading. Early words", full = " and this is the next draft with a longer ending"
    let count = 20, posted = String(full.prefix(count))
    let start = BoxPrint(role: "AXTextArea", identifier: "box", frame: nil, text: prior, title: "T3", url: "chat://one")
    let draft = DictationEnding.LateDraft(before: prior, range: NSRange(location: prior.utf16.count, length: 0),
                                        text: full, postedUTF16: count)
    func recover(_ actual: String, sent: Bool = false, edited: Bool = false, sameElement: Bool = true,
                 sameWindow: Bool = true, now: BoxPrint? = nil) -> (box: BoxPrint, text: String)? {
        DictationEnding.reconcileLateDraft(draft, confirmedDrafts: "Early words", start: start, now: now ?? start,
            actual: actual, cursor: NSRange(location: actual.utf16.count, length: 0), sameElement: sameElement,
            sameWindow: sameWindow, userEdited: edited, inStartBox: true, observedSend: sent)
    }
    let match = recover(prior + posted)
    check("barClick.postedCountRetained", draft.text == posted && draft.exactPostedPrefix)
    check("barClick.exactPartialAdopted", match?.text == posted && match?.box.text == prior + posted)
    check("barClick.shorterArrivalRejected", recover(prior + String(posted.dropLast())) == nil)
    check("barClick.longerArrivalRejected", recover(prior + full) == nil)
    check("barClick.extraSpaceRejected", recover(prior + posted + " ") == nil)
    check("barClick.changedPrefixRejected", recover("Edited " + prior + posted) == nil)
    check("barClick.sentNeverAdopted", recover(prior + posted, sent: true) == nil)
    check("barClick.typedNeverAdopted", recover(prior + posted, edited: true) == nil)
    check("barClick.otherElementRejected", recover(prior + posted, sameElement: false) == nil)
    check("barClick.otherWindowRejected", recover(prior + posted, sameWindow: false) == nil)
    let other = BoxPrint(role: "AXTextArea", identifier: "box", frame: nil, text: prior, title: "T3", url: "chat://two")
    check("barClick.sentConversationRejected", recover(prior + posted, now: other) == nil)
    check("barClick.zeroPostedIsNotFullAttempt", DictationEnding.LateDraft(before: prior, range: .init(location: 0, length: 0), text: full, postedUTF16: 0).text.isEmpty)
    check("barClick.surrogateSplitNeverGuessed", DictationEnding.LateDraft(before: prior, range: .init(location: 0, length: 0), text: "😀 word", postedUTF16: 1).text.isEmpty)
    check("barClick.invalidPostedCountRejected", DictationEnding.LateDraft(before: prior, range: .init(location: 0, length: 0), text: full, postedUTF16: 999).text.isEmpty)
    // The 06:00:44 interruption is replayed with synthetic text. The exact prefix owns the ending span.
    let typed = "Early words" + (match?.text ?? "")
    let checked = "Early words and all the final words."
    let decision = FinishInBox.ending(typed: typed, checked: checked, actual: prior + posted, sent: false, uncertain: match == nil)
    if case .replace(let span) = decision {
        let edit = DraftReplacement(expectedBox: prior + posted, actual: prior + posted,
            cursor: NSRange(location: NSMaxRange(span), length: 0), draft: typed, replacement: checked, exactRange: span)
        check("barClick.incidentEndingLandsInBox", edit?.expected == "My heading. " + checked)
    } else { check("barClick.incidentEndingLandsInBox", false) }
    check("barClick.sentEndingGetsNothing", FinishInBox.ending(typed: typed, checked: checked, actual: prior + posted, sent: true) == .keep)
    check("barClick.clickReasonIsNotTyping", TalkingWords.Stop(.hardwareClick) == .clicked)
}
