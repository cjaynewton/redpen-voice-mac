import AppKit
import CoreGraphics
import Foundation
import VoiceCore

// Command-line checks for the parts that need no microphone. Run: swift run redpen-voice-test
var pass = 0, fail = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { pass += 1 } else { fail += 1; print("FAIL \(name) \(detail)") }
}

// Names: whole word, case-insensitive, longest first, punctuation kept, no clipboard, no partial words.
let names = Names(text: """
# names
claw code = Claude Code
Priya
kmf = KMF
redpen = Redpen
""")
check("names.count", names.entries.count == 4)
check("names.vocab", names.vocabulary.contains("Claude Code") && names.vocabulary.contains("Priya"))
check("names.replace", names.apply("open claw code now") == "open Claude Code now")
check("names.case", names.apply("Claw Code, please.") == "Claude Code, please.")
check("names.partial", names.apply("the clawed cat") == "the clawed cat")
check("names.keep", names.apply("priya said kmf") == "Priya said KMF")
check("names.punct", names.apply("Is redpen's build done?") == "Is Redpen's build done?")
check("names.start", names.apply("redpen. redpen!") == "Redpen. Redpen!")

// History: append, last, trim, nothing lost when inserted is false.
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rv-test-\(UUID().uuidString)/history.jsonl")
let h = History(url: tmp)
check("history.empty", h.last() == nil)
h.append(Entry(raw: "first line", seconds: 3, app: "TextEdit", inserted: true))
h.append(Entry(raw: "second line here", cleaned: "Second line here.", seconds: 4, app: "Slack", inserted: false))
check("history.last", h.last()?.raw == "second line here")
check("history.text", h.last()?.text == "Second line here.")
check("history.words", h.last()?.words == 3)
h.append(Entry(raw: "", cleaned: nil, seconds: 1, app: "T", inserted: false))
check("history.lastSpoken.skipsEmpty", h.last()?.raw == "" && h.lastSpoken()?.raw == "second line here")
for i in 0..<20 { h.append(Entry(raw: "n \(i)", seconds: 1, app: "x", inserted: true)) }
h.trim(to: 5)
check("history.trim", h.all().count == 5 && h.all().last?.raw == "n 19")
try? FileManager.default.removeItem(at: tmp.deletingLastPathComponent())

// Score: words per minute and minutes saved against a 40 wpm typist.
let s = Score(words: 400, seconds: 180, count: 3)
check("score.wpm", s.wordsPerMinute == 133, "\(s.wordsPerMinute)")
check("score.saved", s.minutesSaved == 7, "\(s.minutesSaved)")   // 10 min typed, 3 min spoken
check("score.zero", Score().wordsPerMinute == 0 && Score().minutesSaved == 0)
let old = Entry(date: Date(timeIntervalSinceNow: -2 * 86_400), raw: "a b c", seconds: 1, app: "x", inserted: true)
let new = Entry(raw: "a b", seconds: 1, app: "x", inserted: true)
check("score.today", Score.today([old, new]).words == 2)

// Delivery after either kind of stop: a cancelled tap cannot steal the words or leave the old bar behind.
do {
    let now = Date(timeIntervalSince1970: 1000)
    var delivery = DictationDelivery()
    delivery.begin(at: now)
    let first = delivery.current
    delivery.confirm() // ordinary release, or the stop of a confirmed hands-free dictation
    check("delivery.stopKeepsOwner", delivery.current == first && delivery.waitForTap(after: first, at: now) == 0)
    delivery.begin(at: now.addingTimeInterval(1))
    let tap = delivery.current
    check("delivery.tapStartsImmediately", tap > first)
    check("delivery.finishesBeforeTapReleaseWaits", abs(delivery.waitForTap(after: first, at: now.addingTimeInterval(1.1)) - 0.3) < 0.0001)
    check("delivery.ownFinishDoesNotWait", delivery.waitForTap(after: tap, at: now.addingTimeInterval(1.1)) == 0)
    check("delivery.shortTapCancelled", delivery.cancel(at: now.addingTimeInterval(1.2)))
    check("delivery.cancelBeforeFinishRestoresOwner", delivery.current == first && delivery.waitForTap(after: first, at: now.addingTimeInterval(1.3)) == 0)
    delivery.begin(at: now.addingTimeInterval(1.3))
    check("delivery.generationsNeverReused", delivery.current > tap)
    check("delivery.repeatedTapCancelled", delivery.cancel(at: now.addingTimeInterval(1.35)))
    check("delivery.repeatedTapRestoresOwner", delivery.current == first)
    // A genuine new hold starts recording at once, and remains newer when it crosses the tap threshold.
    delivery.begin(at: now.addingTimeInterval(2))
    let hold = delivery.current
    check("delivery.realHoldDoesNotWaitForever", delivery.waitForTap(after: first, at: now.addingTimeInterval(2.5)) == 0 && delivery.current == hold)
    check("delivery.longShortcutNotATap", !delivery.cancel(at: now.addingTimeInterval(2.5)) && delivery.current == hold)
    delivery.begin(at: now.addingTimeInterval(3))
    let next = delivery.current
    delivery.confirm()
    check("delivery.realReleaseKeepsOwner", delivery.current == next && delivery.waitForTap(after: first, at: now.addingTimeInterval(3.1)) == 0)
    check("delivery.confirmedPressCannotBeCancelledAsTap", !delivery.cancel(at: now.addingTimeInterval(3.1)) && delivery.current == next)
    // Double tap start: discard the first tap, confirm the second as hands-free, then stop without changing owner.
    var handsFree = DictationDelivery()
    handsFree.begin(at: now)
    check("delivery.doubleTapFirstDropped", handsFree.cancel(at: now.addingTimeInterval(0.1)) && handsFree.current == 0)
    handsFree.begin(at: now.addingTimeInterval(0.2))
    let latched = handsFree.current
    handsFree.confirm()
    check("delivery.doubleTapSecondConfirmed", !handsFree.cancel(at: now.addingTimeInterval(0.3)) && handsFree.current == latched)
    handsFree.confirm() // the single stop tap does not call begin
    handsFree.begin(at: now.addingTimeInterval(5)) // an extra tap after the stop
    check("delivery.handsFreeExtraTapWaits", handsFree.waitForTap(after: latched, at: now.addingTimeInterval(5.1)) > 0)
    check("delivery.handsFreeExtraTapIgnored", handsFree.cancel(at: now.addingTimeInterval(5.2)) && handsFree.current == latched)
    handsFree.begin(at: now.addingTimeInterval(6))
    let realAfterStop = handsFree.current
    handsFree.confirm() // another genuine double tap starts hands-free again
    check("delivery.handsFreeCanRestart", handsFree.current == realAfterStop && handsFree.waitForTap(after: latched, at: now.addingTimeInterval(6.1)) == 0)
    // Paste last is deliberate and is not rolled back by an unrelated later stray tap.
    delivery.supersede()
    let pasted = delivery.current
    delivery.begin(at: now.addingTimeInterval(7))
    check("delivery.pasteSurvivesTap", delivery.cancel(at: now.addingTimeInterval(7.1)) && delivery.current == pasted && pasted > next)
    // Exactly tapLength is a hold, matching HoldKey's strict shorter-than rule.
    var boundary = DictationDelivery()
    let zero = Date(timeIntervalSinceReferenceDate: 0)
    boundary.begin(at: zero)
    check("delivery.tapBoundaryIsHold", !boundary.cancel(at: zero.addingTimeInterval(DictationDelivery.tapLength)) && boundary.current == 1)
}

// Draft guards use recorded times only. Reproduce a stop tap being counted as hardware typing.
do {
    var key = TalkKeyState()
    func talk(_ down: Bool, _ time: Double, own: Bool = false, ready: Bool = true) {
        _ = key.event(key: 63, down: down, ownEvent: own, canBegin: ready, at: time)
    }
    func failure(start: Double = 100, now: Double = 120, hardwareKeyAt: Double = 90,
                 leftAt: Double = 90, rightAt: Double = 90) -> DraftSafety.Failure? {
        DraftSafety.hardwareFailure(since: start, at: now, keyDownAgo: now - hardwareKeyAt,
            leftClickAgo: now - leftAt, rightClickAgo: now - rightAt,
            talkKeyDownTimes: key.lastTalkKeyDownAt.map { [$0] } ?? [], typingKeyDownAt: key.lastTypingKeyDownAt)
    }
    check("draftSafety.idleHardwareIsSafe", failure() == nil)
    check("draftSafety.unobservedHardwareKeyBlocks", failure(hardwareKeyAt: 110) == .hardwareKey)
    talk(true, 99.9); talk(false, 99.98)
    talk(true, 100.1); talk(false, 100.2)
    check("draftSafety.startDoubleTapLatches", key.handsFree)
    check("draftSafety.startTapAfterDraftStartIsSafe", failure(hardwareKeyAt: 100.1) == nil)
    talk(true, 115, ready: false)
    check("draftSafety.stopDownRecordedBeforeEnding", key.lastTalkKeyDownAt == 115 && !key.handsFree)
    // The old decision is false for this same stop tap. The new decision accepts it.
    check("draftSafety.oldCounterGuardRejectsStop", 120.0 - 115 < 120.0 - 100)
    check("draftSafety.singleStopTapIsSafe", failure(hardwareKeyAt: 115) == nil)
    talk(false, 115.1, ready: false)
    check("draftSafety.releaseDoesNotMaskNewerTyping", key.lastTalkKeyDownAt == 115)
    _ = key.otherKey(at: 115.05)
    check("draftSafety.keyBetweenStopDownAndReleaseBlocks", failure(hardwareKeyAt: 115.05) == .hardwareKey)
    // Continue this stop-only scenario with a fresh gesture record.
    key = TalkKeyState()
    talk(true, 115, ready: false); talk(false, 115.1, ready: false)
    talk(true, 115.2, ready: false); talk(false, 115.3, ready: false)
    check("draftSafety.blockedSecondStopTapRecorded", key.lastTalkKeyDownAt == 115.2)
    check("draftSafety.doubleStopTapIsSafe", failure(hardwareKeyAt: 115.2) == nil)
    let ending = DraftReplacement(expectedBox: "Prefix. Draft words", actual: "Prefix. Draft words",
        cursor: NSRange(location: 19, length: 0), draft: " Draft words", replacement: " Checked words and the ending.")
    check("draftSafety.stopAllowsCompleteEnding", failure(hardwareKeyAt: 115.2) == nil &&
        ending?.expected == "Prefix. Checked words and the ending.")
    check("draftSafety.counterRoundingTolerated", failure(hardwareKeyAt: 115.201) == nil)
    check("draftSafety.laterHardwareKeyBlocks", failure(hardwareKeyAt: 115.23) == .hardwareKey)
    check("draftSafety.earlierUnmatchedHardwareKeyBlocks", failure(hardwareKeyAt: 114) == .hardwareKey)
    talk(true, 119, own: true)
    check("draftSafety.ownEventCannotExemptRealKey", key.lastTalkKeyDownAt == 115.2 && failure(hardwareKeyAt: 119) == .hardwareKey)
    check("draftSafety.leftClickBlocksAfterStop", failure(hardwareKeyAt: 115.2, leftAt: 116) == .hardwareClick)
    check("draftSafety.rightClickBlocksAfterStop", failure(hardwareKeyAt: 115.2, rightAt: 116) == .hardwareClick)
    check("draftSafety.clickStillBlocksWhenTalkIsLatest", failure(hardwareKeyAt: 115.2, leftAt: 110) == .hardwareClick)
    _ = key.otherKey(at: 115.2005)
    check("draftSafety.observedTypingWithinToleranceBlocks", failure(hardwareKeyAt: 115.2005) == .hardwareKey)
    talk(true, 116, ready: false); talk(false, 116.1, ready: false)
    check("draftSafety.stopCannotHideEarlierRealTyping", failure(hardwareKeyAt: 116) == .hardwareKey)
    check("draftSafety.oldTypingDoesNotBlockNextDictation", failure(start: 117, hardwareKeyAt: 116) == nil)
    key.noteKeyDown(talkKey: true, at: 118)
    key.noteKeyDown(talkKey: true, at: 117.9)
    check("draftSafety.repeatRecordedAndTimeCannotGoBack", key.lastTalkKeyDownAt == 118 && failure(start: 117, hardwareKeyAt: 118) == nil)
    key = TalkKeyState()
    talk(true, 99); talk(false, 101)
    check("draftSafety.holdReleaseIsSafe", failure(hardwareKeyAt: 99) == nil)
    key = TalkKeyState()
    key.doubleTap = false
    _ = key.event(key: 96, down: true, at: 99)
    key.noteKeyDown(talkKey: true, at: 105) // ordinary talk key repeating while held
    check("draftSafety.ordinaryTalkRepeatIsSafe", failure(hardwareKeyAt: 105) == nil)
    check("draftSafety.ordinaryTalkKeyDoesNotDisableTypingGuard", failure(hardwareKeyAt: 106) == .hardwareKey)
    _ = key.otherKey(at: 107)
    key.noteKeyDown(talkKey: true, at: 108)
    check("draftSafety.shortcutTypingCannotBeHiddenByRepeat", failure(hardwareKeyAt: 108) == .hardwareKey)
}

