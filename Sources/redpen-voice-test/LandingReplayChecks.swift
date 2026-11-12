import CoreGraphics
import Foundation
import VoiceCore

/// D-1603 (Nov 12 2026): replays of the dictations that didn't land that morning, from their log lines. Each one
/// runs the decisions the app runs at its ending, with the facts the log recorded, and must end with the words in
/// a box. Counts and box facts only: the log holds no words, so the words here are made up.
/// Twenty-one earlier failures (05:01 to 06:49 UTC, older builds) can't be replayed: the 1 MB log cap had already
/// deleted their lines.
func landingReplayChecks(_ check: (String, Bool) -> Void) {
    typealias Land = WordsLand.Outcome
    let checked = "Alpha bravo charlie delta echo foxtrot."
    let drafts = " alpha bravo charlie"

    /// The box after the decision is carried out with the cursor at its end.
    func carriedOut(_ outcome: Land, box: String) -> String? {
        guard case .land(let landing) = outcome else { return nil }
        switch landing {
        case .already: return box
        case .swap(let range):
            let held = (box as NSString).substring(with: range)
            return (box as NSString).replacingCharacters(in: range, with: (held.first?.isWhitespace == true ? " " : "") + checked)
        case .rest(let rest): return box + (box.isEmpty || box.last?.isWhitespace == true ? "" : " ") + rest
        case .whole: return box + (box.isEmpty || box.last?.isWhitespace == true ? "" : " ") + checked
        }
    }
    func count(_ word: String, in text: String?) -> Int {
        (text ?? "").lowercased().components(separatedBy: word.lowercased()).count - 1
    }
    /// Every checked word is in the box exactly once.
    func landedOnce(_ outcome: Land, box: String) -> Bool {
        let after = carriedOut(outcome, box: box)
        return ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"].allSatisfy { count($0, in: after) == 1 }
    }
    let composer = CGRect(x: 320, y: 900, width: 700, height: 44)

    // MARK: 07:11:21, T3, 72 s. Switched conversation and came back; the composer was rebuilt.
    // Log: start element "failed window; differs frame,title,url". Focused composer "matched; differs text
    // prefix/value,element; same element false, window true; text expected 62, now 61, whitespace only true".
    // No Enter seen. It was kept for paste. It must land in the rebuilt box, once.
    do {
        let prior = String(repeating: "p", count: 40) + "."
        let expected = prior + drafts + " "            // 62: Voice's record, with the space the composer later trimmed
        let now = prior + drafts                       // 61: what the rebuilt composer reads
        check("replay.071121.lengths", expected.utf16.count == 62 && now.utf16.count == 61 && BoxText.same(expected, now))
        let start = BoxPrint(role: "AXTextArea", identifier: nil, frame: composer, text: expected, title: "Thread one", url: "t3://thread-1")
        // The element Voice started in, as it reads at the end: detached from the window, nothing where it was.
        let detached = BoxPrint(role: "AXTextArea", identifier: nil, frame: nil, text: nil, title: nil, url: nil)
        check("replay.071121.oldElementFailsWindow", BoxMatch.failure(start: start, now: detached, nowText: nil, sameElement: true, sameWindow: false) == .window
              && Set(BoxMatch.differences(start: start, now: detached, nowText: expected, sameElement: true)) == ["frame", "title", "url"])
        // None of that is a send: the plan delivers. The old rule (wasSent) called it sent and kept the words.
        let seen = DictationEnding.sendSeen(start: start, now: detached, value: nil)
        check("replay.071121.noSendSeen", !seen && DictationEnding.wasSent(start: start, now: detached, value: nil, boxGone: true))
        check("replay.071121.planNeverKeeps", DictationEnding.plan(typedInStartBox: true, startBoxAsLeft: false, inStartBox: false, sent: seen) == .deliver)
        // The focused composer is the same box rebuilt: same window and conversation, text off by whitespace only.
        let rebuilt = BoxPrint(role: "AXTextArea", identifier: nil, frame: composer.offsetBy(dx: 0, dy: -8), text: nil, title: "Thread one", url: "t3://thread-1")
        check("replay.071121.rebuiltBoxFollowed", BoxMatch.failure(start: start, now: rebuilt, nowText: now, sameElement: false, sameWindow: true) == nil
              && Set(BoxMatch.differences(start: start, now: rebuilt, nowText: now, sameElement: false)) == ["frame", "text prefix/value", "element"])
        // In the followed box the drafts are one span: the checked text replaces them in place.
        let range = FinishInBox.span(of: drafts, in: now)
        check("replay.071121.endingSwapsInPlace", range != nil && FinishInBox.ending(typed: drafts, checked: checked, actual: now, sent: false) == .replace(range!))
        let decision = WordsLand.decide(focus: .text, sendSeen: seen, typed: drafts, sameBox: true, boxText: now, checked: checked)
        check("replay.071121.lands", decision == .land(.swap(range!)) && landedOnce(decision, box: now)
              && carriedOut(decision, box: now) == prior + " " + checked)
        // The trimmed space was the drafts' own last character: no exact span, so only the words after them go in.
        let spaced = drafts + " "
        let trimmed = WordsLand.decide(focus: .text, sendSeen: seen, typed: spaced, sameBox: true, boxText: now, checked: checked)
        check("replay.071121.trimmedDraftLandsTheRest", trimmed == .land(.rest("delta echo foxtrot.")) && landedOnce(trimmed, box: now))
        // Never typed twice: once the checked text is in, another pass finds it there and types nothing.
        let after = carriedOut(decision, box: now)!
        check("replay.071121.neverTwice", WordsLand.decide(focus: .text, sendSeen: seen, typed: drafts, sameBox: true, boxText: after, checked: checked) == .land(.already))
        // Not followed (he stayed in the other conversation, its composer empty): the whole dictation goes there.
        let other = WordsLand.decide(focus: .text, sendSeen: seen, typed: drafts, sameBox: false, boxText: "", checked: checked)
        check("replay.071121.otherConversationLandsWhole", other == .land(.whole) && landedOnce(other, box: ""))
        // Control: the same switch with Enter seen going into the first box still holds, wherever the cursor is.
        let sent = DictationEnding.sendSeen(start: start, now: detached, value: nil, observedSend: true)
        check("replay.071121.control.enterSeenHolds", sent
              && DictationEnding.plan(typedInStartBox: true, startBoxAsLeft: false, inStartBox: false, sent: sent) == .keep
              && WordsLand.decide(focus: .text, sendSeen: sent, typed: drafts, sameBox: false, boxText: "", checked: checked) == .hold
              && WordsLand.decide(focus: .text, sendSeen: sent, typed: drafts, sameBox: true, boxText: "", checked: checked) == .hold
              && WordsLand.notLanded(cancelled: false, newer: false, sendSeen: sent, leftNothing: true, focus: .text) == .sendSeen)
    }

    // MARK: 07:11:31, T3, 4 s. Enter during the ending replace.
    // Log: "replacement not confirmed (deleted 56 of 56, retyped true, box 1227 of 1227 expected)". The box held the
    // expected text and the words were kept for paste anyway. It counts as landed, and nothing is typed again.
    do {
        let typed = " " + String(repeating: "d", count: 55)                 // 56 letters deleted
        let fixed = " " + checked
        let prior = String(repeating: "p", count: 1227 - fixed.utf16.count)
        let asLeft = prior + typed, wanted = prior + fixed
        let range = NSRange(location: prior.utf16.count, length: typed.utf16.count)
        check("replay.071131.lengths", typed.utf16.count == 56 && wanted.utf16.count == 1227)
        let edit = DraftReplacement(expectedBox: asLeft, actual: asLeft, cursor: NSRange(location: asLeft.utf16.count, length: 0),
                                    draft: typed, replacement: fixed, exactRange: range)
        // The read right after the wait stopped, and the read the ending makes after a swap it couldn't confirm.
        check("replay.071131.exactReadIsLanded", edit?.expected == wanted && edit?.landed(wanted) == true
              && FinishInBox.afterFailedSwap(wanted: wanted, asLeft: asLeft, actual: wanted, range: range, fixed: fixed, retried: false) == .landed)
        // Enter was seen after the words were in. That send is the finished message going out, not a reason to hold.
        let afterEnter = WordsLand.decide(focus: .text, sendSeen: true, typed: typed, sameBox: true, boxText: wanted, checked: checked)
        check("replay.071131.enterAfterWordsIsLanded", afterEnter == .land(.already) && count("alpha", in: carriedOut(afterEnter, box: wanted)) == 1)
        // Once it has gone out and the composer is empty, nothing is typed into the next message.
        check("replay.071131.sentMessageNotRetyped", WordsLand.decide(focus: .text, sendSeen: true, typed: typed, sameBox: true, boxText: "", checked: checked) == .hold)
    }

    // MARK: 07:13:33 and 07:30:10, T3. The start target hit the 1.8 s cap, unverified, nothing typed early.
    // Log (07:30:10): "insert: unverified start target, kept for Paste last". It must land at the cursor.
    do {
        var wait = StartTargetWait(at: 0)
        check("replay.unverifiedStart.capped", wait.result(found: false, unchanged: true, at: 1.0) == .wait
              && wait.result(found: false, unchanged: true, at: StartTargetWait.cap) == .fallback)
        check("replay.unverifiedStart.neverHolds", !DictationEnding.holdsUncheckedStart(typedEarly: false, enterSeen: false)
              && !DictationEnding.holdsUncheckedStart(typedEarly: false, enterSeen: true))
        for box in ["", "Words already in the composer."] {
            let decision = WordsLand.decide(focus: .text, sendSeen: false, typed: "", sameBox: false, boxText: box, checked: checked)
            check("replay.unverifiedStart.landsAtCursor.\(box.isEmpty ? "empty" : "text")", decision == .land(.whole) && landedOnce(decision, box: box))
        }
        // A box that won't say what it holds still takes them.
        check("replay.unverifiedStart.unreadableBoxLands", WordsLand.decide(focus: .unknown, sendSeen: false, typed: "", sameBox: false, boxText: nil, checked: checked) == .land(.whole))
        // Words typed early into the unchecked box: still lands unless Enter was seen.
        check("replay.unverifiedStart.typedEarlyLands", !DictationEnding.holdsUncheckedStart(typedEarly: true, enterSeen: false)
              && DictationEnding.holdsUncheckedStart(typedEarly: true, enterSeen: true))
    }

    // MARK: 07:26:10, Chrome, 31 s. Focus left the box while he talked.
    // Log: 3 draft runs; "box check: failed element; app or focus changed"; "cursor not in a text box (AXGroup),
    // waiting for a click"; "couldn't confirm taking the typed words back out ... they stay there"; then "pasted
    // after a click into AXTextArea, false". Paste last landed it a second later. It must land after the click.
    do {
        let prior = String(repeating: "p", count: 30) + "."
        let first = prior + drafts                         // the box he started in, drafts still there
        let page = FocusGate.kind(role: "AXGroup", editableAncestor: false, valueSettable: false, inBrowser: true)
        let box = FocusGate.kind(role: "AXTextArea", editableAncestor: false, valueSettable: true, inBrowser: true)
        // The first box reads as Voice left it and he is elsewhere: deliver where he is, then take the drafts back.
        check("replay.072610.planDelivers", DictationEnding.plan(typedInStartBox: true, startBoxAsLeft: true, inStartBox: false,
              sent: DictationEnding.sendSeen(start: BoxPrint(role: "AXTextArea", identifier: nil, frame: composer, text: first, title: "Page", url: "https://example.test/a"),
                                             now: BoxPrint(role: "AXTextArea", identifier: nil, frame: composer, text: nil, title: "Page", url: "https://example.test/a"),
                                             value: first)) == .takeBackThenDeliver)
        // A page in a browser is not a text box: the words wait for a click, and the page never takes them.
        check("replay.072610.pageWaits", page == .notText
              && WordsLand.decide(focus: page, sendSeen: false, typed: drafts, sameBox: false, boxText: nil, checked: checked) == .waitForClick
              && DictationEnding.waitRefuses(kind: page, inBrowser: true, ownWindow: false))
        // The click into a text box releases them at once.
        check("replay.072610.clickTakes", box == .text && !DictationEnding.waitRefuses(kind: box, inBrowser: true, ownWindow: false)
              && DictationEnding.waitTakes(kind: box, seenInARow: 1))
        // Back in the first box, drafts still there (the take back wasn't confirmed): swapped in place, never twice.
        let back = WordsLand.decide(focus: box, sendSeen: false, typed: drafts, sameBox: true, boxText: first, checked: checked)
        check("replay.072610.backInFirstBoxSwaps", landedOnce(back, box: first) && carriedOut(back, box: first) == prior + " " + checked)
        // The take back did work, or he clicked into another box: the whole dictation goes in.
        for (label, text, same) in [("firstBoxEmptied", prior, true), ("otherBox", "Other words.", false), ("otherEmptyBox", "", false)] {
            let decision = WordsLand.decide(focus: box, sendSeen: false, typed: drafts, sameBox: same, boxText: text, checked: checked)
            check("replay.072610.\(label)LandsWhole", decision == .land(.whole) && landedOnce(decision, box: text))
        }
        // Why typing was refused after that click is a guess (the old code logged nothing): the failed take back
        // left Voice's drafts selected, and a selection was refused. Now the cursor goes past a selection first.
        let selected = FinishInBox.span(of: drafts, in: first)!
        let caret = FinishInBox.caretPastSelection(selected)
        check("replay.072610.selectionNoLongerRefuses", caret == NSRange(location: first.utf16.count, length: 0)
              && FinishInBox.mayPaste(before: first, first: first, settled: first, range: caret, currentRange: caret, sameTarget: true))
        // Typing that isn't seen in the box: two unchanged reads allow the one paste; a click that stopped it before
        // any word arrived gets one more try where the cursor is.
        check("replay.072610.unseenTypingPastesOnce", FinishInBox.mayPaste(before: first, first: first, settled: first,
              range: caret, currentRange: caret, sameTarget: true)
              && !FinishInBox.mayPaste(before: first, first: first, settled: first, range: caret, currentRange: caret, sameTarget: true, alreadyPasted: true))
        check("replay.072610.stoppedByTheClickRetries", FinishInBox.mayRetryAfterStop(before: first, first: first, settled: first, partArrived: false, retried: false))
    }

    // MARK: 07:28:51, T3, 23 s. A draft wasn't confirmed, then another composer, then a page in focus at the end.
    // Log: 07:28:40 "draft AX edit not confirmed", drafts stopped. 07:28:46 composer "failed text prefix/value; same
    // element false, window true; text expected 1319, now 0". 07:28:50 the start element still "matched", 1319 of
    // 1319. No Enter seen. Ending: "you typed or clicked, stopped", "focus AXGroup, unknown", inserted false.
    // Not a send seen, so it must land: the whole dictation, once he is in a text box.
    do {
        let prior = String(repeating: "p", count: 1319 - drafts.utf16.count)
        let first = prior + drafts
        let late = " delta"                                // the draft Voice couldn't confirm
        let start = BoxPrint(role: "AXTextArea", identifier: nil, frame: composer, text: first, title: "Thread one", url: "t3://thread-1")
        let empty = BoxPrint(role: "AXTextArea", identifier: nil, frame: composer.offsetBy(dx: 0, dy: -60), text: nil, title: "Thread one", url: "t3://thread-1")
        check("replay.072851.lengths", first.utf16.count == 1319)
        // The focused composer reads empty and is another element: not the start box, not followed.
        check("replay.072851.emptyComposerNotFollowed", BoxMatch.failure(start: start, now: empty, nowText: "", sameElement: false, sameWindow: true) == .text)
        // The start element still reads as Voice left it, so the unconfirmed draft never arrived there.
        let asLeft = BoxMatch.same(start: start, now: start, nowText: first, sameElement: true)
        // An empty composer is an inference, never a send seen (the old rule held here).
        let seen = DictationEnding.sendSeen(start: start, now: empty, value: "")
        check("replay.072851.emptyIsNotASend", asLeft && !seen && DictationEnding.looksSent(""))
        check("replay.072851.planDelivers", DictationEnding.plan(typedInStartBox: true, startBoxAsLeft: asLeft, inStartBox: false, sent: seen) == .takeBackThenDeliver
              && DictationEnding.plan(typedInStartBox: true, startBoxAsLeft: false, inStartBox: false, sent: seen) == .deliver)
        // T3 is not a browser: its page (AXGroup) is a place Accessibility can't name, so it gets one try, as at release.
        let page = FocusGate.kind(role: "AXGroup", editableAncestor: false, valueSettable: false, inBrowser: false)
        check("replay.072851.pageIsUnknown", page == .unknown)
        for same in [true, false] {
            let decision = WordsLand.decide(focus: page, sendSeen: seen, typed: drafts, late: late, sameBox: same, boxText: "", checked: checked)
            check("replay.072851.emptyPlaceTakesWhole.\(same)", decision == .land(.whole))
        }
        // That try stopped before any word arrived ("you typed or clicked, stopped"): once more, then the words wait
        // for a click into a real text box. Before, they were kept for paste.
        check("replay.072851.triedAgainOnce", FinishInBox.mayRetryAfterStop(before: "", first: "", settled: "", partArrived: false, retried: false)
              && !FinishInBox.mayRetryAfterStop(before: "", first: "", settled: "", partArrived: false, retried: true))
        check("replay.072851.thenWaitsForAClick", WordsLand.notLanded(cancelled: false, newer: false, sendSeen: seen, leftNothing: true, focus: page) == .waitForClick)
        // While they wait the page doesn't get a second try; the composer takes them at the click.
        check("replay.072851.pageNotTriedAgain", DictationEnding.waitRefuses(kind: page, inBrowser: false, ownWindow: false, textBoxOnly: true)
              && !DictationEnding.waitRefuses(kind: .text, inBrowser: false, ownWindow: false, textBoxOnly: true)
              && DictationEnding.waitTakes(kind: .text, seenInARow: 1))
        // The click lands them. The empty composer takes the whole dictation, and the early words stay in the first one.
        let inEmpty = WordsLand.decide(focus: .text, sendSeen: seen, typed: drafts, late: late, sameBox: false, boxText: "", checked: checked)
        check("replay.072851.landsInEmptyComposer", inEmpty == .land(.whole) && landedOnce(inEmpty, box: ""))
        // Or he clicks back into the first composer, drafts still there: swapped in place, never twice.
        let inFirst = WordsLand.decide(focus: .text, sendSeen: seen, typed: drafts, late: late, sameBox: true, boxText: first, checked: checked)
        check("replay.072851.landsBackInFirstComposer", landedOnce(inFirst, box: first) && carriedOut(inFirst, box: first) == prior + " " + checked)
        // The late draft had arrived after all: it is swapped with the drafts.
        let withLate = WordsLand.decide(focus: .text, sendSeen: seen, typed: drafts, late: late, sameBox: true, boxText: first + late, checked: checked)
        check("replay.072851.lateDraftSwappedToo", landedOnce(withLate, box: first + late) && carriedOut(withLate, box: first + late) == prior + " " + checked)
        // Control: the same switch with Enter seen going into the first composer holds, at the end and at the click.
        let sent = DictationEnding.sendSeen(start: start, now: empty, value: "", observedSend: true)
        check("replay.072851.control.enterSeenHolds", sent
              && DictationEnding.plan(typedInStartBox: true, startBoxAsLeft: false, inStartBox: false, sent: sent) == .keep
              && WordsLand.decide(focus: page, sendSeen: sent, typed: drafts, late: late, sameBox: false, boxText: "", checked: checked) == .hold
              && WordsLand.decide(focus: .text, sendSeen: sent, typed: drafts, late: late, sameBox: true, boxText: "", checked: checked) == .hold)
    }

    // MARK: The rule itself.
    // Only two things hold the words: no text box (they wait for a click), and a send seen in the early words' box.
    // With no send seen, every box the cursor can be in gets the words, whatever it holds or won't say.
    for focus in [FocusKind.text, .unknown] {
        for same in [true, false] {
            for box in [nil, "", "Other words.", "p." + drafts, "p. alpha BRAVO, charlie", "p." + drafts + " and" + drafts] as [String?] {
                let decision = WordsLand.decide(focus: focus, sendSeen: false, typed: drafts, sameBox: same, boxText: box, checked: checked)
                var lands = false
                if case .land = decision { lands = true }
                check("rule.noSendSeenAlwaysLands.\(focus.rawValue).\(same).\(box.map { String($0.utf16.count) } ?? "unreadable")", lands)
            }
        }
    }
    // In the box the early words went into, they are never there twice: swapped, completed, or typed whole when gone.
    for box in ["", "Other words.", "p." + drafts, "p. alpha BRAVO, charlie"] {
        let decision = WordsLand.decide(focus: .text, sendSeen: false, typed: drafts, sameBox: true, boxText: box, checked: checked)
        check("rule.firstBoxNeverTwice.\(box.utf16.count)", landedOnce(decision, box: box))
    }
    // Early words there more than once (you copied them): they stay, and only the words after them go in.
    let doubled = "p." + drafts + " and" + drafts
    let afterDoubled = WordsLand.decide(focus: .text, sendSeen: false, typed: drafts, sameBox: true, boxText: doubled, checked: checked)
    check("rule.repeatedEarlyWordsGetTheRest", afterDoubled == .land(.rest("delta echo foxtrot."))
          && ["delta", "echo", "foxtrot"].allSatisfy { count($0, in: carriedOut(afterDoubled, box: doubled)) == 1 })
    // Another box that happens to hold some of the same words takes the whole dictation, never a shortened one.
    check("rule.otherBoxCoincidenceLandsWhole", WordsLand.decide(focus: .text, sendSeen: false, typed: drafts, sameBox: false,
          boxText: "p. alpha BRAVO, charlie", checked: checked) == .land(.whole))
    check("rule.noTextBoxWaits", WordsLand.decide(focus: .notText, sendSeen: false, typed: "", sameBox: false, boxText: nil, checked: checked) == .waitForClick
          && WordsLand.decide(focus: .text, ownWindow: true, sendSeen: false, typed: drafts, sameBox: false, boxText: nil, checked: checked) == .waitForClick)
    // A send seen with nothing of this dictation typed before it sent nothing of it: the words land.
    check("rule.sendWithNothingTypedEarlyLands", WordsLand.decide(focus: .text, sendSeen: true, typed: "", sameBox: true, boxText: "", checked: checked) == .land(.whole))
    check("rule.sendSeenHoldsEvenWithNoBox", WordsLand.decide(focus: .notText, sendSeen: true, typed: drafts, sameBox: false, boxText: nil, checked: checked) == .hold)
    // After two swap tries the early words stay and only the words after them go in.
    check("rule.swapTriedTwiceLandsTheRest", WordsLand.decide(focus: .text, sendSeen: false, typed: drafts, sameBox: true, boxText: "p." + drafts,
          checked: checked, canSwap: false) == .land(.rest("delta echo foxtrot.")))
    // What happens to words a finishing attempt left out.
    typealias N = WordsLand.NotLanded
    func out(cancelled: Bool = false, newer: Bool = false, sent: Bool = false, nothing: Bool = true, focus: FocusKind = .text) -> N {
        WordsLand.notLanded(cancelled: cancelled, newer: newer, sendSeen: sent, leftNothing: nothing, focus: focus)
    }
    check("rule.notLanded.escape", out(cancelled: true, newer: true, sent: true) == .discarded)
    check("rule.notLanded.newerPress", out(newer: true, sent: true) == .newerPress)
    check("rule.notLanded.sendSeen", out(sent: true, focus: .notText) == .sendSeen)
    check("rule.notLanded.noBoxWaits", out(focus: .notText) == .waitForClick && out(focus: .unknown) == .waitForClick)
    check("rule.notLanded.partArrivedChecksTheBox", out(nothing: false, focus: .notText) == .checkTheBox && out(nothing: false) == .checkTheBox)
    check("rule.notLanded.textBoxTriedChecksTheBox", out() == .checkTheBox)
    check("rule.checkNoteFitsTheBar", WordsLand.checkNote.count <= 48 && WordsLand.checkNote.contains("⌃⌥V"))
}