// Escape throws a dictation away: hands-free ends, a held key's release is swallowed, the next press is new.
do {
    var k = TalkKeyState()
    _ = k.event(key: 63, down: true, at: 10); _ = k.event(key: 63, down: false, at: 10.1)
    _ = k.event(key: 63, down: true, at: 10.2); _ = k.event(key: 63, down: false, at: 10.3)
    check("escape.handsFreeBefore", k.handsFree)
    k.discard(at: 12)
    check("escape.handsFreeOff", !k.handsFree && !k.active)
    check("escape.nextPressBegins", k.event(key: 63, down: true, at: 13) == .begin)
    var h = TalkKeyState()
    _ = h.event(key: 63, down: true, at: 20)
    h.discard(at: 21)
    check("escape.heldReleaseSwallowed", h.event(key: 63, down: false, at: 22) == nil && !h.active)
    check("escape.afterHeldNewPressBegins", h.event(key: 63, down: true, at: 23) == .begin)
}

// Oct 30 live log: the counter's key-down time matched the Fn release, not the press.
do {
    let input = DraftInput(since: 998648.0)
    input.record(talkKey: true, at: 998671.739563); input.record(talkKey: true, at: 998671.830269)
    input.record(talkKey: true, at: 998671.888730); input.record(talkKey: true, at: 998672.029599)
    let t = input.snapshot()
    func fail(_ keyAt: Double) -> DraftSafety.Failure? {
        DraftSafety.hardwareFailure(since: 998648.0, at: 998673.0, keyDownAgo: 998673.0 - keyAt,
            leftClickAgo: 999, rightClickAgo: 999, talkKeyDownTimes: t.talkTimes, typingKeyDownAt: t.typingAt)
    }
    check("draftR3.stopTapReleaseIsTalkKey", fail(998672.029619) == nil)
    check("draftR3.keyLongAfterReleaseBlocks", fail(998672.5) == .hardwareKey)
}
// Oct 30 17:02 live log: a key-down posted with the Fn release (0.05 ms apart) was counted as typing.
do {
    let input = DraftInput(since: 999170.0)
    input.record(talkKey: false, at: 999193.504760) // can arrive before the flags event
    input.record(talkKey: true, at: 999193.504726)
    check("draftR3.keyWithFnReleaseIsNotTyping", input.snapshot().typingAt == nil)
    input.record(talkKey: false, at: 999193.9)
    check("draftR3.laterRealKeyStillTyping", input.snapshot().typingAt == 999193.9)
}

// Round 2: use the same per-dictation evidence and bounded reconciliation as the production while/ending guard.
// All input is injected into the time ledger. No keys or events are posted.
do {
    let input = DraftInput(since: 100)
    var now = 120.0, hardwareAt = 115.0, leftAt = 90.0, rightAt = 90.0
    var waits = 0
    var onWait: (() -> Void)?
    func sample() -> DraftSafety.HardwareSample {
        let evidence = input.snapshot()
        return .init(now: now, keyDownAgo: now - hardwareAt, leftClickAgo: now - leftAt,
            rightClickAgo: now - rightAt, talkKeyDownTimes: evidence.talkTimes, typingKeyDownAt: evidence.typingAt)
    }
    func resolved() -> DraftSafety.HardwareSample {
        DraftSafety.resolveHardware(since: 100, sample: sample, wait: { delay in
            now += delay; waits += 1; onWait?()
        })
    }
    input.record(talkKey: true, at: 99) // another dictation
    check("draftR2.ignoresPreviousDictation", input.snapshot().talkTimes.isEmpty)
    input.record(talkKey: true, at: 115)
    input.record(talkKey: true, at: 115.15)
    input.record(talkKey: true, at: 115) // same event from passive and main-thread paths
    check("draftR2.remembersBothStopDowns", input.snapshot().talkTimes.count == 2)
    check("draftR2.counterCanMatchFirstOfDoubleStop", resolved().failure(since: 100) == nil)
    hardwareAt = 115.1545
    check("draftR2.handledDoubleTapWithRealisticGap", resolved().failure(since: 100) == nil && waits == 0)
    check("draftR2.diagnosticNearestAndGap", abs((sample().nearestTalkAt ?? 0) - 115.15) < 0.000001 &&
        abs((sample().keyAt - (sample().nearestTalkAt ?? 0)) - 0.0045) < 0.000001)
    hardwareAt = 116
    onWait = { if waits == 24 { input.record(talkKey: true, at: 116) } }
    check("draftR2.counterBeforeCallbackWaitsAndResolves", resolved().failure(since: 100) == nil && waits == 24)
    // A second counter/event race during a later chunk must also reconcile. Completing the chunk keeps
    // its known suffix available for the checked ending instead of creating an uncertain partial edit.
    var typed = ""
    var complete = true
    for chunk in ["Draft ", "words", " and tail"] {
        hardwareAt += 1
        onWait = { input.record(talkKey: true, at: hardwareAt) }
        guard resolved().failure(since: 100) == nil else { complete = false; break }
        typed += chunk
    }
    let ending = DraftReplacement(expectedBox: "Prefix. " + typed, actual: "Prefix. " + typed,
        cursor: NSRange(location: ("Prefix. " + typed).utf16.count, length: 0),
        draft: typed, replacement: "Checked words and ending.")
    check("draftR2.stopDuringChunkFinishesKnownDraft", complete && typed == "Draft words and tail")
    check("draftR2.sameGuardAllowsCheckedEnding", resolved().failure(since: 100) == nil &&
        ending?.expected == "Prefix. Checked words and ending.")
    hardwareAt += 1; onWait = nil; waits = 0
    let beforeTimeout = now
    let timedOut = resolved()
    check("draftR2.unidentifiedKeyStillBlocks", timedOut.failure(since: 100) == .hardwareKey)
    check("draftR2.waitIsBounded", now - beforeTimeout <= 0.250001 && waits <= 51)
    leftAt = now - 0.001; waits = 0
    check("draftR2.clickDoesNotWaitForUnidentifiedKey", resolved().failure(since: 100) != nil && waits == 0)
    leftAt = 90; rightAt = now - 0.001
    check("draftR2.rightClickStillBlocks", resolved().failure(since: 100) != nil && waits == 0)
    rightAt = 90
    onWait = { input.record(talkKey: false, at: hardwareAt) }
    check("draftR2.delayedRealKeyBlocks", resolved().failure(since: 100) == .hardwareKey && waits == 1)
    input.record(talkKey: true, at: hardwareAt + 0.001)
    hardwareAt += 0.001; waits = 0
    check("draftR2.talkWithinToleranceCannotMaskTyping", resolved().failure(since: 100) == .hardwareKey && waits == 0)
    let next = DraftInput(since: now + 1)
    next.record(talkKey: false, at: now)
    check("draftR2.nextDictationHasNoStickyOldTyping", next.snapshot().typingAt == nil)
    // Actual concurrent delivery, without dispatching a main-thread NSEvent or pumping its run loop.
    let concurrent = DraftInput(since: ProcessInfo.processInfo.systemUptime - 1)
    let keyAt = ProcessInfo.processInfo.systemUptime
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { concurrent.record(talkKey: true, at: keyAt) }
    let raced = DraftSafety.resolveHardware(since: concurrent.since) {
        let evidence = concurrent.snapshot(), time = ProcessInfo.processInfo.systemUptime
        return .init(now: time, keyDownAgo: time - keyAt, leftClickAgo: 10, rightClickAgo: 10,
            talkKeyDownTimes: evidence.talkTimes, typingKeyDownAt: evidence.typingAt)
    }
    check("draftR2.independentThreadResolvesWhileMainWaits", raced.failure(since: concurrent.since) == nil)
}

// Talk gestures run without posting keys, opening windows, or using the microphone.
do {
    var key = TalkKeyState()
    func event(_ down: Bool, _ time: Double, code: Int = 63, own: Bool = false, ready: Bool = true) -> TalkKeyState.Action? {
        key.event(key: code, down: down, ownEvent: own, canBegin: ready, at: time)
    }
    check("talk.firstDownBegins", event(true, 1) == .begin)
    check("talk.duplicateDownIgnored", event(true, 1.02) == nil)
    check("talk.firstTapCancelled", event(false, 1.1) == .cancel && !key.active)
    check("talk.secondDownBegins", event(true, 1.25) == .begin)
    check("talk.secondTapLatches", event(false, 1.35) == .handsFree && key.handsFree)
    check("talk.typingWhileHandsFreeIgnored", key.otherKey() == nil && key.handsFree)
    check("talk.ownDownCannotStop", event(true, 2, own: true) == nil && key.handsFree)
    check("talk.latchHasNoHeldKey", !key.held && key.handsFree)
    check("talk.oneDownStops", event(true, 3, ready: false) == .end && !key.handsFree && !key.active)
    check("talk.stopUpSwallowed", event(false, 3.1, ready: false) == nil)
    check("talk.extraDownNoRecording", event(true, 3.2, ready: false) == nil && !key.active)
    check("talk.extraUpNoLatch", event(false, 3.3, ready: false) == nil && !key.handsFree)
    check("talk.guardAfterFinishNoRecording", event(true, 3.45) == nil && !key.active)
    check("talk.guardAfterFinishNoLatch", event(false, 3.55) == nil && !key.handsFree)
    check("talk.finishingBeyondGuardBlocks", event(true, 5, ready: false) == nil)
    check("talk.releaseAfterFinishingCannotLatch", event(false, 5.1) == nil && !key.handsFree)
    check("talk.newIdleTapBegins", event(true, 6) == .begin)
    check("talk.newIdleTapDropped", event(false, 6.1) == .cancel)
    check("talk.newIdleDoubleTapBegins", event(true, 6.25) == .begin)
    check("talk.newIdleDoubleTapLatches", event(false, 6.35) == .handsFree)
    check("talk.eitherTalkKeyStops", event(true, 7, code: 61, ready: false) == .end)
    check("talk.eitherTalkKeyReleaseSwallowed", event(false, 7.1, code: 61) == nil && key.owner == nil)

    key = TalkKeyState()
    check("talk.holdBeginsImmediately", event(true, 10) == .begin)
    check("talk.ownReleaseIgnored", event(false, 10.1, own: true) == nil && key.active)
    check("talk.holdKeepsOwner", key.held && key.active && key.owner == 63)
    check("talk.otherTalkKeyCannotOwnHold", event(true, 10.3, code: 61) == nil && key.owner == 63)
    check("talk.holdReleaseEnds", event(false, 10.6) == .end && !key.active)
    check("talk.holdStopGuard", event(true, 10.7) == nil)
    check("talk.holdStopGuardRelease", event(false, 10.8) == nil)
    check("talk.holdClearedTapHistory", event(true, 12) == .begin && event(false, 12.1) == .cancel && !key.handsFree)

    key = TalkKeyState()
    check("talk.idleHasNoOwner", !key.active && !key.held && key.owner == nil)
    check("talk.ownDownNoBegin", event(true, 20.1, own: true) == nil && key.owner == nil)
    check("talk.realAfterOwnEventBegins", event(true, 21) == .begin)
    check("talk.veryFastTapStillCounts", event(false, 21.01) == .cancel)
    check("talk.veryFastSecondDownStillBegins", event(true, 21.02) == .begin && key.active)
    check("talk.veryFastSecondReleaseLatches", event(false, 21.03) == .handsFree && key.handsFree)
    key = TalkKeyState()
    check("talk.newFirstTap", event(true, 22) == .begin && event(false, 22.1) == .cancel)
    check("talk.doubleTapOtherKeyNotSecond", event(true, 22.25, code: 61) == .begin && event(false, 22.35, code: 61) == .cancel)
    check("talk.expiredTapNotSecond", event(true, 23, code: 61) == .begin && event(false, 23.1, code: 61) == .cancel)

    key = TalkKeyState()
    check("talk.shortcutBegins", event(true, 30) == .begin)
    check("talk.otherKeyCancels", key.otherKey() == .cancel && !key.active)
    check("talk.shortcutReleaseIgnored", event(false, 30.1) == nil)
    check("talk.shortcutCannotSeedDoubleTap", event(true, 30.25) == .begin && event(false, 30.35) == .cancel && !key.handsFree)
    check("talk.rejectedBegin", event(true, 30.5) == .begin)
    key.rejectBegin()
    check("talk.rejectedBeginCannotLatch", event(false, 30.6) == nil && !key.handsFree)
    key = TalkKeyState(); key.doubleTap = false
    check("talk.singleTapModeBegins", event(true, 40) == .begin)
    check("talk.singleTapModeEnds", event(false, 40.1) == .end && !key.handsFree)
    key = TalkKeyState()
    check("talk.tapLengthBoundaryIsHold", event(true, 0) == .begin && event(false, TalkKeyState.tapLength) == .end)
    key = TalkKeyState()
    _ = event(true, 50); _ = event(false, 50.1)
    _ = event(true, 50.25); _ = event(false, 50.35)
    _ = event(true, 51); _ = event(false, 51.1)
    var began = 0, latched = 0
    for i in 0..<26 {
        let time = 51.2 + Double(i) * 0.12
        if event(true, time, ready: i > 20) == .begin { began += 1 }
        if event(false, time + 0.06, ready: i > 20) == .handsFree { latched += 1 }
    }
    check("talk.26ExtraTapsNeverRecordOrLatch", began == 0 && latched == 0 && !key.active && !key.handsFree)
}

// A missing release follows the same gesture path as a normal release.
do {
    var key = TalkKeyState()
    check("talk.releaseCheckIdleNoAction", key.checkRelease(key: 63, hardwareDown: false, at: 0) == nil)
    check("talk.missedReleaseBegins", key.event(key: 63, down: true, at: 1) == .begin)
    check("talk.missingUpWaitsForRecovery", key.held && key.active)
    check("talk.releaseRecheckStillHeld", key.checkRelease(key: 63, hardwareDown: true, at: 1.55) == nil
          && key.held && key.active)
    check("talk.releaseTimerNeverEndsHeldKey", key.checkRelease(key: 63, hardwareDown: true, at: 10) == nil && key.active)
    check("talk.releaseCheckOnlyOwner", key.checkRelease(key: 61, hardwareDown: false, at: 10.1) == nil && key.active)
    check("talk.missedReleaseEndsFromHardware", key.checkRelease(key: 63, hardwareDown: false, at: 10.2) == .end
          && !key.held && !key.active && key.owner == nil)
    check("talk.missedReleaseEndsExactlyOnce", key.checkRelease(key: 63, hardwareDown: false, at: 10.4) == nil
          && key.event(key: 63, down: false, at: 10.5) == nil)
    check("talk.missedReleaseUsesStopGuard", key.event(key: 63, down: true, at: 10.6) == nil && !key.active)
    check("talk.missedGuardReleaseClearsHold", key.checkRelease(key: 63, hardwareDown: false, at: 10.7) == nil
          && !key.held && key.owner == nil)

    key = TalkKeyState()
    _ = key.event(key: 61, down: true, at: 20)
    check("talk.entirelyMissingReleaseEnds", key.checkRelease(key: 61, hardwareDown: false, at: 20.6) == .end && !key.active)
    key = TalkKeyState(); key.doubleTap = false
    _ = key.event(key: 42, down: true, at: 21)
    check("talk.missedSingleTapModeEnds", key.checkRelease(key: 42, hardwareDown: false, at: 21.1) == .end && !key.active)

    key = TalkKeyState()
    _ = key.event(key: 63, down: true, at: 30)
    check("talk.missedQuickReleaseCancelsNormally", key.checkRelease(key: 63, hardwareDown: false, at: 30.1) == .cancel
          && !key.active && !key.held)
    check("talk.missedTapCanBeginSecond", key.event(key: 63, down: true, at: 30.25) == .begin)
    check("talk.secondMissedTapLatchesNormally", key.checkRelease(key: 63, hardwareDown: false, at: 30.35) == .handsFree
          && key.handsFree && key.active && !key.held)
    check("talk.releaseCheckNeverEndsHandsFree", key.checkRelease(key: 63, hardwareDown: false, at: 40) == nil
          && key.handsFree && key.active)
    check("talk.otherKeyCheckNeverEndsHandsFree", key.checkRelease(key: 61, hardwareDown: false, at: 41) == nil
          && key.handsFree && key.active)
    check("talk.handsFreeStillStopsNormally", key.event(key: 63, down: true, at: 42) == .end)
    check("talk.missedHandsFreeStopReleaseSwallowed", key.checkRelease(key: 63, hardwareDown: false, at: 42.1) == nil
          && !key.held && key.owner == nil && !key.active)
    check("talk.missedStopReleaseKeepsGuard", key.event(key: 63, down: true, at: 42.3) == nil)

    key = TalkKeyState()
    _ = key.event(key: 63, down: true, at: 50)
    _ = key.otherKey()
    check("talk.cancelledHoldRecheckDoesNotEnd", key.checkRelease(key: 63, hardwareDown: false, at: 50.6) == nil
          && !key.active && !key.held && key.owner == nil)
    key = TalkKeyState()
    _ = key.event(key: 63, down: true, at: 51)
    key.rejectBegin()
    check("talk.failedBeginRecheckCannotLatch", key.checkRelease(key: 63, hardwareDown: false, at: 51.1) == nil
          && !key.active && !key.held && !key.handsFree)
}

// Replay the real event times. Handler times must not shorten taps or the space between them.
do {
    var key = TalkKeyState()
    let trace: [(Bool, Double, Double)] = [
        (true, 877537.248089, 877537.596022), (false, 877537.326396, 877537.597452),
        (true, 877537.400087, 877537.600064), (false, 877537.510938, 877537.600817)
    ]
    let actions = trace.compactMap { down, event, _ in key.event(key: 63, down: down, at: event) }
    check("talk.delayedReleasedDoubleTap", actions == [.begin, .cancel, .begin, .handsFree] && key.handsFree)
    _ = key.event(key: 63, down: true, at: 877538)
    _ = key.event(key: 63, down: false, at: 877538.1)
    check("talk.delayedExtraStopTapBlocked", key.event(key: 63, down: true, at: 877538.2) == nil && !key.active)
    _ = key.event(key: 63, down: false, at: 877538.3)

    key = TalkKeyState()
    let first = key.event(key: 63, down: true, at: 877568.461358)
    let cancel = key.event(key: 63, down: false, at: 877568.533444)
    let second = key.event(key: 63, down: true, at: 877568.594213)
    let latch = key.event(key: 63, down: false, at: 877568.728678)
    check("talk.logged26msHandlerGapStillLatches", [first, cancel, second, latch] == [.begin, .cancel, .begin, .handsFree])

    key = TalkKeyState()
    _ = key.event(key: 63, down: true, at: 877540.094132)
    check("talk.upAcceptedEvenIfHardwareAlreadyDownAgain", key.event(key: 63, down: false, at: 877540.184299) == .cancel)
    _ = key.event(key: 63, down: true, at: 877540.243950)
    check("talk.nextPhysicalPressLatches", key.event(key: 63, down: false, at: 877540.363864) == .handsFree)

    key = TalkKeyState()
    check("talk.releasedDownStillBegins", key.event(key: 63, down: true, at: 1) == .begin)
    check("talk.releasedDownWithNoUpCompletesQuickTap", key.recoverReleasedDown(key: 63, eventAt: 1) == .cancel && !key.held)
    check("talk.recoveredTapOnlyCompletesOnce", key.recoverReleasedDown(key: 63, eventAt: 1) == nil)
    check("talk.lateQueuedUpIgnored", key.event(key: 63, down: false, at: 1.1) == nil)
    _ = key.event(key: 63, down: true, at: 1.2)
    check("talk.staleRecoveryCannotEndNewPress", key.recoverReleasedDown(key: 63, eventAt: 1) == nil && key.held)
    check("talk.otherKeyRecoveryCannotEndPress", key.recoverReleasedDown(key: 61, eventAt: 1.2) == nil && key.held)
    check("talk.twoRecoveredFastTapsLatch", key.recoverReleasedDown(key: 63, eventAt: 1.2) == .handsFree && !key.held)
    check("talk.recoveryNeverStopsLatchedDictation", key.recoverReleasedDown(key: 63, eventAt: 1.2) == nil && key.handsFree)
    check("talk.releasedStopDownEnds", key.event(key: 63, down: true, at: 2) == .end)
    check("talk.releasedStopDownReleaseSwallowed", key.recoverReleasedDown(key: 63, eventAt: 2) == nil && !key.held)
    check("talk.recoveredStopKeepsGuard", key.event(key: 63, down: true, at: 2.1) == nil && !key.active)
    _ = key.recoverReleasedDown(key: 63, eventAt: 2.1)

    key = TalkKeyState()
    _ = key.event(key: 63, down: true, at: 10)
    _ = key.event(key: 63, down: false, at: 11)
    check("talk.finishingStillBlocksNewRecording", key.event(key: 63, down: true, canBegin: false, at: 12) == nil)
    _ = key.event(key: 63, down: false, canBegin: false, at: 12.1)
    // Finishing ends at 15. The first tap can begin immediately, with no stale tap/guard from the old dictation.
    check("talk.firstTapImmediatelyAfterFinishBegins", key.event(key: 63, down: true, at: 15) == .begin)
    _ = key.event(key: 63, down: false, at: 15.08)
    check("talk.secondTapImmediatelyAfterFinishBegins", key.event(key: 63, down: true, at: 15.15) == .begin)
    check("talk.doubleTapImmediatelyAfterFinishLatches", key.event(key: 63, down: false, at: 15.25) == .handsFree)

    key = TalkKeyState()
    check("talk.ownDelayedDownCannotBegin", key.event(key: 63, down: true, ownEvent: true, at: 20) == nil)
    check("talk.ownDelayedDownCannotSeedRecovery", key.recoverReleasedDown(key: 63, eventAt: 20) == nil && !key.active)
}

// Paste policy is exercised without posting a single key or touching the general clipboard.
do {
    var attempt = PasteAttempt(at: 0)
    func step(_ now: Double, held: Bool = false, target: Bool = true, clipboard: Bool = true,
              landed: Bool = false) -> PasteAttempt.Decision {
        attempt.next(at: now, modifiersDown: held, sameTarget: target, clipboardOwned: clipboard, landed: landed)
    }
    check("paste.shortcutWaitsForModifiers", step(0, held: true) == .wait && attempt.postedAt == nil)
    check("paste.noPostWhileControlOptionHeld", step(0.8, held: true) == .wait && attempt.postedAt == nil)
    check("paste.releaseMustSettle", step(0.9) == .wait)
    check("paste.shortcutPostsAfterRelease", step(0.95) == .post)
    check("paste.postIsNotSuccess", step(1) == .wait)
    check("paste.noPrematureHalfSecondRestore", step(1.5) == .wait)
    check("paste.slowElectronSuccessConfirmed", step(2.1, landed: true) == .confirmed)

    attempt = PasteAttempt(at: 10)
    check("paste.menuStartsWithoutShortcut", step(10) == .wait)
    check("paste.menuPostsAfterStableRelease", step(10.04) == .post)
    check("paste.menuSuccessNeedsEvidence", step(10.1, landed: true) == .confirmed)
    attempt = PasteAttempt(at: 20)
    _ = step(20, held: true)
    check("paste.heldShortcutTimesOutWithoutPosting", step(21.21, held: true) == .failed("shortcut keys still held") && attempt.postedAt == nil)
    attempt = PasteAttempt(at: 30)
    _ = step(30); _ = step(30.04)
    check("paste.undeliveredPasteFails", step(32.1) == .failed("delivery not confirmed"))
    attempt = PasteAttempt(at: 40)
    _ = step(40, held: true)
    check("paste.focusChangeBeforePostFails", step(40.1, target: false) == .failed("target changed") && attempt.postedAt == nil)
    attempt = PasteAttempt(at: 50)
    _ = step(50); _ = step(50.04)
    check("paste.focusChangeAfterPostFails", step(50.1, target: false, landed: true) == .failed("target changed"))
    attempt = PasteAttempt(at: 60)
    check("paste.newClipboardBeforePostFails", step(60.1, clipboard: false) == .failed("clipboard changed before posting"))
    attempt = PasteAttempt(at: 70)
    _ = step(70); _ = step(70.04)
    check("paste.newClipboardAfterPostDoesNotInventFailure", step(70.1, clipboard: false, landed: true) == .confirmed)
    attempt = PasteAttempt(at: 80)
    _ = step(80); _ = step(80.02, held: true)
    check("paste.modifierRepressResetsStableWait", step(80.04) == .wait)
    check("paste.releasedAgainThenPosts", step(80.08) == .post)

    let evidence = PasteEvidence(before: "Hello world", range: NSRange(location: 6, length: 5), text: "🌍")
    check("paste.selectedUTF16ReplacementConfirmed", evidence.landed(value: "Hello 🌍", range: NSRange(location: 8, length: 0)))
    check("paste.unchangedBoxNeverConfirms", !evidence.landed(value: "Hello world", range: NSRange(location: 6, length: 5)))
    check("paste.unrelatedEditNeverConfirms", !evidence.landed(value: "Other words", range: NSRange(location: 8, length: 0)))
    let unreadable = PasteEvidence(before: nil, range: NSRange(location: 4, length: 0), text: "hi")
    check("paste.unreadableValueExpectedCursorConfirms", unreadable.landed(value: nil, range: NSRange(location: 6, length: 0)))
    check("paste.unreadableValueWrongCursorFails", !unreadable.landed(value: nil, range: NSRange(location: 5, length: 0)))
    check("paste.noReadableEvidenceNeverConfirms", !PasteEvidence(before: nil, range: nil, text: "hi").landed(value: nil, range: nil))
    let same = PasteEvidence(before: "hello", range: NSRange(location: 0, length: 5), text: "hello")
    check("paste.identicalSelectedTextNeedsCursorChange", same.landed(value: "hello", range: NSRange(location: 5, length: 0)))
    let pb = NSPasteboard(name: NSPasteboard.Name("rv-paste-failure-\(UUID().uuidString)"))
    pb.clearContents(); pb.setString("old clipboard", forType: .string)
    let saved = ClipboardSnapshot.take(pb)
    let failedLoan = PasteClipboardLoan("kept dictation", pasteboard: pb)!
    check("paste.failedDeliveryKeepsWordsForManualPaste", failedLoan.finish(confirmed: false) == .kept
          && pb.string(forType: .string) == "kept dictation" && !saved.matches(pb))
    saved.restore(to: pb)
    let confirmedLoan = PasteClipboardLoan("landed dictation", pasteboard: pb)!
    check("paste.confirmedDeliveryRestoresSnapshot", confirmedLoan.finish(confirmed: true) == .restored && saved.matches(pb))
    let changedLoan = PasteClipboardLoan("dictation", pasteboard: pb)!
    pb.clearContents(); pb.setString("new user copy", forType: .string)
    check("paste.newCopyPreservedAfterSuccess", changedLoan.finish(confirmed: true) == .changed && pb.string(forType: .string) == "new user copy")
    check("paste.newCopyPreservedAfterFailure", changedLoan.finish(confirmed: false) == .changed && pb.string(forType: .string) == "new user copy")
    check("paste.invalidCursorDoesNotConfirmOrCrash", !PasteEvidence(before: "hi", range: NSRange(location: NSNotFound, length: 0), text: "x").landed(value: "hi", range: nil))
    pb.releaseGlobally()
}

// Inspect synthetic event construction only. None of these events are posted.
do {
    let me = Int64(ProcessInfo.processInfo.processIdentifier)
    check("events.ownPID", VoiceEvents.isOwn(pid: me, userData: 0))
    check("events.ownMarker", VoiceEvents.isOwn(pid: -1, userData: VoiceEvents.marker))
    check("events.hardwareNotOwn", !VoiceEvents.isOwn(pid: 0, userData: 0))
    let paste = VoiceEvents.keyboardPair(key: 9, flags: .maskCommand)
    check("events.pastePairConstructed", paste != nil)
    check("events.pasteDownCommandOnly", paste?.down.flags == .maskCommand)
    check("events.pasteUpClearsCommand", paste?.up.flags.isEmpty == true)
    check("events.pasteSourcePrivate", paste?.down.getIntegerValueField(.eventSourceStateID) != Int64(CGEventSourceStateID.combinedSessionState.rawValue)
          && paste?.down.getIntegerValueField(.eventSourceStateID) != Int64(CGEventSourceStateID.hidSystemState.rawValue))
    check("events.bothMarked", paste?.down.getIntegerValueField(.eventSourceUserData) == VoiceEvents.marker
          && paste?.up.getIntegerValueField(.eventSourceUserData) == VoiceEvents.marker)
    let typing = VoiceEvents.keyboardPair(key: 0)
    check("events.typingHasNoModifiers", typing?.down.flags.isEmpty == true && typing?.up.flags.isEmpty == true)
    let media = VoiceEvents.playPausePair()
    check("events.mediaPairConstructed", media != nil)
    check("events.mediaHasNoModifiers", media?.down.flags.isEmpty == true && media?.up.flags.isEmpty == true)
    check("events.mediaBothMarked", media?.down.getIntegerValueField(.eventSourceUserData) == VoiceEvents.marker
          && media?.up.getIntegerValueField(.eventSourceUserData) == VoiceEvents.marker)
    check("events.mediaSourcePrivate", media?.down.getIntegerValueField(.eventSourceStateID) != Int64(CGEventSourceStateID.combinedSessionState.rawValue)
          && media?.down.getIntegerValueField(.eventSourceStateID) != Int64(CGEventSourceStateID.hidSystemState.rawValue))
    check("events.mediaDownUp", media.flatMap { NSEvent(cgEvent: $0.down) }?.data1 == (16 << 16) | (0xA << 8)
          && media.flatMap { NSEvent(cgEvent: $0.up) }?.data1 == (16 << 16) | (0xB << 8))
    check("events.noFocusCannotType", !FocusGate.canType(kind: .unknown, hasFocusedElement: false))
    check("events.noFocusEvenIfTextCannotType", !FocusGate.canType(kind: .text, hasFocusedElement: false))
    check("events.controlCannotType", !FocusGate.canType(kind: .notText, hasFocusedElement: true))
    check("events.nativeEditorStillTypes", FocusGate.canType(kind: .unknown, hasFocusedElement: true))
    check("events.textBoxStillTypes", FocusGate.canType(kind: .text, hasFocusedElement: true))
}

// Media gate: never press play on a quiet Mac.
check("media.quiet", MediaGate.shouldPause(enabled: true, outputRunning: false) == false)
check("media.playing", MediaGate.shouldPause(enabled: true, outputRunning: true) == true)
check("media.off", MediaGate.shouldPause(enabled: false, outputRunning: true) == false)
check("media.router", MediaGate.isRouter("Boom 3D") && MediaGate.isRouter("SoundSource"))
check("media.silent", !MediaGate.isPlaying(peak: 0.0005) && !MediaGate.isPlaying(peak: nil))
check("media.loud", MediaGate.isPlaying(peak: 0.05))
check("media.chrome", !MediaGate.isRouter("Google Chrome Helper (Aperitif)"))
check("media.resume", MediaGate.shouldResume(paused: false) == false)
check("media.resume.ours", MediaGate.shouldResume(paused: true))
check("media.resume.newpress", !MediaGate.shouldResume(paused: true, recordingAgain: true))
check("media.resume.alreadyplaying", !MediaGate.shouldResume(paused: true, playingNow: true))
check("media.alerts", !MediaGate.isMedia("systemsoundserverd") && !MediaGate.isMedia("corespeechd") && !MediaGate.isMedia("Monologue"))
check("media.players", MediaGate.isMedia("Google Chrome Helper (Aperitif)") && MediaGate.isMedia("Music") && !MediaGate.isMedia("Boom 3D"))
// A double tap must wait for the first listen, never turn a busy tap into a silent result.
let listens = MediaListenQueue<Int>()
check("media.listen.firstTap", listens.submit(1) == 1)
check("media.listen.secondTapWaits", listens.submit(2) == nil)
check("media.listen.resumeWaits", listens.submit(3) == nil)
check("media.listen.secondTapRunsNext", listens.finish() == 2)
check("media.listen.quietWaits", listens.submit(4) == nil)
check("media.listen.resumeRunsNext", listens.finish() == 3)
check("media.listen.quietRunsNext", listens.finish() == 4)
check("media.listen.drained", listens.finish() == nil)
check("media.listen.availableAgain", listens.submit(5) == 5 && listens.finish() == nil)
check("media.listen.diagnosticStartsIdle", listens.submitIfIdle(6) == 6)
check("media.listen.diagnosticSkipsBusy", listens.submitIfIdle(7) == nil)
check("media.listen.realCheckStillQueues", listens.submit(8) == nil)
check("media.listen.diagnosticDoesNotQueue", listens.finish() == 8 && listens.finish() == nil)
check("media.listen.diagnosticAvailableAgain", listens.submitIfIdle(9) == 9 && listens.finish() == nil)

// Settings links and fallback order, without opening System Settings.
let settingsURLs: [(SystemSettingsLink, String, String)] = [
    (.accessibility, "com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility", "com.apple.preference.security?Privacy_Accessibility"),
    (.microphone, "com.apple.settings.PrivacySecurity.extension?Privacy_Microphone", "com.apple.preference.security?Privacy_Microphone"),
    (.systemAudio, "com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture", "com.apple.preference.security?Privacy_AudioCapture"),
    (.keyboard, "com.apple.Keyboard-Settings.extension", "com.apple.preference.keyboard"),
]
for (page, current, legacy) in settingsURLs {
    check("settings.\(page).url", page.url.absoluteString == "x-apple.systempreferences:\(current)")
    check("settings.\(page).legacy", page.fallbackURL.absoluteString == "x-apple.systempreferences:\(legacy)")
    var opened: [URL] = []
    let success = page.open { opened.append($0); return true }
    check("settings.\(page).noFallbackOnSuccess", success && opened == [page.url])
    opened = []
    let fallback = page.open { opened.append($0); return opened.count == 2 }
    check("settings.\(page).fallbackOnFailure", fallback && opened == [page.url, page.fallbackURL])
    opened = []
    let failure = page.open { opened.append($0); return false }
    check("settings.\(page).bothFail", !failure && opened == [page.url, page.fallbackURL])
}
func fk(_ r: String?, ed: Bool = false, set: Bool = false, web: Bool = false) -> FocusKind { FocusGate.kind(role: r, editableAncestor: ed, valueSettable: set, inBrowser: web) }
// Streaming cuts: only in a pause, never inside a word.
func tone(_ secs: Double) -> [Float] { (0..<Int(secs * 16000)).map { Float(sin(Double($0) * 0.05)) * 0.3 } }
func hush(_ secs: Double) -> [Float] { Array(repeating: 0.0005, count: Int(secs * 16000)) }
let ch = Chunker()
check("chunk.tooSoon", ch.cut(tone(2) + hush(1), from: 0) == nil)
let talk = tone(5) + hush(0.8) + tone(2)
if let c = ch.cut(talk, from: 0) { check("chunk.inPause", c > 5 * 16000 && c < Int(5.8 * 16000)) } else { check("chunk.inPause", false) }
check("chunk.shortGap", ch.cut(tone(5) + hush(0.2) + tone(2), from: 0) == nil)
let longTalk = tone(26)
if let c = ch.cut(longTalk, from: 0) { check("chunk.forced", c >= 4 * 16000 && c <= 25 * 16000) } else { check("chunk.forced", false) }
check("chunk.fromLastCut", ch.cut(talk + tone(1), from: 6 * 16000) == nil)
check("quiet.end", Chunker.endsQuiet(tone(2) + hush(0.5), from: 0) && !Chunker.endsQuiet(tone(2), from: 0) && !Chunker.endsQuiet(hush(2), from: 0))
check("quiet.after", !Chunker.hasSpeech(tone(2) + hush(1), from: 2 * 16000 + 800, reference: 0) && Chunker.hasSpeech(tone(2) + hush(0.5) + tone(1), from: 2 * 16000 + 800, reference: 0))
// How you talk: speech time and the pauses between stretches of speech.
var tp = TalkProfile()
tp.add(tone(2) + hush(0.3) + tone(2) + hush(1.0) + tone(1), words: 12)
check("talk.counted", tp.dictations == 1 && tp.words == 12 && abs(tp.speaking - 5) < 0.2)
check("talk.gaps", tp.gaps.reduce(0, +) == 2)
check("talk.default", tp.pauseSeconds == 0.5 && tp.wordsPerMinute == nil && tp.summary == nil)
var slow = TalkProfile()
for _ in 0..<25 { slow.add(tone(3) + hush(0.7) + tone(3) + hush(0.75) + tone(3) + hush(0.7) + tone(3), words: 25) }
check("talk.learnsSlowPauses", slow.pauseSeconds >= 0.7 && slow.pauseSeconds <= 1.0)
check("talk.wpm", slow.wordsPerMinute.map { $0 > 100 && $0 < 150 } == true)
var fast = TalkProfile()
for _ in 0..<25 { fast.add(tone(3) + hush(0.2) + tone(3) + hush(0.25) + tone(3) + hush(0.2) + tone(3), words: 40) }
check("talk.floor", fast.pauseSeconds == 0.4)
// Learning fixes: small word swaps only, learned the second time.
check("fix.name", Corrections.find(typed: "I was reading so well last night", now: "I was reading Sowell last night") == [Corrections.Fix(heard: "so well", fixed: "Sowell")])
check("fix.twoWords", Corrections.find(typed: "open claw code and run it", now: "Hey, open Claude Code and run it. Thanks") == [Corrections.Fix(heard: "claw code", fixed: "Claude Code")])
check("fix.caseOnly", Corrections.find(typed: "send it to monica today", now: "send it to Monica today.").isEmpty)
check("fix.rewrite", Corrections.find(typed: "can you look at the file and tell me", now: "please review the attached document thoroughly").isEmpty)
check("fix.untouched", Corrections.find(typed: "this stays the same", now: "this stays the same and more words after").isEmpty)
check("fix.lastWord", Corrections.find(typed: "please call so well", now: "please call Sowell") == [Corrections.Fix(heard: "so well", fixed: "Sowell")])
check("fix.otherName", Corrections.find(typed: "please call Monica today", now: "please call Priya today").isEmpty)
var learned = Learned()
let f = Corrections.Fix(heard: "so well", fixed: "Sowell")
check("learn.once", learned.see(f) == false)
check("learn.twice", learned.see(f) == true && learned.see(f) == false)
// Hints from the screen: names and code-like words, not ordinary words or sentence starts.
let screen = Hints.fromScreen("Ask Cedric about the plan. Then open Claude Code and check fb36e2f in redpen_voice/main.swift. The weather is nice.")
check("hints.names", screen.contains("Cedric") && screen.contains("Claude") && screen.contains("Code") && screen.contains("fb36e2f"))
check("hints.code", screen.contains("redpen_voice/main.swift"))
check("hints.notOrdinary", !screen.contains("Then") && !screen.contains("The") && !screen.contains("weather") && !screen.contains("Ask"))
check("hints.line", Hints.line(names: ["Sowell", "Claude Code"], screen: ["sowell", "T3"]) == "Sowell, Claude Code, T3")
check("names.spellings", Names(text: "claw code = Claude Code\nSowell").spellings == ["Claude Code", "Sowell"])
check("focus.textbox", fk("AXTextArea") == .text)
check("focus.contenteditable", fk("AXGroup", ed: true, web: true) == .text)
check("focus.webpage", fk("AXWebArea", web: true) == .notText)
check("focus.player", fk("AXGroup", web: true) == .notText)
check("focus.button", fk("AXButton") == .notText)
check("focus.none", fk(nil) == .unknown)
check("focus.word", fk("AXLayoutArea") == .unknown && fk("AXScrollArea") == .unknown && fk("AXGroup") == .unknown)
check("focus.slider", fk("AXSlider", set: true) == .notText)
check("focus.settableGroup", fk("AXGroup", set: true, web: true) == .text)

// Silence: sound labels and invented phrases from a quiet mic are dropped, real words are kept.
check("silence.label", Silence.clean("*Loud sound*", peak: 0.03) == "")
check("silence.brackets", Silence.clean("[Music] (upbeat music)", peak: 0.5) == "")
check("silence.thanks.quiet", Silence.clean("Thank you.", peak: 0.035) == "")
check("silence.thanks.said", Silence.clean("Thank you.", peak: 0.4) == "Thank you.")
check("silence.mixed", Silence.clean("Send it today *cough* please.", peak: 0.5) == "Send it today please.", Silence.clean("Send it today *cough* please.", peak: 0.5))
check("silence.sentence", Silence.clean("Thank you for the notes.", peak: 0.03) == "Thank you for the notes.")

// Fillers: only sounds come out, every real word stays.
check("fillers.commas", Fillers.strip("So, um, I think we, we should ship it Friday.") == "So, I think we, we should ship it Friday.", Fillers.strip("So, um, I think we, we should ship it Friday."))
check("fillers.start", Fillers.strip("Um, I like it.") == "I like it.", Fillers.strip("Um, I like it."))
check("fillers.end", Fillers.strip("we should ship it um.") == "we should ship it.", Fillers.strip("we should ship it um."))
check("fillers.mid", Fillers.strip("Is it uh ready? Uh, yes.") == "Is it ready? Yes.", Fillers.strip("Is it uh ready? Uh, yes."))
check("fillers.words", Fillers.strip("I mean, you know, I like the umbrella and Uhura.") == "I mean, you know, I like the umbrella and Uhura.")
check("fillers.only", Fillers.strip("Um.") == "")
check("fillers.trailing", Fillers.strip("Let me think, hmm") == "Let me think", Fillers.strip("Let me think, hmm"))

// Tidy it up: a dropped "not" or a changed number means the raw words go in (D-817).
check("meaning.same", Meaning.changed("um so we don't ship it on Friday", "So we don't ship it on Friday.") == nil)
check("meaning.notDropped", Meaning.changed("we do not ship it", "We ship it.") == "negation")
check("meaning.ntDropped", Meaning.changed("I don't think so", "I think so.") == "negation")
check("meaning.number", Meaning.changed("send three copies", "Send two copies.") == "number")
check("meaning.numberWordToDigit", Meaning.changed("send three copies", "Send 3 copies.") == nil)
check("meaning.neverAdded", Meaning.changed("it works", "It never works.") == "negation")

// Fitting the sentence it lands in (D-817).
check("fit.midSentence", Fit.text("And we go.", before: "and then ", after: nil, keep: []) == "and we go.", Fit.text("And we go.", before: "and then ", after: nil, keep: []))
check("fit.afterStop", Fit.text("And we go.", before: "Done. ", after: nil, keep: []) == "And we go.")
check("fit.startOfBox", Fit.text("And we go.", before: "", after: nil, keep: []) == "And we go.")
check("fit.newLine", Fit.text("And we go.", before: "Hi\n", after: nil, keep: []) == "And we go.")
check("fit.keepI", Fit.text("I think so.", before: "and ", after: nil, keep: []) == "I think so.")
check("fit.keepName", Fit.text("Sowell said it.", before: "as ", after: nil, keep: ["Sowell"]) == "Sowell said it.")
check("fit.keepAcronym", Fit.text("NASA did.", before: "and ", after: nil, keep: []) == "NASA did.")
check("fit.beforeWord", Fit.text("We should go.", before: "Then ", after: "t", keep: []) == "we should go ", Fit.text("We should go.", before: "Then ", after: "t", keep: []))
check("fit.beforeSpace", Fit.text("We should go.", before: "Done. ", after: " ", keep: []) == "We should go.")
check("fit.keepQuestion", Fit.text("Should we go?", before: "", after: "t", keep: []) == "Should we go? ")

// The box a dictation started in (D-817): same box only, and its text must still start the same.
let f0 = CGRect(x: 100, y: 800, width: 600, height: 40)
let start = BoxPrint(role: "AXTextArea", identifier: nil, frame: f0, text: "Hello there")
check("box.sameElement", BoxMatch.same(start: start, now: start, nowText: "Hello there", sameElement: true))
check("box.sentAndCleared", !BoxMatch.same(start: start, now: start, nowText: "", sameElement: true))
check("box.otherBoxSameWindow", !BoxMatch.same(start: start, now: BoxPrint(role: "AXTextArea", identifier: nil, frame: CGRect(x: 100, y: 200, width: 300, height: 40), text: nil), nowText: "Hello there", sameElement: false))
check("box.newElementSameBoxGrew", BoxMatch.same(start: start, now: BoxPrint(role: "AXTextArea", identifier: nil, frame: CGRect(x: 100, y: 760, width: 600, height: 80), text: nil), nowText: "Hello there", sameElement: false))
check("box.sameId", BoxMatch.same(start: BoxPrint(role: "AXTextArea", identifier: "composer", frame: nil, text: "x", title: "Notes"), now: BoxPrint(role: "AXTextArea", identifier: "composer", frame: nil, text: nil, title: "Notes"), nowText: "x", sameElement: false))
check("box.unreadableOther", !BoxMatch.same(start: BoxPrint(role: "AXTextArea", identifier: "c", frame: f0, text: nil), now: BoxPrint(role: "AXTextArea", identifier: "c", frame: f0, text: nil), nowText: nil, sameElement: false))

// Growing/moving composers and changing titles are harmless in the same window and conversation.
let t3Start = BoxPrint(role: "AXTextArea", identifier: "composer", frame: f0, text: "", title: "Thread", url: "t3://thread-1")
let t3Grew = BoxPrint(role: "AXTextArea", identifier: "composer", frame: CGRect(x: 105, y: 690, width: 600, height: 150), text: nil, title: "Working", url: "t3://thread-1")
check("box.sameElementGrewAndMoved", BoxMatch.same(start: t3Start, now: t3Grew, nowText: "", sameElement: true))
check("box.titleChanged", BoxMatch.same(start: t3Start, now: t3Grew, nowText: "", sameElement: true))
check("box.otherWindow", BoxMatch.failure(start: t3Start, now: t3Grew, nowText: "", sameElement: true, sameWindow: false) == .window)
check("box.recreatedMovedSlightly", BoxMatch.same(start: start, now: BoxPrint(role: "AXTextArea", identifier: nil, frame: CGRect(x: 106, y: 766, width: 605, height: 80), text: nil), nowText: "Hello there", sameElement: false))
var ownDraft = t3Start
check("box.recordOwnDraft", ownDraft.recordEdit(before: "", range: NSRange(location: 0, length: 0), replacement: "My draft"))
check("box.ownDraftTyped", BoxMatch.same(start: ownDraft, now: t3Grew, nowText: "My draft", sameElement: true))
ownDraft.replaceBeforeCursor("draft", with: "checked words", cursor: 8)
check("box.ownDraftCorrected", BoxMatch.same(start: ownDraft, now: t3Grew, nowText: "My checked words", sameElement: true))
check("box.ownDraftSent", BoxMatch.failure(start: ownDraft, now: t3Grew, nowText: "", sameElement: true) == .text)
check("box.userDifferentText", !BoxMatch.same(start: ownDraft, now: t3Grew, nowText: "Someone else's message", sameElement: true))
check("box.userAppendedText", !BoxMatch.same(start: ownDraft, now: t3Grew, nowText: "My checked words plus mine", sameElement: true))
check("box.notArbitraryRebase", !ownDraft.recordEdit(before: "Unrelated", range: NSRange(location: 0, length: 0), replacement: "Oops"))
check("box.rebaseLeavesExpected", ownDraft.text == "My checked words")
let anotherThread = BoxPrint(role: "AXTextArea", identifier: "composer", frame: f0, text: nil, title: "Thread", url: "t3://thread-2")
check("box.nonemptyOtherConversation", BoxMatch.failure(start: ownDraft, now: anotherThread, nowText: "My checked words", sameElement: true) == .url)
check("box.emptyOtherConversation", BoxMatch.failure(start: t3Start, now: anotherThread, nowText: "", sameElement: true) == .url)
check("box.missingURL", BoxMatch.failure(start: t3Start, now: BoxPrint(role: "AXTextArea", identifier: "composer", frame: f0, text: nil, title: "Thread"), nowText: "", sameElement: true) == .url)
check("box.diagnostics", BoxMatch.differences(start: t3Start, now: t3Grew, nowText: "x", sameElement: false) == ["frame", "title", "text prefix/value", "element"])
let longText = String(repeating: "a", count: 220)
check("box.changeBeyondOldPrefix", !BoxMatch.same(start: BoxPrint(role: "AXTextArea", identifier: nil, frame: f0, text: longText), now: start, nowText: String(repeating: "a", count: 210) + "changed", sameElement: true))
var unicodeBox = BoxPrint(role: "AXTextArea", identifier: nil, frame: f0, text: "Hi 🎉")
check("box.ownUTF16Edit", unicodeBox.recordEdit(before: "Hi 🎉", range: NSRange(location: 5, length: 0), replacement: " there") && unicodeBox.text == "Hi 🎉 there")
check("box.badEditRange", !unicodeBox.recordEdit(before: "Hi 🎉 there", range: NSRange(location: 999, length: 1), replacement: "x"))

check("box.initiallyEmptyUserTypedAndSent", BoxMatch.failure(start: t3Start, now: t3Grew, nowText: "", sameElement: true, userEdited: true) == .text)
check("box.nonemptyURLDoesNotExcuseUserEdit", !BoxMatch.same(start: ownDraft, now: t3Grew, nowText: "My checked words", sameElement: true, userEdited: true))

var middleDraft = BoxPrint(role: "AXTextArea", identifier: nil, frame: f0, text: "Mine. Draft Later. Tail stays.")
middleDraft.replaceBeforeCursor("Draft Later.", with: "Checked later.", cursor: 18)
check("box.ownDraftInMiddle", middleDraft.text == "Mine. Checked later. Tail stays.")

// App whitespace normalization must not stop drafts or corrupt the next known edit's UTF-16 offsets.
let spacedDraft = BoxPrint(role: "AXTextArea", identifier: "composer", frame: f0,
                           text: "  My  checked\u{00a0}words \n", title: "Thread", url: "t3://thread-1")
for (name, value) in [("trailingSpaceTrimmed", "  My  checked\u{00a0}words\n"),
                      ("newlineTrimmed", "  My  checked\u{00a0}words "),
                      ("leadingSpaceTrimmed", "My  checked\u{00a0}words \n"),
                      ("doubleSpacesCollapsed", " My checked\u{00a0}words \n"),
                      ("nbspToSpace", "  My  checked words \n"),
                      ("allWhitespaceNormalized", "My checked words")] {
    check("box." + name, BoxMatch.same(start: spacedDraft, now: t3Grew, nowText: value, sameElement: true))
}
check("box.normalizationStillRejectsEdit", !BoxMatch.same(start: spacedDraft, now: t3Grew, nowText: "My changed words", sameElement: true))
check("box.normalizationKeepsWordBoundaries", !BoxText.same("some words", "somewords"))
check("box.normalizationKeepsCase", !BoxText.same("Some words", "some words"))
check("box.normalizationKeepsPunctuation", !BoxText.same("Some words.", "Some words"))
check("box.normalizedButHardwareEdited", !BoxMatch.same(start: spacedDraft, now: t3Grew, nowText: "My checked words", sameElement: true, userEdited: true))
check("box.normalizedButDifferentConversation", !BoxMatch.same(start: spacedDraft, now: anotherThread, nowText: "My checked words", sameElement: true))
check("box.normalizedButDifferentWindow", !BoxMatch.same(start: spacedDraft, now: t3Grew, nowText: "My checked words", sameElement: true, sameWindow: false))
check("box.normalizationDoesNotExcuseUnreadable", !BoxMatch.same(start: spacedDraft, now: t3Grew, nowText: nil, sameElement: true))
var normalizedDraft = spacedDraft
check("box.nextEditAfterTrim", normalizedDraft.recordEdit(before: "My checked words", range: NSRange(location: 16, length: 0), replacement: " again "))
check("box.nextEditTracksActualOffsets", normalizedDraft.text == "My checked words again ")
check("box.nextEditRejectsNewCharacters", !normalizedDraft.recordEdit(before: "My checked words again plus mine", range: NSRange(location: 0, length: 0), replacement: "x"))
check("box.emptyWhitespaceEquivalent", BoxText.same(" \n", ""))

// Stopped drafts finish with the WHOLE checked text, never only the engine's last tail. These are the
// production replacement planner and delivery checks, with no AX edits or keyboard events posted.
let stoppedDraft = DraftReplacement(expectedBox: "Prefix. My draft ", actual: "Prefix. My draft",
                                    cursor: NSRange(location: 16, length: 0), draft: "My draft ",
                                    replacement: "My checked words and the rest.")
check("draft.trimmedSuffixActualRange", stoppedDraft?.range == NSRange(location: 8, length: 8))
check("draft.completeEndingAfterStop", stoppedDraft?.expected == "Prefix. My checked words and the rest.")
check("draft.completeEndingConfirmed", stoppedDraft?.landed("Prefix. My checked words and the rest.\n") == true)
check("draft.postedButUnchangedNotConfirmed", stoppedDraft?.landed("Prefix. My draft") == false)
check("draft.partialEndingNotConfirmed", stoppedDraft?.landed("Prefix. My checked words") == false)
check("draft.unreadableNotConfirmed", stoppedDraft?.landed(nil) == false)
let middleNormalized = DraftReplacement(expectedBox: "🎉 Mine.  Draft  later. \nTail stays.",
                                         actual: "🎉 Mine. Draft later. Tail stays.",
                                         cursor: NSRange(location: 22, length: 0), draft: " Draft  later. \n",
                                         replacement: " Checked words. ")
check("draft.normalizedMiddleRange", middleNormalized?.range == NSRange(location: 8, length: 14))
check("draft.normalizedMiddleKeepsBothSides", middleNormalized?.expected == "🎉 Mine. Checked words. Tail stays.")
check("draft.normalizedFullBoxEditRejected", DraftReplacement(expectedBox: "Prefix. My draft ", actual: "Edited. My draft", cursor: NSRange(location: 16, length: 0), draft: "My draft ", replacement: "Checked.") == nil)
check("draft.selectionRejected", DraftReplacement(expectedBox: "My draft", actual: "My draft", cursor: NSRange(location: 0, length: 8), draft: "My draft", replacement: "Checked.") == nil)
check("draft.invalidCursorRejected", DraftReplacement(expectedBox: "My draft", actual: "My draft", cursor: NSRange(location: NSNotFound, length: 0), draft: "My draft", replacement: "Checked.") == nil)
check("draft.wrongSuffixRejected", DraftReplacement(expectedBox: "My draft", actual: "My draft", cursor: NSRange(location: 8, length: 0), draft: "other draft", replacement: "Checked.") == nil)
check("draft.wordSubstringRejected", DraftReplacement(expectedBox: "undraft", actual: "undraft", cursor: NSRange(location: 7, length: 0), draft: "draft", replacement: "Checked.") == nil)
let normalizedOnly = DraftReplacement(expectedBox: " My  words \n", actual: "My words", cursor: NSRange(location: 8, length: 0), draft: " My  words \n", replacement: " My words")
check("draft.normalizedAlreadyPresent", normalizedOnly?.landed("My words") == true)
let emptyChecked = DraftReplacement(expectedBox: "Prefix. draft", actual: "Prefix. draft", cursor: NSRange(location: 13, length: 0), draft: " draft", replacement: "")
check("draft.checkedEmptyPreservesPrefix", emptyChecked?.expected == "Prefix.")
check("draft.checkedDeletionNeedsEvidence", emptyChecked?.landed("Prefix. draft") == false && emptyChecked?.landed("Prefix.") == true)

check("box.noURLChangedConversationTitle", BoxMatch.failure(start: BoxPrint(role: "AXTextArea", identifier: "composer", frame: f0, text: "Same text", title: "Chat A"), now: BoxPrint(role: "AXTextArea", identifier: "composer", frame: f0, text: nil, title: "Chat B"), nowText: "Same text", sameElement: true) == .title)

// The video's words come off the start; yours stay (D-817).
check("echo.strip", MediaEcho.strip("Please tell me what. Why is listening to horror music so comfortable?", video: "please tell me what") == "Why is listening to horror music so comfortable?", MediaEcho.strip("Please tell me what. Why is listening to horror music so comfortable?", video: "please tell me what"))
check("echo.misheard", MediaEcho.strip("Please tel me what so we ship it", video: "please tell me what the") == "So we ship it", MediaEcho.strip("Please tel me what so we ship it", video: "please tell me what the"))
check("echo.nothingPlayed", MediaEcho.strip("So we ship it", video: "") == "So we ship it")
check("echo.noMatch", MediaEcho.strip("So we ship it", video: "the weather tomorrow") == "So we ship it")
check("echo.laterRepeatKept", MediaEcho.strip("Tell me more. Then tell me what you think about tell me", video: "tell me") == "More. Then tell me what you think about tell me", MediaEcho.strip("Tell me more. Then tell me what you think about tell me", video: "tell me"))

// Round 2 (Codex): an empty box proves nothing by its text; scattered words never take the sentence; minus signs count.
let emptyStart = BoxPrint(role: "AXTextArea", identifier: nil, frame: f0, text: "", title: "T3 Code", url: "thread-1")
check("box.emptySameThread", BoxMatch.same(start: emptyStart, now: BoxPrint(role: "AXTextArea", identifier: nil, frame: f0, text: nil, title: "T3 Code", url: "thread-1"), nowText: "", sameElement: true))
check("box.emptyOtherThread", !BoxMatch.same(start: emptyStart, now: BoxPrint(role: "AXTextArea", identifier: nil, frame: f0, text: nil, title: "T3 Code", url: "thread-2"), nowText: "", sameElement: true))
check("box.emptyNoContext", !BoxMatch.same(start: BoxPrint(role: "AXTextArea", identifier: nil, frame: f0, text: "", title: nil), now: BoxPrint(role: "AXTextArea", identifier: nil, frame: f0, text: nil, title: nil), nowText: "", sameElement: true))
check("echo.scatteredKept", MediaEcho.strip("I need the report tomorrow", video: "the weather tomorrow") == "I need the report tomorrow", MediaEcho.strip("I need the report tomorrow", video: "the weather tomorrow"))
check("echo.preRollWord", MediaEcho.strip("Wait please tell me what so we ship it", video: "please tell me what") == "So we ship it", MediaEcho.strip("Wait please tell me what so we ship it", video: "please tell me what"))
check("meaning.minus", Meaning.changed("send -5 copies", "Send 5 copies.") == "number")
check("meaning.hyphenNumbers", Meaning.changed("send twenty-one copies today", "Send twenty-two copies today.") == "number")
check("meaning.hyphenSame", Meaning.changed("send twenty-one copies", "Send twenty-one copies.") == nil)
check("meaning.date", Meaning.changed("ship on 2026-10-11", "Ship on 2026-11-10.") == "number")
check("meaning.dateSame", Meaning.changed("ship on 2026-10-11", "Ship on 2026-10-11.") == nil)

// The clipboard, borrowed for a paste, comes back exactly: every item, every format, the same bytes (D-825).
do {
    let pb = NSPasteboard(name: NSPasteboard.Name("redpen-voice-test-\(UUID().uuidString)"))
    pb.clearContents()
    let a = NSPasteboardItem(); a.setString("first item", forType: .string); a.setData(Data([1, 2, 3, 255]), forType: NSPasteboard.PasteboardType("com.example.custom"))
    let b = NSPasteboardItem(); b.setString("second", forType: .string); b.setData(Data("{\\rtf1 hi}".utf8), forType: .rtf)
    pb.writeObjects([a, b])
    let saved = ClipboardSnapshot.take(pb)
    pb.clearContents(); pb.setString("the dictation", forType: .string)
    check("clipboard.borrowed", !saved.matches(pb))
    saved.restore(to: pb)
    check("clipboard.restoredExactly", saved.matches(pb) && pb.pasteboardItems?.count == 2 && pb.pasteboardItems?.first?.data(forType: NSPasteboard.PasteboardType("com.example.custom")) == Data([1, 2, 3, 255]))
    pb.clearContents()
    let empty = ClipboardSnapshot.take(pb)
    pb.setString("x", forType: .string); empty.restore(to: pb)
    check("clipboard.emptyStaysEmpty", (pb.pasteboardItems ?? []).isEmpty)
    pb.releaseGlobally()
}

// History window (D-825): keep a week, keep nothing, delete one, and the file stays readable only by you.
do {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rv-history-test-\(UUID().uuidString).jsonl")
    let h = History(url: url)
    let now = Date()
    let old = Entry(date: now.addingTimeInterval(-9 * 24 * 3600), raw: "old one", seconds: 2, app: "Notes", inserted: true)
    let recent = Entry(date: now.addingTimeInterval(-3600), raw: "recent one", seconds: 2, app: "Notes", inserted: true)
    let newest = Entry(date: now, raw: "newest one", seconds: 2, app: "Mail", inserted: true)
    for e in [old, recent, newest] { h.append(e) }
    check("history.keepWeek", History.kept(h.all(), keep: "week", now: now).map(\.raw) == ["recent one", "newest one"])
    check("history.keepNone", History.kept(h.all(), keep: "none", now: now).isEmpty)
    check("history.keepAll", History.kept(h.all(), keep: "all", now: now).count == 3)
    h.remove(recent)
    check("history.removeOne", h.all().map(\.raw) == ["old one", "newest one"])
    h.apply(keep: "week", now: now)
    check("history.applyWeek", h.all().map(\.raw) == ["newest one"])
    let perms = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0
    check("history.private", perms == 0o600, String(perms, radix: 8))
    h.apply(keep: "none", now: now)
    check("history.applyNone", h.all().isEmpty)
    try? FileManager.default.removeItem(at: url)
}

// Stats (D-837): daily counts in their own file, numbers only; the history's keep choice and deletes never touch them.
do {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rv-stats-test-\(UUID().uuidString)")
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Toronto")!
    let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 15))!
    let yesterday = cal.date(byAdding: .day, value: -1, to: now)!, tenDaysAgo = cal.date(byAdding: .day, value: -10, to: now)!
    let statsURL = dir.appendingPathComponent("stats.json")
    let h = History(url: dir.appendingPathComponent("history.jsonl"))
    // Backfill: the history's dictations are counted once; a press that caught nothing is not.
    h.append(Entry(date: tenDaysAgo, raw: "one two three four", seconds: 3, app: "Notes", inserted: true))
    h.append(Entry(date: yesterday, raw: "five six", seconds: 2, app: "Mail", inserted: true))
    h.append(Entry(date: yesterday, raw: "", seconds: 1, app: "Mail", inserted: false))
    let st = StatsStore(url: statsURL)
    check("stats.backfillRuns", st.backfillIfNeeded(h.all(), calendar: cal))
    check("stats.backfillCounts", Stats.score(st.days).words == 6 && Stats.score(st.days).count == 2 && Stats.score(st.days).seconds == 5, "\(st.days)")
    check("stats.backfillEngine", st.days.allSatisfy { $0.engine == "unknown" })
    check("stats.backfillOnce", !st.backfillIfNeeded(h.all(), calendar: cal) && Stats.score(st.days).count == 2)
    check("stats.backfillOnceAfterReopen", !StatsStore(url: statsURL).backfillIfNeeded(h.all(), calendar: cal))
    // The daily store: one row a day per engine, adding up.
    st.add(words: 100, seconds: 40, engine: "whisper", date: now, calendar: cal)
    st.add(words: 50, seconds: 20, engine: "whisper", date: now, calendar: cal)
    st.add(words: 30, seconds: 10, engine: "live", date: now, calendar: cal)
    let todayKey = StatsStore.key(now, calendar: cal)
    check("stats.key", todayKey == "2026-10-27", todayKey)
    check("stats.onePerDayEngine", st.days.filter { $0.day == todayKey }.count == 2 && st.days.first { $0.day == todayKey && $0.engine == "whisper" }?.dictations == 2)
    let today = Stats.today(st.days, now: now, calendar: cal)
    check("stats.today", today.words == 180 && today.count == 3 && today.seconds == 70, "\(today)")
    check("stats.todayWPM", today.wordsPerMinute == 154, "\(today.wordsPerMinute)")
    check("stats.allTime", Stats.score(st.days).words == 186 && Stats.score(st.days).count == 5)
    check("stats.last30", Stats.lastDays(30, st.days, now: now, calendar: cal).words == 186)
    check("stats.last7", Stats.lastDays(7, st.days, now: now, calendar: cal).words == 182)
    // Oct 27 2026 is a Tuesday: a week from Monday takes in yesterday, a week from Tuesday doesn't.
    var mon = cal; mon.firstWeekday = 2
    var tue = cal; tue.firstWeekday = 3
    check("stats.thisWeek", Stats.thisWeek(st.days, now: now, calendar: mon).words == 182 && Stats.thisWeek(st.days, now: now, calendar: tue).words == 180)
    check("stats.reopened", StatsStore(url: statsURL).days == st.days)
    let daily = Stats.daily(st.days, n: 30, now: now, calendar: cal)
    check("stats.dailySlots", daily.count == 30 && daily.last?.score.words == 180 && daily[28].score.words == 2 && daily[19].score.words == 4, "\(daily.map(\.score.words))")
    let sp = Stats.speed(st.days, now: now, calendar: cal)
    check("stats.speedDaily", !sp.weekly && sp.points.count == 30 && sp.points.last?.wpm == 154 && sp.points[28].wpm == nil, "\(sp.points.map(\.wpm))")
    let perms = (try? FileManager.default.attributesOfItem(atPath: statsURL.path)[.posixPermissions] as? Int) ?? 0
    check("stats.private", perms == 0o600, String(perms, radix: 8))
    // Numbers only: no word said ever reaches the file.
    let body = (try? String(contentsOf: statsURL, encoding: .utf8)) ?? ""
    check("stats.numbersOnly", !body.contains("five") && !body.contains("one two") && !body.contains("Notes"))
    // Keep a week, keep nothing, and deleting a dictation leave the stats as they were.
    let before = st.days
    h.apply(keep: "week", now: now)
    check("stats.keepWeekIntact", StatsStore(url: statsURL).days == before && h.all().count == 2)
    h.remove(h.all()[0])
    h.apply(keep: "none", now: now)
    check("stats.keepNoneIntact", StatsStore(url: statsURL).days == before && h.all().isEmpty)
    // Reset: back to zero, and the history is never counted again.
    h.append(Entry(date: now, raw: "after the reset", seconds: 2, app: "Notes", inserted: true))
    st.reset()
    check("stats.reset", st.days.isEmpty && StatsStore(url: statsURL).days.isEmpty && Stats.score(st.days).words == 0)
    check("stats.resetNoBackfill", !StatsStore(url: statsURL).backfillIfNeeded(h.all(), calendar: cal) && StatsStore(url: statsURL).days.isEmpty)
    check("stats.resetHistoryKept", h.all().count == 1)
    // Your typing speed changes minutes saved: 180 words in 70 s against 40 wpm is 4.5 min less 1.2 = 3; against 20, 8.
    check("stats.typing40", Stats.today(before, now: now, calendar: cal, typing: 40).minutesSaved == 3)
    check("stats.typing20", Stats.today(before, now: now, calendar: cal, typing: 20).minutesSaved == 8)
    check("stats.typing120", Stats.today(before, now: now, calendar: cal, typing: 120).minutesSaved == 0)
    check("stats.savedText", Score.savedText(9) == "9 min" && Score.savedText(65) == "1 h 5 min" && Score.savedText(120) == "2 h" && Score.savedText(1_010) == "17 h")
    // Speed by week once there is more than six weeks of counts; a short day is left out.
    let s2 = StatsStore(url: dir.appendingPathComponent("stats2.json"))
    s2.add(words: 500, seconds: 240, engine: "whisper", date: cal.date(byAdding: .day, value: -60, to: now)!, calendar: cal)
    s2.add(words: 5, seconds: 2, engine: "whisper", date: now, calendar: cal)
    let sw = Stats.speed(s2.days, now: now, calendar: cal)
    check("stats.speedWeekly", sw.weekly && sw.points.count >= 9 && sw.points.count <= 10 && sw.points.first?.wpm == 125 && sw.points.last?.wpm == nil, "\(sw.points.map(\.wpm))")
    // The recording path itself, under each keep choice: the history keeps what you chose, the stats count every one.
    for keep in ["all", "week", "none"] {
        let k = dir.appendingPathComponent("rec-\(keep)")
        let kh = History(url: k.appendingPathComponent("history.jsonl")), ks = StatsStore(url: k.appendingPathComponent("stats.json"))
        Dictations.record(Entry(date: tenDaysAgo, raw: "an older one here", seconds: 2, app: "Notes", inserted: true), keep: keep, history: kh, stats: ks, engine: "whisper", calendar: cal)
        Dictations.record(Entry(date: now, raw: "a new one", seconds: 1, app: "Notes", inserted: true), keep: keep, history: kh, stats: ks, engine: "live", calendar: cal)
        let reopened = StatsStore(url: k.appendingPathComponent("stats.json"))
        let wantHistory = ["all": 2, "week": 1, "none": 0][keep]!
        check("stats.record.\(keep)", Stats.score(reopened.days).words == 7 && Stats.score(reopened.days).count == 2 && kh.all().count == wantHistory,
              "\(Stats.score(reopened.days)) history \(kh.all().count)")
    }
    // A damaged file is moved aside, never written over; the history is then counted into a new one.
    let dmg = dir.appendingPathComponent("damaged"); try? FileManager.default.createDirectory(at: dmg, withIntermediateDirectories: true)
    let dmgURL = dmg.appendingPathComponent("stats.json")
    try? Data("{not json".utf8).write(to: dmgURL)
    let ds = StatsStore(url: dmgURL)
    let aside = ((try? FileManager.default.contentsOfDirectory(atPath: dmg.path)) ?? []).filter { $0.hasPrefix("stats.damaged-") }
    check("stats.damagedMovedAside", aside.count == 1 && ds.writable && ds.days.isEmpty && !ds.backfilled && ds.problem != nil, "\(aside)")
    check("stats.damagedKept", aside.first.flatMap { try? String(contentsOf: dmg.appendingPathComponent($0), encoding: .utf8) } == "{not json")
    // Read only (for pictures): a damaged file stays where it is, and nothing is ever written.
    let ro2 = dir.appendingPathComponent("ro2"); try? FileManager.default.createDirectory(at: ro2, withIntermediateDirectories: true)
    try? Data("{not json".utf8).write(to: ro2.appendingPathComponent("stats.json"))
    let rd = StatsStore.readOnly(url: ro2.appendingPathComponent("stats.json"))
    rd.add(words: 3, seconds: 1, engine: "whisper", date: now, calendar: cal)
    check("stats.readOnlyLeavesDamaged", !rd.writable && (try? String(contentsOf: ro2.appendingPathComponent("stats.json"), encoding: .utf8)) == "{not json"
          && ((try? FileManager.default.contentsOfDirectory(atPath: ro2.path)) ?? []).count == 1)
    check("stats.readOnlyReads", StatsStore.readOnly(url: statsURL).days == st.days && !StatsStore.readOnly(url: statsURL).writable)
    // A file that can't be read is left exactly as it is, and nothing is written over it.
    let lockedURL = dir.appendingPathComponent("locked-stats.json")
    try? Data("{\"backfilled\":true,\"days\":[],\"version\":1}".utf8).write(to: lockedURL)
    try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedURL.path)
    let ls = StatsStore(url: lockedURL)
    ls.add(words: 5, seconds: 2, engine: "whisper", date: now, calendar: cal)
    let lsReset = ls.reset()
    let lsBackfill = ls.backfillIfNeeded(h.all(), calendar: cal)
    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockedURL.path)
    check("stats.unreadableNotWritten", !ls.writable && !lsReset && (try? String(contentsOf: lockedURL, encoding: .utf8)) == "{\"backfilled\":true,\"days\":[],\"version\":1}")
    check("stats.unreadableBackfillNotSaved", !lsBackfill)
    // A backfill that can't be saved stays in memory and lands with the next count; reopened, nothing is counted twice.
    let ro = dir.appendingPathComponent("readonly"); try? FileManager.default.createDirectory(at: ro, withIntermediateDirectories: true)
    let roURL = ro.appendingPathComponent("stats.json")
    let roHistory = [Entry(date: yesterday, raw: "one two three", seconds: 2, app: "Notes", inserted: true)]
    try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: ro.path)
    let rs = StatsStore(url: roURL)
    let roSaved = rs.backfillIfNeeded(roHistory, calendar: cal)
    try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: ro.path)
    check("stats.backfillUnsaved", !roSaved && !FileManager.default.fileExists(atPath: roURL.path) && Stats.score(rs.days).words == 3)
    rs.add(words: 4, seconds: 2, engine: "whisper", date: now, calendar: cal)
    let roReopened = StatsStore(url: roURL)
    check("stats.backfillLandsWithNextCount", roReopened.backfilled && Stats.score(roReopened.days).words == 7 && !roReopened.backfillIfNeeded(roHistory, calendar: cal) && Stats.score(roReopened.days).words == 7)
    // Not loaded yet: writes nothing until read.
    let deferredURL = dir.appendingPathComponent("deferred.json")
    let deferred = StatsStore(url: deferredURL, load: false)
    deferred.add(words: 3, seconds: 1, engine: "whisper", date: now, calendar: cal)
    check("stats.deferredWritesNothing", !FileManager.default.fileExists(atPath: deferredURL.path))
    try? FileManager.default.removeItem(at: dir)
}

// Words worth a second look, where the engines disagree (D-817 test).
let rk = RiskyWords.find(final: "So we should not ship it on Friday with three fixes", other: "So we should now ship it on Friday with free fixes", names: [])
check("risky.negationFirst", rk.first?.kind == "negation" && rk.first?.heard == "not" && rk.first?.other == "now", "\(rk)")
check("risky.number", rk.contains { $0.kind == "number" && $0.heard == "three" })
check("risky.swap", rk.first?.swapped == "So we should now ship it on Friday with three fixes")
check("risky.ordinaryIgnored", RiskyWords.find(final: "Tell the team that the build is green and ready today", other: "Tell the team that a build is green and ready today", names: []).isEmpty)
check("risky.name", RiskyWords.find(final: "Ask so well about the plan for next week", other: "Ask Sowell about the plan for next week", names: ["Sowell"]).first?.kind == "name")
check("risky.edge", RiskyWords.find(final: "Hey team the plan is set", other: "Hi team the plan is set", names: []).first?.kind == "edge")
check("risky.caseOnly", RiskyWords.find(final: "Ship it today.", other: "ship it today", names: []).isEmpty)

// Fun facts use the all-time word count and exact stored daily totals, with at most two approximate book lines.
check("facts.zero", StatsFunFacts.bookLines(words: 0).isEmpty && StatsFunFacts.lines([]).isEmpty)
check("facts.real39712", StatsFunFacts.bookLines(words: 39_712) == [
    "You've spoken about 1.2 times as many words as The Call of the Wild.",
    "You've spoken about 80% of the words in The Great Gatsby."
])
check("facts.booksChangeWithTotal", StatsFunFacts.bookLines(words: 80_000).first?.contains("Frankenstein") == true)
check("facts.verySmallNoZeroPercent", StatsFunFacts.bookLines(words: 1) == ["Your 1 word is less than about 1% of A Christmas Carol."])
check("facts.belowFirstOne", StatsFunFacts.bookLines(words: 10_000).count == 1)
check("facts.exactBookAbout", StatsFunFacts.bookLines(words: 563_500) == ["You've spoken about as many words as War and Peace."])
check("facts.aboveLastOne", StatsFunFacts.bookLines(words: 1_127_000) == ["You've spoken about 2 times as many words as War and Peace."])
check("facts.alwaysApproximate", [1, 10_000, 39_712, 80_000, 600_000].flatMap { StatsFunFacts.bookLines(words: $0) }.allSatisfy { $0.contains("about") })
check("facts.seconds", StatsFunFacts.talkingTime(59.9) == "less than a minute")
check("facts.singularMinute", StatsFunFacts.talkingTime(60) == "1 minute")
check("facts.singularHour", StatsFunFacts.talkingTime(3600) == "1 hour")
check("facts.hoursAndMinutes", StatsFunFacts.talkingTime(13_020) == "3 hours 37 minutes")
let factDays = [DayStats(day: "2026-10-24", engine: "whisper", words: 4_000, seconds: 6_000, dictations: 20),
                DayStats(day: "2026-10-24", engine: "live", words: 3_515, seconds: 3_000, dictations: 10),
                DayStats(day: "2026-10-25", engine: "whisper", words: 7_000, seconds: 4_020, dictations: 30)]
let personalFacts = StatsFunFacts.lines(factDays)
check("facts.enginesCombineForLongestDay", personalFacts.contains { $0.hasPrefix("Your longest day was 7,515 words on ") && $0.contains("2026") })
check("facts.totalTalkingTime", personalFacts.last == "You've talked for 3 hours 37 minutes in total.")
check("facts.smallSection", personalFacts.count <= 4)

// Bar placement uses desktop coordinates, including a portrait display and displays above/left of primary.
do {
    let screens = [CGRect(x: 0, y: 0, width: 3440, height: 1440),
                   CGRect(x: -3440, y: 0, width: 3440, height: 1440),
                   CGRect(x: 3440, y: -560, width: 1440, height: 2560)]
    let box = CGRect(x: 3500, y: 200, width: 500, height: 100)
    let window = CGRect(x: -3000, y: 100, width: 1000, height: 900)
    func pick(_ text: CGRect?, _ win: CGRect?, _ pointer: CGPoint = .zero) -> BarScreen.Choice? {
        BarScreen.choose(screens: screens, textBox: text, window: win, pointer: pointer)
    }
    check("bar.textBoxBeatsWindowAndPointer", pick(box, window)?.index == 2 && pick(box, window)?.reason == "text box")
    check("bar.windowFallback", pick(nil, window)?.index == 1 && pick(nil, window)?.reason == "focused window")
    check("bar.pointerFallback", pick(nil, nil, CGPoint(x: 4000, y: -200))?.index == 2)
    check("bar.offscreenBoxFallsBack", pick(CGRect(x: 9000, y: 0, width: 10, height: 10), window)?.index == 1)
    check("bar.zeroBoxFallsBack", pick(.zero, window)?.index == 1)
    check("bar.spanningWindowLargestArea", pick(nil, CGRect(x: 3000, y: 0, width: 1800, height: 1000))?.index == 2)
    check("bar.offscreenPointerFallback", pick(nil, nil, CGPoint(x: 20000, y: 20000))?.index == 0)
    check("bar.noScreens", BarScreen.choose(screens: [], textBox: box, window: window, pointer: .zero) == nil)
    let ax = CGRect(x: 3500, y: -200, width: 500, height: 100)
    check("bar.accessibilityCoordinates", BarScreen.fromAccessibility(ax, primaryTop: 1440) == CGRect(x: 3500, y: 1540, width: 500, height: 100))
    check("bar.abovePrimary", BarScreen.choose(screens: screens + [CGRect(x: 0, y: 1440, width: 3440, height: 1440)],
          textBox: BarScreen.fromAccessibility(CGRect(x: 10, y: -200, width: 100, height: 100), primaryTop: 1440), window: nil, pointer: .zero)?.index == 3)
}

// Word suggestions never retain dictation sentences, and only offer recurring unlisted names after talking.
do {
    let empty = Names(text: "")
    check("suggest.capitalName", WordSuggestions.words(in: "Ask Breanna about it.", names: empty) == ["Breanna"])
    check("suggest.commonEnglish", WordSuggestions.words(in: "Use The Other Good Words on Monday in October.", names: empty).isEmpty)
    check("suggest.sentenceStart", WordSuggestions.words(in: "Breanna is here. Breanna left! Breanna came? Breanna knows.", names: empty).isEmpty)
    check("suggest.quotedSentenceStart", WordSuggestions.words(in: "\"Breanna is here.\" “Breanna left.”", names: empty).isEmpty)
    check("suggest.newlineStart", WordSuggestions.words(in: "Ask now\nBreanna left.", names: empty).isEmpty)
    check("suggest.quotedName", WordSuggestions.words(in: "Ask “Breanna.”", names: empty) == ["Breanna"])
    check("suggest.listedBothSidesAndPhrases", WordSuggestions.words(in: "Ask Breanna about Acme then Claw or Claude Code.", names: Names(text: "Breanna\nClaw = Claude Code\nAcme")).isEmpty)
    check("suggest.listedCaseInsensitive", WordSuggestions.words(in: "Ask BREANNA.", names: Names(text: "breanna")).isEmpty)
    check("suggest.lowercaseSkipped", WordSuggestions.words(in: "Ask breanna about it.", names: empty).isEmpty)
    check("suggest.lowConfidenceWhenSupplied", WordSuggestions.words(in: "Ask breanna about it.", names: empty, lowConfidence: ["breanna"]) == ["breanna"])
    check("suggest.lowConfidenceCommonStillSkipped", WordSuggestions.words(in: "Ask the other person.", names: empty, lowConfidence: ["the", "other"]).isEmpty)
    check("suggest.possessive", WordSuggestions.words(in: "Ask Breanna’s friend.", names: empty) == ["Breanna"])
    check("suggest.unicodeAndHyphen", WordSuggestions.words(in: "Ask Élodie and Jean-Luc.", names: empty) == ["Élodie", "Jean-Luc"])
    check("suggest.oneSightingPerDictation", WordSuggestions.words(in: "Ask Breanna and BREANNA then Breanna.", names: empty) == ["Breanna"])
    check("suggest.lengthGuards", WordSuggestions.words(in: "Ask AB and " + String(repeating: "X", count: 41), names: empty).isEmpty)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rv-suggestions-\(UUID().uuidString)")
    let url = dir.appendingPathComponent("counts.json")
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let day1 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12))!
    let day2 = day1.addingTimeInterval(86400), day3 = day2.addingTimeInterval(86400)
    let store = WordSuggestions(url: url)
    store.observe("Ask Breanna and Breanna.", names: empty, date: day1, calendar: calendar)
    check("suggest.oneCount", store.candidates.first?.count == 1)
    check("suggest.belowThreshold", store.next(names: empty, date: day2, calendar: calendar) == nil)
    store.observe("Ask Breanna.", names: empty, date: day1, calendar: calendar)
    store.observe("Ask Breanna.", names: empty, date: day1, calendar: calendar)
    check("suggest.threeSameDayWait", store.candidates.first?.count == 3 && store.next(names: empty, date: day1, calendar: calendar) == nil)
    store.observe("Ask Breanna.", names: empty, date: day2, calendar: calendar)
    check("suggest.threeAndTwoDays", store.next(names: empty, date: day2, calendar: calendar) == "Breanna")
    check("suggest.newlyListedSkippedAtOffer", store.next(names: Names(text: "Breanna"), date: day2, calendar: calendar) == nil)
    store.offered(date: day2, calendar: calendar)
    check("suggest.onceADay", store.next(names: empty, date: day2, calendar: calendar) == nil)
    let reloaded = WordSuggestions(url: url)
    check("suggest.onceADaySurvivesRestart", reloaded.next(names: empty, date: day2, calendar: calendar) == nil)
    check("suggest.nextDayAfterTimeout", reloaded.next(names: empty, date: day3, calendar: calendar) == "Breanna")
    reloaded.dismiss("BREANNA")
    reloaded.observe("Ask Breanna.", names: empty, date: day3, calendar: calendar)
    check("suggest.dismissForever", WordSuggestions(url: url).next(names: empty, date: day3, calendar: calendar) == nil && reloaded.candidates.isEmpty)
    let json = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    check("suggest.noSentencesOrDismissedWord", !json.contains("Ask") && !json.contains("Breanna") && !json.contains("BREANNA"))
    let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int
    check("suggest.privateFile", permissions == 0o600)
    reloaded.observe("Ask Zephyra.", names: empty, enabled: false, date: day3, calendar: calendar)
    check("suggest.disabledDoesNotCount", reloaded.candidates.isEmpty)
    reloaded.clear()
    reloaded.observe("Ask Zephyra.", names: empty, date: day1, calendar: calendar)
    reloaded.observe("Ask Zephyra.", names: empty, date: day2, calendar: calendar)
    check("suggest.twoSightingsTwoDaysWait", reloaded.next(names: empty, date: day2, calendar: calendar) == nil)
    reloaded.observe("Ask Zephyra.", names: empty, date: day2, calendar: calendar)
    check("suggest.exactThreshold", reloaded.next(names: empty, date: day2, calendar: calendar) == "Zephyra")
    reloaded.offered(date: day2, calendar: calendar)
    check("suggest.dailyLimitAcrossWords", reloaded.next(names: empty, date: day2, calendar: calendar) == nil)
    reloaded.observe("Ask Zephyra.", names: Names(text: "Zephyra"), date: day3, calendar: calendar)
    check("suggest.addedNamesPruned", reloaded.candidates.isEmpty)
    reloaded.observe("Ask Breanna.", names: empty, keep: "none", date: day3, calendar: calendar)
    check("suggest.keepNothingWipesFile", reloaded.candidates.isEmpty && !FileManager.default.fileExists(atPath: url.path))
    reloaded.observe("Ask Breanna.", names: empty, keep: "none", date: day3, calendar: calendar)
    check("suggest.keepNothingDoesNotRecreate", !FileManager.default.fileExists(atPath: url.path))
    // Keep the candidate table bounded even with many unique names.
    for i in 0..<270 {
        let suffix = String(UnicodeScalar(65 + i / 26)!) + String(UnicodeScalar(65 + i % 26)!)
        reloaded.observe("Ask Zephyra" + suffix, names: empty, date: day3, calendar: calendar)
    }
    check("suggest.boundedCounts", reloaded.candidates.count == WordSuggestions.cap)
    reloaded.clear()
    check("suggest.explicitClear", reloaded.candidates.isEmpty && !FileManager.default.fileExists(atPath: url.path))
    try? FileManager.default.removeItem(at: dir)
}

print("\(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
