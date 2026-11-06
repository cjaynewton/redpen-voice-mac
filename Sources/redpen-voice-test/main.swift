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

// Chrome pause: only what plays out loud, marked, and only those come back; Chrome's answers read right.
let bmTok = BrowserMedia.token()
check("browser.token", !bmTok.isEmpty && bmTok.allSatisfy { $0.isLetter || $0.isNumber })
check("browser.pause.loud", BrowserMedia.pauseScript(token: "abc").contains("!m.paused&&!m.ended&&!m.muted&&m.volume>0"))
check("browser.pause.mark", BrowserMedia.pauseScript(token: "abc").contains("setAttribute('data-redpen-paused','abc')"))
check("browser.resume.ours", BrowserMedia.resumeScript(token: "abc").contains("[data-redpen-paused=\"abc\"]"))
check("browser.token.clean", !BrowserMedia.pauseScript(token: "a'b);x(").contains("'b);"))
check("browser.chrome", BrowserMedia.isChrome(path: "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/142/Helpers/Google Chrome Helper (Aperitif).app/Contents/MacOS/Google Chrome Helper (Aperitif)"))
check("browser.notchrome", !BrowserMedia.isChrome(path: "/System/Applications/Music.app/Contents/MacOS/Music"))
check("browser.handled", BrowserMedia.outcome(status: 0, output: "1234:1,5678:2\n", error: "") == .handled(tabs: [1234, 5678], count: 3))
check("browser.none", BrowserMedia.outcome(status: 0, output: "\n", error: "") == .nothingFound)
check("browser.zero", BrowserMedia.outcome(status: 0, output: "1234:0", error: "") == .nothingFound)
check("browser.slow", BrowserMedia.outcome(status: 0, output: "slow", error: "") == .failed("slow"))
check("browser.refused", BrowserMedia.outcome(status: 0, output: "refused", error: "") == .scriptsOff)
check("browser.refused.found", BrowserMedia.outcome(status: 0, output: "1234:1", error: "") == .handled(tabs: [1234], count: 1))
check("browser.runner.skips", BrowserMedia.pauseRunner.contains("set refused to true") && !BrowserMedia.pauseRunner.contains("or msg contains \"turned off\" then error"))
check("browser.slow.found", BrowserMedia.outcome(status: 0, output: "1234:1,slow", error: "") == .handled(tabs: [1234], count: 1))
check("browser.runner.sites", BrowserMedia.pauseRunner.contains("\"primevideo.\"") && BrowserMedia.pauseRunner.contains("with timeout of 1 second"))
check("browser.off", BrowserMedia.outcome(status: 1, output: "", error: "execution error: Google Chrome got an error: Executing JavaScript through AppleScript is turned off. To turn it on, from the menu bar, go to View > Developer > Allow JavaScript from Apple Events. (12)") == .scriptsOff)
check("browser.denied", BrowserMedia.outcome(status: 1, output: "", error: "execution error: Not authorized to send Apple events to Google Chrome. (-1743)") == .notAllowed)
if case .failed = BrowserMedia.outcome(status: 1, output: "", error: "execution error: something else (-1728)") { check("browser.failed", true) } else { check("browser.failed", false) }
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

// Where a finished dictation goes (D-965): the box you are in at the end. The first box is swapped in place, emptied
// of Voice's words, or left alone. No AX edits, keys or windows: the planner and the box checks only.
do {
    typealias P = DictationEnding.Plan
    check("ending.stillThereAsLeft", DictationEnding.plan(typedInStartBox: true, startBoxAsLeft: true, inStartBox: true) == P.inPlace)
    check("ending.movedAwayAsLeft", DictationEnding.plan(typedInStartBox: true, startBoxAsLeft: true, inStartBox: false) == P.takeBackThenDeliver)
    // D-998: words already in a box you sent, edited or left for another conversation are never typed again anywhere.
    check("ending.movedAwayEditedKeeps", DictationEnding.plan(typedInStartBox: true, startBoxAsLeft: false, inStartBox: false) == P.keep)
    check("ending.stillThereEditedOrSentKeeps", DictationEnding.plan(typedInStartBox: true, startBoxAsLeft: false, inStartBox: true) == P.keep)
    check("ending.sentBoxEmpty", DictationEnding.looksSent(""))
    check("ending.sentBoxStrayCharacter", DictationEnding.looksSent("\n"))
    check("ending.sentBoxOneLetter", DictationEnding.looksSent(" x "))
    check("ending.editedBoxNotSent", !DictationEnding.looksSent("so the plan is to"))
    check("ending.unreadableBoxNotSent", !DictationEnding.looksSent(nil))
    // The bar after a kept ending: quiet when the sent message had every word, a pointer to ⌃⌥V when it didn't.
    check("ending.sentWholeQuiet", DictationEnding.keptNote(sent: true, typed: "Words the drafts typed so far", checked: "Words the drafts typed, so far.") == nil)
    check("ending.sentShortSaysSo", DictationEnding.keptNote(sent: true, typed: "Words the drafts typed so far", checked: "Words the drafts typed so far, and the last word.") == DictationEnding.sentShortNote)
    check("ending.changedPointsToPaste", DictationEnding.keptNote(sent: false, typed: "a b", checked: "a b") == DictationEnding.changedNote)
    check("ending.droppedRepeatCantHideLastWord", DictationEnding.keptNote(sent: true, typed: "I I think we should", checked: "I think we should go.") == DictationEnding.sentShortNote)
    check("ending.numberFormatCantHideLastWord", DictationEnding.keptNote(sent: true, typed: "about twenty five", checked: "About 25 people.") == DictationEnding.sentShortNote)
    check("ending.sentNothingTypedSaysSo", DictationEnding.keptNote(sent: true, typed: "", checked: "All of it.") == DictationEnding.sentShortNote)
    check("ending.keptNotesShort", DictationEnding.sentShortNote.count <= 48 && DictationEnding.changedNote.count <= 48
          && DictationEnding.unconfirmedNote.count <= 48)
    // Oct 31 07:54: Voice's own swap came out one character off, nothing of yours touched the box, the bar said ⌃⌥V,
    // and ⌃⌥V pasted the dictation a second time. Voice's own doubt never points at ⌃⌥V.
    check("ending.voiceUnsureNoPastePrompt", DictationEnding.keptNote(sent: false, voiceUnsure: true, typed: "a b", checked: "a b c") == DictationEnding.unconfirmedNote)
    check("ending.sentBeatsVoiceUnsure", DictationEnding.keptNote(sent: true, voiceUnsure: true, typed: "a b", checked: "a b c") == DictationEnding.sentShortNote)
    for asLeft in [true, false] {
        for here in [true, false] {
            check("ending.nothingTypedGoesWhereYouAre.\(asLeft).\(here)", DictationEnding.plan(typedInStartBox: false, startBoxAsLeft: asLeft, inStartBox: here) == P.deliver)
        }
    }

    // Oct 31 03:47 log: drafts 90 UTF-16 units, the box sent (1 left) by your key before the ending was ready.
    var sentBox = BoxPrint(role: "AXTextArea", identifier: "composer", frame: f0, text: "", title: "Thread", url: "t3://thread-1")
    sentBox.recordEdit(before: "", range: NSRange(location: 0, length: 0), replacement: "Words the drafts typed so far")
    let sentNow = BoxMatch.same(start: sentBox, now: t3Grew, nowText: "\n", sameElement: true, userEdited: true)
    check("ending.sentBoxNotAsLeft", !sentNow)
    check("ending.sentBoxNotTypedAgainHere", DictationEnding.plan(typedInStartBox: true, startBoxAsLeft: sentNow, inStartBox: true) == P.keep)
    // Oct 31 2026, reported: you sent in one T3 chat and clicked into another before the checked text came. It went into the
    // second chat as well. Sent, then somewhere else: kept, never typed there.
    check("ending.sentThenOtherChatKeeps", DictationEnding.plan(typedInStartBox: true, startBoxAsLeft: sentNow, inStartBox: false) == P.keep)
    check("ending.otherChatNeverTypedAgain", DictationEnding.plan(typedInStartBox: true,
          startBoxAsLeft: BoxMatch.same(start: sentBox, now: anotherThread, nowText: "", sameElement: true), inStartBox: false) == P.keep)
    // A key or click earlier that didn't change the box: still as Voice left it, so the ending swaps in place.
    let untouched = BoxMatch.same(start: sentBox, now: t3Grew, nowText: "Words the drafts typed so far", sameElement: true)
    check("ending.keyThatChangedNothingStillSwaps", untouched && DictationEnding.plan(typedInStartBox: true, startBoxAsLeft: untouched, inStartBox: true) == P.inPlace)
    let swap = DraftReplacement(expectedBox: "Words the drafts typed so far", actual: "Words the drafts typed so far",
                                cursor: NSRange(location: 29, length: 0), draft: "Words the drafts typed so far",
                                replacement: "Words the drafts typed so far, and the last word.")
    check("ending.swapKeepsTheLastWord", swap?.expected == "Words the drafts typed so far, and the last word.")
    // You clicked into the box elsewhere: the cursor no longer follows the drafts, so nothing is swapped blindly.
    check("ending.cursorMovedNoSwap", DraftReplacement(expectedBox: "Words the drafts typed so far", actual: "Words the drafts typed so far",
                                                        cursor: NSRange(location: 5, length: 0), draft: "Words the drafts typed so far", replacement: "x") == nil)
    // An edit in another conversation of the same app is not the first box.
    check("ending.otherConversationNotAsLeft", !BoxMatch.same(start: sentBox, now: anotherThread, nowText: "Words the drafts typed so far", sameElement: true))

    // Taking Voice's words back out of the first box: only its own words before the cursor, never yours before them.
    let back = DraftReplacement(expectedBox: "Mine stays. one two three", actual: "Mine stays. one two three",
                                cursor: NSRange(location: 25, length: 0), draft: " one two three", replacement: "")
    check("ending.takeBackLeavesYourText", back?.expected == "Mine stays." && back?.range == NSRange(location: 11, length: 14))
    check("ending.takeBackNeedsEvidence", back?.landed("Mine stays. one two three") == false && back?.landed("Mine stays.") == true)
    let trimmedBack = DraftReplacement(expectedBox: "Mine stays. one two three ", actual: "Mine stays. one two three",
                                       cursor: NSRange(location: 25, length: 0), draft: " one two three ", replacement: "")
    check("ending.takeBackAfterTrim", trimmedBack?.expected == "Mine stays.")
    check("ending.takeBackRefusesYourEdit", DraftReplacement(expectedBox: "Mine stays. one two three", actual: "Mine stays. one two three four",
                                                              cursor: NSRange(location: 30, length: 0), draft: " one two three", replacement: "") == nil)
    var taken = BoxPrint(role: "AXTextArea", identifier: nil, frame: f0, text: "Mine stays. one two three")
    check("ending.takeBackRecorded", taken.recordEdit(before: "Mine stays. one two three", range: NSRange(location: 11, length: 14), replacement: "") && taken.text == "Mine stays.")

    // Enter stops and sends (D-1008): which presses Voice holds, and exactly one Enter out for each.
    do {
        typealias E = EnterSend
        check("enter.plainReturn", E.owns(keyCode: 36, flags: 0))
        check("enter.keypadEnter", E.owns(keyCode: 76, flags: 0))
        check("enter.fnReturnCounts", E.owns(keyCode: 36, flags: 0x800000))
        check("enter.shiftLeftAlone", !E.owns(keyCode: 36, flags: E.shift))
        check("enter.commandLeftAlone", !E.owns(keyCode: 36, flags: E.command))
        check("enter.optionLeftAlone", !E.owns(keyCode: 36, flags: E.option))
        check("enter.controlLeftAlone", !E.owns(keyCode: 36, flags: E.control))
        check("enter.otherKeysNot", !E.owns(keyCode: 53, flags: 0) && !E.owns(keyCode: 0, flags: 0))
        // Right Option held to talk: Option+Enter is still your Enter. Left Option, or Option not a talk key: a shortcut.
        check("enter.rightOptionTalkKeyCounts", E.owns(keyCode: 36, flags: E.option | 0x40, talkKeys: E.option))
        check("enter.leftOptionStillShortcut", !E.owns(keyCode: 36, flags: E.option | 0x20, talkKeys: E.option))
        check("enter.rightOptionNotTalkKey", !E.owns(keyCode: 36, flags: E.option | 0x40))
        check("enter.rightOptionTalkShiftStillShortcut", !E.owns(keyCode: 36, flags: E.option | 0x40 | E.shift, talkKeys: E.option))

        var r = E()
        check("enter.notArmedPasses", r.keyDown(code: 36, flags: 0, own: false, repeated: false, now: 10) == .pass)
        check("enter.notArmedUpPasses", r.keyUp(code: 36, own: false) == .pass)
        r.arm(now: 10)
        check("enter.shiftArmedPasses", r.keyDown(code: 36, flags: E.shift, own: false, repeated: false, now: 10.1) == .pass)
        check("enter.ownArmedPasses", r.keyDown(code: 36, flags: 0, own: true, repeated: false, now: 10.1) == .pass)
        check("enter.armedHolds", r.keyDown(code: 36, flags: 0, own: false, repeated: false, now: 10.2) == .hold(id: 1))
        check("enter.repeatSwallowed", r.keyDown(code: 36, flags: 0, own: false, repeated: true, now: 10.3) == .swallow)
        check("enter.upSwallowed", r.keyUp(code: 36, own: false) == .swallow)
        check("enter.secondUpPasses", r.keyUp(code: 36, own: false) == .pass)
        check("enter.ownUpPasses", r.keyUp(code: 36, own: true) == .pass)
        check("enter.secondEnterSendsNow", r.keyDown(code: 36, flags: 0, own: false, repeated: false, now: 11) == .sendNow(id: 1))
        check("enter.secondEnterUpSwallowed", r.keyUp(code: 36, own: false) == .swallow)
        check("enter.releaseOnce", r.release(id: 1) == 36 && r.release(id: 1) == nil)
        check("enter.capAfterReleaseNothing", r.capReached(id: 1, now: 20) == nil)
        // A fresh press waits for its words, then the 5 s cap sends it if they never come.
        r.arm(now: 30)
        check("enter.nextPressNewID", r.keyDown(code: 76, flags: 0, own: false, repeated: false, now: 30.1) == .hold(id: 2))
        check("enter.capNotEarly", r.capReached(id: 2, now: 33) == nil)
        check("enter.capAtFiveSendsSameKey", r.capReached(id: 2, now: 35.1) == 76)
        check("enter.releaseAfterCapNothing", r.release(id: 2) == nil)
        // An ending arms for its whole length; a renewal never shortens it.
        r.arm(now: 60, for: E.endingArmLength); r.arm(now: 61)
        check("enter.endingArmNotShortened", r.armed(now: 70))
        r.disarm()
        // The arming runs out by itself, so a stalled Voice can't keep holding Enter.
        r.arm(now: 40)
        check("enter.armRunsOut", r.keyDown(code: 36, flags: 0, own: false, repeated: false, now: 40 + E.armLength + 0.01) == .pass)
        r.arm(now: 50); r.disarm()
        check("enter.disarmPasses", r.keyDown(code: 36, flags: 0, own: false, repeated: false, now: 50.1) == .pass)
        // The keyboard's own key counter still sees a held Enter. Counted like a talk key, it doesn't stop the ending.
        check("enter.heldEnterNotYourTyping", DraftSafety.hardwareFailure(since: 100, at: 103, keyDownAgo: 1, leftClickAgo: 99,
              rightClickAgo: 99, talkKeyDownTimes: [100.2, 102.01], typingKeyDownAt: nil) == nil)
        check("enter.realKeyStillCounts", DraftSafety.hardwareFailure(since: 100, at: 103, keyDownAgo: 0.5, leftClickAgo: 99,
              rightClickAgo: 99, talkKeyDownTimes: [100.2, 102.01], typingKeyDownAt: nil) == .hardwareKey)
        check("enter.capFive", E.cap == 5)
        check("enter.notesShort", E.waitingNote.count <= 40)
    }

    // Long talks land whole (D-1023): past 45 s nothing more is typed as you talk, the ending adds the rest with one
    // paste, and a held Enter waits up to a minute and is never sent with words missing.
    do {
        typealias E = EnterSend
        check("long.after45", !LongTalk.isLong(seconds: 44.9) && LongTalk.isLong(seconds: 45) && LongTalk.isLong(seconds: 1800))
        check("long.lengthSeconds", LongTalk.length(seconds: 50.4) == "50 seconds", LongTalk.length(seconds: 50.4))
        check("long.lengthOneMinute", LongTalk.length(seconds: 68) == "1 minute" && LongTalk.length(seconds: 89) == "1 minute")
        check("long.lengthMinutes", LongTalk.length(seconds: 184) == "3 minutes" && LongTalk.length(seconds: 1200) == "20 minutes")
        check("long.writingNote", LongTalk.writingNote(seconds: 184) == "Putting in your 3 minutes of talk")
        check("long.sendingNote", LongTalk.sendingNote(seconds: 184) == "Sends when your 3 minutes is in")
        let notes = [LongTalk.writingNote(seconds: 1800), LongTalk.sendingNote(seconds: 1800), LongTalk.notSent,
                     TalkingWords.stoppedLine(.longTalk, words: 4000)]
        check("long.notesShortAndPlain", notes.allSatisfy { $0.count <= 60 && !$0.contains(":") && !$0.contains("\u{2014}") }, notes.joined(separator: " | "))
        check("long.barLine", TalkingWords.stoppedLine(.longTalk, words: 120) == "Long talk. 120 words so far, all go in when you stop.")
        check("long.barLineNotAlarm", !TalkingWords.stoppedLine(.longTalk, words: 3).contains("stopped"))
        // The ending keeps the checked runs from the start and takes out only the rough words after them.
        let all = LongTalk.split([(" So the plan", true), (" is this.", true), (" and then", false), (" more", false)])
        check("long.splitKeepsChecked", all.keep == 2 && all.erase == " and then more", all.erase)
        let none = LongTalk.split([(" So the plan", true), (" is this.", true)])
        check("long.splitAllChecked", none.keep == 2 && none.erase.isEmpty)
        let rough = LongTalk.split([(" so the", false), (" plan", true)])
        check("long.splitStopsAtFirstRough", rough.keep == 0 && rough.erase == " so the plan")
        check("long.splitEmpty", LongTalk.split([]).keep == 0 && LongTalk.split([]).erase.isEmpty)

        // Enter on a long talk: past the 5 s cap and the backstop it still waits; at a minute it is dropped, never sent.
        var r = E()
        r.arm(now: 100)
        check("long.enterHolds", r.keyDown(code: 36, flags: 0, own: false, repeated: false, now: 100.1) == .hold(id: 1))
        check("long.enterWaitLonger", r.waitLonger(id: 1, now: 100.2))
        check("long.enterCapDoesNotSend", r.capReached(id: 1, now: 105.2) == nil && r.capReached(id: 1, now: 116) == nil)
        check("long.enterNotDroppedEarly", !r.dropAtDeadline(id: 1, now: 130))
        check("long.enterCapNeverSendsLong", r.capReached(id: 1, now: 200) == nil)
        check("long.enterDroppedAtMinute", r.dropAtDeadline(id: 1, now: 160.3))
        check("long.enterDroppedOnce", !r.dropAtDeadline(id: 1, now: 170) && r.release(id: 1) == nil && !r.drop(id: 1))
        check("long.enterUpStillSwallowed", r.keyUp(code: 36, own: false) == .swallow)
        // Words not all in: dropped at once. Words in: sent as usual.
        r.arm(now: 300)
        check("long.enterSecondPress", r.keyDown(code: 36, flags: 0, own: false, repeated: false, now: 300.1) == .hold(id: 2))
        check("long.enterWaitLongerSecond", r.waitLonger(id: 2, now: 300.1))
        check("long.enterDropNow", r.drop(id: 2) && r.release(id: 2) == nil)
        _ = r.keyUp(code: 36, own: false)
        r.arm(now: 400)
        check("long.enterThird", r.keyDown(code: 36, flags: 0, own: false, repeated: false, now: 400.1) == .hold(id: 3) && r.waitLonger(id: 3, now: 400.1))
        // A second Enter from you still sends straight away: your call, not Voice's.
        check("long.enterYourSecondEnterSends", r.keyDown(code: 36, flags: 0, own: false, repeated: false, now: 401) == .sendNow(id: 3))
        check("long.enterReleaseSends", r.release(id: 3) == 36 && !r.dropAtDeadline(id: 3, now: 500))
        check("long.waitLongerOnlyWaiting", !r.waitLonger(id: 3, now: 402) && !r.waitLonger(id: 9, now: 402))
        // A short dictation is untouched: the 5 s cap still sends.
        _ = r.keyUp(code: 36, own: false); _ = r.keyUp(code: 36, own: false)
        r.arm(now: 600)
        check("long.shortStillCaps", r.keyDown(code: 36, flags: 0, own: false, repeated: false, now: 600.1) == .hold(id: 4)
              && !r.dropAtDeadline(id: 4, now: 700) && r.capReached(id: 4, now: 605.2) == 36)

        // The one paste confirms as typing does, allowing for the box's own spacing; Paste last stays exact.
        let loose = PasteEvidence(before: "Plan. Fix", range: NSRange(location: 9, length: 0), text: " the bar  now.", loose: true)
        check("long.pasteLooseConfirms", loose.landed(value: "Plan. Fix the bar now.", range: NSRange(location: 22, length: 0)))
        check("long.pasteLooseNeedsWords", !loose.landed(value: "Plan. Fix the bar", range: NSRange(location: 17, length: 0)))
        check("long.pasteLooseNotUnchanged", !loose.landed(value: "Plan. Fix", range: NSRange(location: 9, length: 0)))
        let exact = PasteEvidence(before: "Plan. Fix", range: NSRange(location: 9, length: 0), text: " the bar  now.")
        check("long.pasteExactStaysExact", !exact.landed(value: "Plan. Fix the bar now.", range: NSRange(location: 99, length: 0)))
    }

    // Straight after: any place but a page, a control or Voice's own window takes the words; otherwise they wait.
    check("ending.textTypesNow", DictationEnding.typesNow(kind: .text, ownWindow: false))
    check("ending.unknownNativeTypesNow", DictationEnding.typesNow(kind: .unknown, ownWindow: false))
    check("ending.pageWaits", !DictationEnding.typesNow(kind: .notText, ownWindow: false))
    check("ending.ownWindowWaits", !DictationEnding.typesNow(kind: .text, ownWindow: true))
    // Waiting: 10 minutes, the same safeties as before.
    check("ending.waitTenMinutes", DictationEnding.waitSeconds == 600)
    check("ending.waitRefusesOwnWindow", DictationEnding.waitRefuses(kind: .text, inBrowser: false, ownWindow: true))
    check("ending.waitRefusesPage", DictationEnding.waitRefuses(kind: .notText, inBrowser: true, ownWindow: false))
    check("ending.waitRefusesControl", DictationEnding.waitRefuses(kind: .notText, inBrowser: false, ownWindow: false))
    check("ending.waitRefusesUnknownInBrowser", DictationEnding.waitRefuses(kind: .unknown, inBrowser: true, ownWindow: false))
    check("ending.waitAllowsBrowserTextBox", !DictationEnding.waitRefuses(kind: .text, inBrowser: true, ownWindow: false))
    check("ending.waitAllowsElectronBox", !DictationEnding.waitRefuses(kind: .unknown, inBrowser: false, ownWindow: false))
    check("ending.textBoxTakesAtOnce", DictationEnding.waitTakes(kind: .text, seenInARow: 1))
    check("ending.unknownBoxSeenOnceWaits", !DictationEnding.waitTakes(kind: .unknown, seenInARow: 1))
    check("ending.unknownBoxSeenTwiceTakes", DictationEnding.waitTakes(kind: .unknown, seenInARow: 2))
    // A video page in Chrome (the web area) never takes waiting words, so a click on the video does nothing.
    check("ending.videoPageNeverTakes", DictationEnding.waitRefuses(kind: fk("AXWebArea", web: true), inBrowser: true, ownWindow: false))
    check("ending.browserTextFieldTakes", !DictationEnding.waitRefuses(kind: fk("AXTextField", web: true), inBrowser: true, ownWindow: false)
          && DictationEnding.waitTakes(kind: fk("AXTextField", web: true), seenInARow: 1))
}

// While you talk (D-972): typed into the box, or on the bar and in once at the end. No windows, keys or AX edits:
// the choice, the bar's words and lines, and where the bar sits.
do {
    // Older config files keep what they did. His own (Oct 31): draftMode true, liveWords missing.
    check("talking.hisConfigTypesIntoBox", TalkingWords.choice(saved: nil, liveWords: nil, draftMode: true) == .box)
    check("talking.missingIsBox", TalkingWords.choice(saved: nil, liveWords: nil, draftMode: nil) == .box)
    check("talking.liveWordsOnIsBox", TalkingWords.choice(saved: nil, liveWords: true, draftMode: false) == .box)
    check("talking.liveWordsOffIsBar", TalkingWords.choice(saved: nil, liveWords: false, draftMode: nil) == .bar)
    check("talking.draftsTypedEvenWithLiveWordsOff", TalkingWords.choice(saved: nil, liveWords: false, draftMode: true) == .box)
    check("talking.savedBarWins", TalkingWords.choice(saved: "bar", liveWords: true, draftMode: true) == .bar)
    check("talking.savedBoxWins", TalkingWords.choice(saved: "box", liveWords: false, draftMode: false) == .box)
    check("talking.unknownSavedFallsBack", TalkingWords.choice(saved: "sideways", liveWords: false, draftMode: nil) == .bar)

    // The newest words that fit, from a whole word, one line.
    check("talking.tailShortUnchanged", TalkingWords.tail("so the plan is") == "so the plan is")
    let long = "so the plan for today is to finish the voice app and then write the essay about the shelf before lunch"
    let t = TalkingWords.tail(long)
    check("talking.tailFits", t.count <= 56, "\(t.count)")
    check("talking.tailShowsNewest", t.hasPrefix("…") && t.hasSuffix("about the shelf before lunch"), t)
    let firstWord = t.dropFirst().split(separator: " ").first.map(String.init) ?? ""
    check("talking.tailStartsAtWholeWord", long.split(separator: " ").map(String.init).contains(firstWord), firstWord)
    check("talking.tailOneLine", !TalkingWords.tail(long.replacingOccurrences(of: " the ", with: "\nthe ")).contains("\n"))
    check("talking.tailAtSpaceKeepsWord", TalkingWords.tail("aaaa bbbb cccc", limit: 10) == "…bbbb cccc")
    check("talking.tailOneLongWord", TalkingWords.tail(String(repeating: "x", count: 80), limit: 10) == "…" + String(repeating: "x", count: 9))
    check("talking.words", TalkingWords.words("  one two\nthree  ") == 3 && TalkingWords.words("") == 0)

    // Why typing stopped, in plain words, and what happens next. Never the clipboard since D-965.
    check("talking.stopKey", TalkingWords.Stop(.hardwareKey) == .typed)
    check("talking.stopClick", TalkingWords.Stop(.hardwareClick) == .clicked)
    check("talking.stopLeftApp", TalkingWords.Stop(.appChanged) == .leftBox && TalkingWords.Stop(.elementChanged) == .leftBox)
    check("talking.stopBoxChanged", TalkingWords.Stop(.boxCheck) == .boxChanged)
    check("talking.stopUnchecked", TalkingWords.Stop(.editUnconfirmed) == .unchecked && TalkingWords.Stop(.deliveryUncertain) == .unchecked)
    let stopped = TalkingWords.stoppedLine(.clicked, words: 120)
    check("talking.stoppedLine", stopped == "Typing stopped (you clicked). 120 words so far, all go in at the end.", stopped)
    check("talking.stoppedOneWord", TalkingWords.stoppedLine(nil, words: 1) == "Typing stopped. 1 word so far, all go in at the end.")
    check("talking.stoppedNoWordsYet", TalkingWords.stoppedLine(.noBox, words: 0) == "Typing stopped (not in a text box). Your words go in at the end.")
    check("talking.stoppedCountMoves", TalkingWords.stoppedLine(.typed, words: 57) != TalkingWords.stoppedLine(.typed, words: 58))
    check("talking.typingHandsFree", TalkingWords.typingLine(words: 57, handsFree: true, key: "Fn") == "Hands-free · 57 words · tap Fn to stop")
    check("talking.typingHeld", TalkingWords.typingLine(words: 1, handsFree: false, key: "Fn") == "1 word")
    let lines = [stopped, TalkingWords.writingAfterStop, TalkingWords.stoppedLine(.unchecked, words: 3), TalkingWords.stoppedLine(.leftBox, words: 0)]
        + [TalkingWords.Stop.typed, .clicked, .typedOrClicked, .leftBox, .boxChanged, .noBox, .unchecked, .longTalk].map(\.phrase)
    check("talking.plainLines", lines.allSatisfy { !$0.contains("\u{2014}") && !$0.contains(":") && !$0.lowercased().contains("clipboard") })

    // The bar's words: drafts in order, Whisper's check takes their place.
    var bar = BarWords()
    bar.draft(0, "so the plan"); bar.draft(1, " is to fix "); bar.draft(2, "the bar")
    check("talking.barDrafts", bar.text == "so the plan is to fix the bar" && bar.words == 8, bar.text)
    bar.check(0..<2, "So the plan is to fix")
    check("talking.barCheckReplaces", bar.text == "So the plan is to fix the bar", bar.text)
    bar.draft(4, "later")
    check("talking.barGapStaysEmpty", bar.text == "So the plan is to fix the bar later", bar.text)
    bar.check(2..<5, "")
    check("talking.barEmptyCheckRemoves", bar.text == "So the plan is to fix", bar.text)
    bar.check(-1..<1, "never")
    check("talking.barBadRangeIgnored", bar.text == "So the plan is to fix")

    // The bar never sits on the box you started in (AppKit coordinates, 40 high, 120 up from the bottom as before).
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 944), size = CGSize(width: 400, height: 40)
    check("bar.usualPlace", BarScreen.origin(visible: screen, size: size, avoiding: nil) == CGPoint(x: 556, y: 120))
    check("bar.boxElsewhereUsual", BarScreen.origin(visible: screen, size: size, avoiding: CGRect(x: 300, y: 600, width: 800, height: 60)) == CGPoint(x: 556, y: 120))
    // A chat composer low on the screen (T3, ChatGPT): the bar goes just above it.
    check("bar.aboveComposer", BarScreen.origin(visible: screen, size: size, avoiding: CGRect(x: 300, y: 80, width: 900, height: 90)) == CGPoint(x: 556, y: 182))
    // A box reaching the top: just below it instead.
    check("bar.belowTallBox", BarScreen.origin(visible: screen, size: size, avoiding: CGRect(x: 300, y: 150, width: 900, height: 780)) == CGPoint(x: 556, y: 98))
    // A box filling the screen (a document): nowhere is clear, so the usual place.
    check("bar.fullScreenBoxUsual", BarScreen.origin(visible: screen, size: size, avoiding: CGRect(x: 0, y: 0, width: 1512, height: 944)) == CGPoint(x: 556, y: 120))
    // A second screen's visible frame and a box on it.
    let right = CGRect(x: 1512, y: -200, width: 1920, height: 1055)
    check("bar.otherScreenAbove", BarScreen.origin(visible: right, size: size, avoiding: CGRect(x: 1700, y: -150, width: 1400, height: 120)) == CGPoint(x: 2272, y: -18))
    check("bar.emptyBoxIgnored", BarScreen.origin(visible: screen, size: size, avoiding: .zero) == CGPoint(x: 556, y: 120))
}

check("box.noURLChangedConversationTitle", BoxMatch.failure(start: BoxPrint(role: "AXTextArea", identifier: "composer", frame: f0, text: "Same text", title: "Chat A"), now: BoxPrint(role: "AXTextArea", identifier: "composer", frame: f0, text: nil, title: "Chat B"), nowText: "Same text", sameElement: true) == .title)

// Escape needs two quick presses (D-987): one goes to the app, two within half a second throw the recording away.
// No keys posted: the counting rule, the box rule, and the bar's words when no box takes them.
do {
    var e = EscapeTwice()
    check("escape2.oneIsNot", !e.press(at: 10))
    check("escape2.twoQuick", e.press(at: 10.3))
    check("escape2.pairUsedUp", !e.press(at: 10.5))
    check("escape2.edgeOfWindow", e.press(at: 10.5 + EscapeTwice.window))
    var slow = EscapeTwice()
    _ = slow.press(at: 20)
    check("escape2.tooSlow", !slow.press(at: 20.51))
    check("escape2.slowSecondStartsNewPair", slow.press(at: 20.8))
    var held = EscapeTwice()
    _ = held.press(at: 30)
    check("escape2.repeatIsNotAPress", !held.press(at: 30.1, repeated: true) && !held.press(at: 30.15, repeated: true))
    check("escape2.realSecondAfterRepeats", held.press(at: 30.2))
    var backwards = EscapeTwice()
    _ = backwards.press(at: 40)
    check("escape2.olderEventNotASecond", !backwards.press(at: 39.9))
    check("escape2.window", EscapeTwice.window == 0.5 && EscapeTwice.keyCode == 53)
    // A fresh recording starts counting again: a press just before it can't pair with one inside it.
    var fresh = EscapeTwice()
    check("escape2.freshAfterArming", !fresh.press(at: 50.1))
    // Escape types nothing: it never marks the box you started in as edited. Letters and Delete still do.
    check("escape2.notAnEdit", !EscapeTwice.marksBoxEdited(keyCode: 53))
    check("escape2.letterIsAnEdit", EscapeTwice.marksBoxEdited(keyCode: 0) && EscapeTwice.marksBoxEdited(keyCode: 51))
    // A held talk key still treats any other key as a shortcut; Escape is kept out of that path in HoldKey and only
    // noted as a key-down, which leaves the held press recording.
    var k = TalkKeyState()
    _ = k.event(key: 63, down: true, at: 1)
    check("escape2.otherKeyStillCancelsHold", k.otherKey(at: 1.5) == .cancel)
    var hk = TalkKeyState()
    _ = hk.event(key: 63, down: true, at: 1)
    hk.noteKeyDown(talkKey: false, at: 1.5)
    check("escape2.escapeNoteKeepsHold", hk.active && hk.held && hk.lastTypingKeyDownAt == 1.5)

    // No box: the bar asks while the words wait, plain and short, with no colon or em dash.
    let lines = [DictationEnding.waitQuestion, DictationEnding.copyButton, DictationEnding.throwAwayButton,
                 DictationEnding.copiedNote, DictationEnding.thrownAwayNote]
    check("wait.question", DictationEnding.waitQuestion == "No box here. Click where your words go")
    check("wait.buttons", DictationEnding.copyButton == "Copy" && DictationEnding.throwAwayButton == "Throw away")
    check("wait.plain", lines.allSatisfy { !$0.contains("\u{2014}") && !$0.contains("\u{2013}") && !$0.contains(":") })
    check("wait.short", DictationEnding.waitQuestion.count <= 40 && DictationEnding.thrownAwayNote.count <= 40)
    check("wait.stillTenMinutes", DictationEnding.waitSeconds == 600)
    // Copy leaves the words on the clipboard the way Paste last does when it can't confirm: marked, kept for Command-V.
    let pb = NSPasteboard(name: NSPasteboard.Name("rv-wait-copy-\(UUID().uuidString)"))
    pb.clearContents(); pb.setString("older copy", forType: .string)
    let loan = PasteClipboardLoan("waiting words", pasteboard: pb)
    check("wait.copyOnClipboard", loan != nil && pb.string(forType: .string) == "waiting words")
    check("wait.copyMarkedTransient", pb.pasteboardItems?.first?.types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) == true)
    check("wait.copyKept", loan?.finish(confirmed: false) == .kept && pb.string(forType: .string) == "waiting words")
    pb.releaseGlobally()
}

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

// Meeting notes (D-951): clock, file name, lines from words, echo, merge by time, the file, the summary pieces.
do {
    check("meeting.clock", Meeting.clock(252) == "04:12" && Meeting.clock(0) == "00:00" && Meeting.clock(3852) == "1:04:12")
    check("meeting.clockNegative", Meeting.clock(-3) == "00:00")
    check("meeting.length", Meeting.length(40) == "40 s" && Meeting.length(42 * 60) == "42 min" && Meeting.length(65 * 60) == "1 h 5 min" && Meeting.length(7200) == "2 h")
    var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Toronto")!
    let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 14, minute: 15, second: 41))!
    check("meeting.baseName", Meeting.baseName(start, calendar: cal) == "2026-10-30 1415 Meeting", Meeting.baseName(start, calendar: cal))
    let taken: Set<String> = ["2026-10-30 1415 Meeting", "2026-10-30 1415 Meeting 2"]
    check("meeting.uniqueFree", Meeting.uniqueBase("2026-10-30 1416 Meeting") { taken.contains($0) } == "2026-10-30 1416 Meeting")
    check("meeting.uniqueTaken", Meeting.uniqueBase("2026-10-30 1415 Meeting") { taken.contains($0) } == "2026-10-30 1415 Meeting 3")

    // Words into lines: a pause starts a new line, a long run is split, a finished sentence ends a line.
    let words = [TimedWord("So", start: 0, end: 0.3), TimedWord("the", start: 0.35, end: 0.5), TimedWord("plan.", start: 0.55, end: 1),
                 TimedWord("Next", start: 2.5, end: 2.8), TimedWord("week", start: 2.85, end: 3.1)]
    let g = Meeting.group(words)
    check("meeting.groupPause", g.count == 2 && g[0].text == "So the plan." && g[1].text == "Next week" && g[1].start == 2.5, "\(g)")
    let run = (0..<40).map { TimedWord("w\($0)", start: Double($0) * 0.7, end: Double($0) * 0.7 + 0.5) }
    let gr = Meeting.group(run, maxSeconds: 20)
    check("meeting.groupMax", gr.count == 2 && gr.allSatisfy { $0.end - $0.start <= 20 }, "\(gr.map { $0.end - $0.start })")
    let sentences = [TimedWord("We", start: 0, end: 1), TimedWord("agree.", start: 4, end: 4.5), TimedWord("Good", start: 4.6, end: 5)]
    check("meeting.groupSentence", Meeting.group(sentences).count == 2)
    check("meeting.groupEmpty", Meeting.group([]).isEmpty && Meeting.group([TimedWord(" ", start: 0, end: 1)]).isEmpty)

    // Echo: a Me line that repeats the Others line at the same time goes; your own words stay.
    let others = [MeetingSegment(start: 10, end: 14, text: "We should ship the pricing page on Friday."),
                  MeetingSegment(start: 30, end: 31, text: "Yeah.")]
    let me = [MeetingSegment(start: 10.3, end: 14.2, text: "we should ship the pricing page friday"),   // echo, a word missed
              MeetingSegment(start: 15, end: 18, text: "Friday works, I'll write the copy."),            // mine, after
              MeetingSegment(start: 30.2, end: 30.8, text: "Yeah."),                                     // short echo
              MeetingSegment(start: 31.5, end: 32, text: "Okay."),                                       // short, mine
              MeetingSegment(start: 60, end: 64, text: "We should ship the pricing page on Friday.")]     // same words, much later
    let e = Meeting.dropEcho(me: me, others: others)
    check("meeting.echoDropped", e.dropped == 2, "\(e.dropped)")
    check("meeting.echoKeepsMine", e.kept.map(\.start) == [15, 31.5, 60], "\(e.kept.map(\.start))")
    let partial = [MeetingSegment(start: 11, end: 13, text: "ship it on Monday instead, the page isn't ready")]
    check("meeting.echoPartialKept", Meeting.dropEcho(me: partial, others: others).dropped == 0)
    check("meeting.echoNoOthers", Meeting.dropEcho(me: me, others: []).kept.count == me.count)
    check("meeting.echoEmptyMeGone", Meeting.dropEcho(me: [MeetingSegment(start: 1, end: 2, text: " ... ")], others: []).kept.isEmpty)

    // Merge by time; at the same second Others first.
    let merged = Meeting.merge(me: [MeetingSegment(start: 5, end: 6, text: "b"), MeetingSegment(start: 1, end: 2, text: "a")],
                               others: [MeetingSegment(start: 5, end: 7, text: "q"), MeetingSegment(start: 9, end: 10, text: "c")])
    check("meeting.merge", merged.map(\.text) == ["a", "q", "b", "c"] && merged[1].speaker == .others, "\(merged.map(\.text))")
    // Pause and resume (D-957): the bar's time stands still while paused, the notes mark each pause where it began,
    // and nothing written inside a pause survives.
    var pz = MeetingPauses()
    check("pause.none", pz.recorded(at: 100) == 100 && !pz.isPaused)
    pz.pause(at: 60); pz.pause(at: 70)  // a second press while paused changes nothing
    check("pause.frozen", pz.isPaused && pz.recorded(at: 60) == 60 && pz.recorded(at: 190) == 60)
    pz.resume(at: 190)
    check("pause.resumed", !pz.isPaused && pz.recorded(at: 250) == 120 && pz.done == [MeetingPause(start: 60, end: 190)])
    pz.resume(at: 300)  // resume when not paused does nothing
    check("pause.resumeTwice", pz.done.count == 1)
    pz.pause(at: 400)
    check("pause.openClosedAtStop", pz.all(closingAt: 430) == [MeetingPause(start: 60, end: 190), MeetingPause(start: 400, end: 430)]
          && pz.recorded(at: 430) == 270)
    check("pause.codable", (try? JSONDecoder().decode(MeetingPauses.self, from: JSONEncoder().encode(pz))) == pz)
    check("pause.clockShort", Meeting.clockShort(21.9) == "0:21" && Meeting.clockShort(754.2) == "12:34" && Meeting.clockShort(-1) == "0:00")
    check("pause.span", Meeting.span(130) == "2:10" && Meeting.span(5) == "0:05" && Meeting.span(3730) == "1:02:10")
    let talk2 = [MeetingLine(start: 50, speaker: .me, text: "Before.", end: 58),
                 MeetingLine(start: 100, speaker: .others, text: "Thank you.", end: 101),   // invented in the silence
                 MeetingLine(start: 190, speaker: .others, text: "After.", end: 195)]
    let marked = Meeting.withPauses(talk2, [MeetingPause(start: 60, end: 190), MeetingPause(start: 300, end: 300.4)])
    check("pause.marked", marked.map(\.markdown) == ["[00:50] Me: Before.", "[01:00] [paused 2:10]", "[03:10] Others: After."], "\(marked.map(\.markdown))")
    check("pause.atSameSecondFirst", Meeting.withPauses([MeetingLine(start: 60, speaker: .me, text: "x", end: 59.5)],
                                                       [MeetingPause(start: 60, end: 70)]).first?.speaker == .pause)
    let pmd = Meeting.markdown(start: start, seconds: 300, lines: marked, audio: [], echoDropped: 0, engine: "Whisper", paused: 130, calendar: cal)
    check("pause.header", pmd.contains("- Paused: 2 min, nothing recorded then\n") && pmd.contains("[01:00] [paused 2:10]"))
    var mfp = MeetingManifest(started: start); mfp.pauses = pz
    check("pause.manifest", (try? JSONDecoder().decode(MeetingManifest.self, from: JSONEncoder().encode(mfp)))?.pauses == pz)

    // Repeats and paragraphs (from the first live test): "Okay." "Okay." goes, a turn reads as one paragraph.
    let said2 = [MeetingLine(start: 0, speaker: .others, text: "The serene waters of.", end: 1.5),
                 MeetingLine(start: 2, speaker: .others, text: "The serene waters of", end: 3),
                 MeetingLine(start: 3.2, speaker: .me, text: "Okay.", end: 3.6),
                 MeetingLine(start: 3.8, speaker: .others, text: "Then the match.", end: 5),
                 MeetingLine(start: 4.0, speaker: .me, text: "Okay.", end: 4.3),
                 MeetingLine(start: 9, speaker: .me, text: "Okay.", end: 9.5)]
    let dr = Meeting.dropRepeats(said2)
    check("meeting.repeatDropped", dr.map(\.text) == ["The serene waters of.", "Okay.", "Then the match.", "Okay."], "\(dr.map(\.text))")
    check("meeting.repeatLaterKept", dr.last?.start == 9)
    check("meeting.repeatNotOtherSpeaker", Meeting.dropRepeats([MeetingLine(start: 0, speaker: .others, text: "Yes.", end: 1),
                                                                MeetingLine(start: 1, speaker: .me, text: "Yes.", end: 2)]).count == 2)
    check("meeting.repeatDifferentWordsKept", Meeting.dropRepeats([MeetingLine(start: 0, speaker: .me, text: "Okay.", end: 1),
                                                                   MeetingLine(start: 1, speaker: .me, text: "Okay, okay.", end: 2)]).count == 2)
    let turns = [MeetingLine(start: 0, speaker: .me, text: "The WSL.", end: 1), MeetingLine(start: 1.5, speaker: .me, text: "Yes.", end: 2),
                 MeetingLine(start: 4.5, speaker: .me, text: "Okay.", end: 5),
                 MeetingLine(start: 9, speaker: .me, text: "After a pause.", end: 10),
                 MeetingLine(start: 10.5, speaker: .others, text: "Their turn.", end: 11),
                 MeetingLine(start: 11.5, speaker: .me, text: "Mine again.", end: 12)]
    let ps2 = Meeting.paragraphs(turns)
    check("meeting.paragraphJoin", ps2.first?.text == "The WSL. Yes. Okay." && ps2.first?.start == 0, "\(ps2.map(\.text))")
    check("meeting.paragraphGapAndTurns", ps2.map(\.text) == ["The WSL. Yes. Okay.", "After a pause.", "Their turn.", "Mine again."], "\(ps2.map(\.text))")
    let longTurn = (0..<20).map { MeetingLine(start: Double($0) * 6, speaker: .others, text: "Line \($0).", end: Double($0) * 6 + 5) }
    let capped = Meeting.paragraphs(longTurn)
    check("meeting.paragraphCap", capped.count == 3 && capped.map(\.start) == [0, 48, 96] && capped.allSatisfy { $0.end - $0.start <= 50 }, "\(capped.map(\.start))")
    check("meeting.paragraphEmpty", Meeting.paragraphs([]).isEmpty && Meeting.dropRepeats([]).isEmpty)
    check("meeting.mergeKeepsEnd", Meeting.merge(me: [MeetingSegment(start: 1, end: 4, text: "x")], others: []).first?.end == 4)
    check("meeting.line", MeetingLine(start: 252, speaker: .me, text: "Hi.").markdown == "[04:12] Me: Hi.")

    // The file: header, transcript in order, audio links, no em dashes.
    let md = Meeting.markdown(start: start, seconds: 42 * 60, lines: merged, audio: ["2026-10-30 1415 Meeting Me.m4a"], echoDropped: 3,
                              engine: "Whisper", calendar: cal)
    check("meeting.mdTitle", md.hasPrefix("# Meeting notes, Friday 30 October 2026\n"), String(md.prefix(60)))
    check("meeting.mdHeader", md.contains("- Date: 2026-10-30\n") && md.contains("- Started: 14:15\n") && md.contains("- Length: 42 min\n"))
    check("meeting.mdAudio", md.contains("[2026-10-30 1415 Meeting Me.m4a](<2026-10-30 1415 Meeting Me.m4a>)"))
    check("meeting.mdEcho", md.contains("3 Me lines were left out"))
    check("meeting.mdTranscript", md.contains("## Transcript\n\n[00:01] Me: a\n\n[00:05] Others: q\n\n[00:05] Me: b\n\n[00:09] Others: c\n"))
    check("meeting.notice", Meeting.notice == "Heads up: I'm taking notes on this call with Redpen. It runs on my Mac and nothing is sent anywhere.")
    check("meeting.mdNoDash", !md.contains("\u{2014}") && !md.contains("\u{2013}"))
    let quiet = Meeting.markdown(start: start, seconds: 30, lines: [], audio: [], echoDropped: 0, engine: "Whisper", calendar: cal)
    let noted = Meeting.markdown(start: start, seconds: 30, lines: [], audio: [], echoDropped: 0, engine: "Whisper", notes: [Meeting.silentMacNote], calendar: cal)
    check("meeting.mdNote", noted.contains(Meeting.silentMacNote + "\n\n## Transcript"))
    check("meeting.mdEmpty", quiet.contains("Nothing was heard.") && !quiet.contains("- Audio:") && !quiet.contains("left out"))

    // Summary pieces: whole lines, under the limit, nothing lost.
    let lines = (0..<50).map { "[00:\(String(format: "%02d", $0))] Others: line number \($0) of the meeting" }
    let ps = Meeting.pieces(lines, maxChars: 300)
    check("meeting.piecesFit", ps.count > 1 && ps.allSatisfy { $0.count <= 300 }, "\(ps.map(\.count))")
    check("meeting.piecesWhole", ps.joined(separator: "\n") == lines.joined(separator: "\n"))
    check("meeting.piecesOne", Meeting.pieces(["short"], maxChars: 300) == ["short"] && Meeting.pieces([], maxChars: 300).isEmpty)
    let long = String(repeating: "word ", count: 200)
    let lp = Meeting.pieces([long], maxChars: 100)
    check("meeting.piecesLongLine", lp.allSatisfy { $0.count <= 100 } && lp.joined(separator: " ").split(separator: " ").count == 200, "\(lp.map(\.count))")

    // Names: Me, Others, or a name said in the meeting; never one the model made up.
    let said = "[00:01] Others: Thanks Priya, can you send the deck? [00:04] Me: Sure."
    check("meeting.whoMe", Meeting.who("me", transcript: said) == "Me" && Meeting.who("I", transcript: said) == "Me")
    check("meeting.whoOthers", Meeting.who("Others", transcript: said) == "Others")
    check("meeting.whoSilentMe", Meeting.who("Me", transcript: "[00:01] Others: I'll send it.") == "Not clear")
    check("meeting.unknownTime", Meeting.unknownNames("Meet Friday at 10 AM.", transcript: "[00:01] Others: Friday at ten") == [])
    check("meeting.whoSaid", Meeting.who("Priya", transcript: said) == "Priya")
    check("meeting.whoInvented", Meeting.who("John Smith", transcript: said) == "Not clear")
    check("meeting.unknownSlash", Meeting.unknownNames("Back after the July/August break.", transcript: "[00:01] Others: July and August off") == [])
    check("meeting.unknownNames", Meeting.unknownNames("Priya will send the deck to Marcus by Friday.", transcript: said) == ["Marcus", "Friday"])
    // Summary v2 (D-956): times, the citation check, the to-do filter, reading a written summary, where it goes.
    check("summary.seconds", Meeting.seconds("12:34") == 754 && Meeting.seconds("1:02:03") == 3723 && Meeting.seconds("[00:05]") == 5)
    check("summary.secondsBad", Meeting.seconds("12:3") == nil && Meeting.seconds("12:60") == nil && Meeting.seconds("soon") == nil && Meeting.seconds("1:2:03") == nil)
    check("summary.citedEnd", Meeting.cited("The deck is late. [01:10]") == ("The deck is late.", 70))
    check("summary.citedSeveral", Meeting.cited("Budget up 20% [00:05, 01:10].").at == 5 && Meeting.cited("Budget up 20% [00:05, 01:10].").text == "Budget up 20%")
    check("summary.citedStart", Meeting.cited("[02:30] Book the studio.") == ("Book the studio.", 150))
    check("summary.citedNone", Meeting.cited("No time here.") == ("No time here.", nil) && Meeting.cited("Costs (about 5%) rose.").at == nil)
    let tx = """
    [00:05] Others: Thanks for joining. The plan is to raise the marketing budget by 20% for Q3 and focus on Gen Z this time.

    [00:40] Others: Our numbers last quarter were strong across every channel, especially video and podcasts, and the board was happy with how the launch went overall.

    [01:10] Me: I'll send the revised budget deck to Priya by Friday.

    [02:30] Others: Can you book the studio for the March 3 shoot?

    [02:50] [paused 1:00]

    [03:00] Others: Great, have a lovely weekend everyone.
    """
    let heard = Meeting.said(tx)
    check("summary.said", heard.count == 5 && heard[2] == Meeting.Said(at: 70, speaker: "Me", text: "I'll send the revised budget deck to Priya by Friday."))
    let file = "# Meeting notes\n\n- Date: 2026-10-31\n\n## Transcript\n\n" + tx + "\n"
    check("summary.transcriptInFile", Meeting.said(Meeting.transcript(inFile: file)).count == 5 && Meeting.transcript(inFile: "# No transcript\n").isEmpty)
    let raw = Meeting.Summary(
        overview: "A planning call about the Q3 budget.",
        points: [Meeting.Cited("The marketing budget rises 20% for Q3.", at: 5),
                 Meeting.Cited("The marketing budget rises 20% in Q3.", at: 150),
                 Meeting.Cited("The marketing budget rises 30% for Q3.", at: 5),
                 Meeting.Cited("The studio is booked for the March 3 shoot.", at: nil),
                 Meeting.Cited("Sales doubled in Europe.", at: 40)],
        decisions: [],
        todos: [Meeting.ToDo(who: "Me", task: "Send the revised budget deck to Priya by Friday.", at: 70),
                Meeting.ToDo(who: "Others", task: "Have a lovely weekend.", at: 180),
                Meeting.ToDo(who: "Others", task: "Focus the marketing on Gen Z.", at: 5),
                Meeting.ToDo(who: "Bob", task: "Book the studio for the March 3 shoot.", at: 150),
                Meeting.ToDo(who: "Me", task: "Book the studio for the March 3 shoot.", at: 9999)])
    let ck = Meeting.check(raw, transcript: tx)
    check("summary.checkKept", ck.summary.points.first == Meeting.Cited("The marketing budget rises 20% for Q3.", at: 5), "\(ck.summary.points)")
    // Moved to the line that says it, then kept once: it repeats the first point (D-1126).
    check("summary.checkMoved", ck.moved >= 1 && ck.summary.points.filter { $0.text.contains("20%") }.count == 1, "\(ck.moved)")
    check("summary.checkWrongNumber", !ck.summary.points.contains { $0.text.contains("30%") })
    check("summary.checkUncitedFound", ck.summary.points.contains(Meeting.Cited("The studio is booked for the March 3 shoot.", at: 150)))
    check("summary.checkNotSaid", !ck.summary.points.contains { $0.text.contains("Europe") } && ck.dropped == 2, "\(ck.dropped)")
    check("summary.checkUncitedCount", ck.uncited == 2, "\(ck.uncited)")
    check("summary.todoKept", ck.summary.todos.first == Meeting.ToDo(who: "Me", task: "Send the revised budget deck to Priya by Friday.", at: 70, when: "Friday"), "\(ck.summary.todos)")
    check("summary.todoPleasantry", !ck.summary.todos.contains { $0.task.contains("weekend") })
    check("summary.todoNotAsked", !ck.summary.todos.contains { $0.task.contains("Gen Z") } && ck.notTasks == 2, "\(ck.notTasks)")
    // A made-up owner is Not clear; alone, that copy stays, and beside one with an owner, the owned one wins.
    check("summary.todoOwner", Meeting.check(Meeting.Summary(todos: [Meeting.ToDo(who: "Bob", task: "Book the studio for the March 3 shoot.", at: 150)]), transcript: tx).summary.todos
          .contains(Meeting.ToDo(who: "Not clear", task: "Book the studio for the March 3 shoot.", at: 150, when: "March 3"))
          && ck.summary.todos.contains { $0.who == "Me" && $0.task.hasPrefix("Book the studio") }, "\(ck.summary.todos)")
    check("summary.todoBadTime", ck.summary.todos.filter { $0.task.hasPrefix("Book the studio") }.count == 1)
    check("summary.todoBadTimeAlone", Meeting.check(Meeting.Summary(todos: [Meeting.ToDo(who: "Me", task: "Book the studio for the March 3 shoot.", at: 9999)]), transcript: tx).summary.todos.prefix(1)
          == [Meeting.ToDo(who: "Me", task: "Book the studio for the March 3 shoot.", at: 150, when: "March 3")])
    check("summary.commitment", Meeting.isCommitment("Sure, I’ll do that") && Meeting.isCommitment("Could you book it?") && !Meeting.isCommitment("The numbers were strong."))
    check("summary.pleasantry", Meeting.isPleasantry("Thank everyone for coming") && Meeting.isPleasantry("Enjoy the weekend") && !Meeting.isPleasantry("Book the studio"))

    // From the review: real to-dos that mention a weekend or thanks, numbers in words, predictions, times of day.
    check("summary.pleasantryOnly", !Meeting.isPleasantry("Finish the budget report over the weekend") && !Meeting.isPleasantry("Send a thank-you note to the client")
          && Meeting.isPleasantry("Have a lovely weekend everyone") && Meeting.isPleasantry("Thanks everyone for joining"))
    check("summary.prediction", !Meeting.isCommitment("Sales are going to drop next quarter") && Meeting.isCommitment("We're going to send it Monday") && Meeting.isCommitment("Let me check with finance"))
    check("summary.citedTimeOfDay", Meeting.cited("Next meeting Tuesday (10:30).") == ("Next meeting Tuesday (10:30).", nil))
    let money = "[00:10] Others: The contract is worth five thousand dollars and nobody objected.\n\n[00:30] Others: We have twenty five stores, and two hundred fifty staff."
    let mc = Meeting.check(Meeting.Summary(points: [Meeting.Cited("The contract is worth $5,000.", at: 10), Meeting.Cited("No one objected to the contract.", at: 10),
                                                    Meeting.Cited("There are 25 stores and 250 staff.", at: 30), Meeting.Cited("The contract is worth $6,000.", at: 10)]), transcript: money)
    check("summary.numberWords", mc.summary.points.count == 3 && mc.dropped == 1 && !mc.summary.points.contains { $0.text.contains("6,000") }, "\(mc.summary.points.map(\.text))")
    let pc = Meeting.check(Meeting.Summary(todos: [Meeting.ToDo(who: "Others", task: "Sales drop 20% next quarter.", at: 5)]),
                           transcript: "[00:05] Others: Sales are going to drop 20% next quarter, honestly.")
    check("summary.predictionNotTask", pc.summary.todos.isEmpty && pc.notTasks == 1)
    check("summary.parseBoldOverview", Meeting.parse(written: "### Overview\n**The team agreed to ship.**\nThen they left.\n### Key points\n- Ship it [00:05]")?.overview == "The team agreed to ship. Then they left.")

    let pa = Meeting.Summary(overview: "A", points: [Meeting.Cited("Budget rises 20% for Q3.", at: 5), Meeting.Cited("Kids are sick this week.", at: 9)])
    let pb = Meeting.Summary(overview: "B", points: [Meeting.Cited("The marketing budget rises 20% in Q3.", at: 400), Meeting.Cited("Studio booked for March 3.", at: 500)],
                             todos: [Meeting.ToDo(who: "Me", task: "Send the deck.", at: 450)])
    let joined = Meeting.merge([pa, pb], overview: "Both.", points: 3)
    check("summary.mergeTurns", joined.points.map(\.text) == ["Budget rises 20% for Q3.", "Kids are sick this week.", "Studio booked for March 3."] && joined.todos.count == 1 && joined.overview == "Both.", "\(joined.points.map(\.text))")
    check("summary.namesPossessive", Meeting.unknownNames("The list comes after Friday's meeting.", transcript: "[00:01] Others: on Friday at ten") == [])

    let clockCk = Meeting.check(Meeting.Summary(todos: [Meeting.ToDo(who: "Others", task: "Send the list around 12:30 after the 10:00 meeting on Friday.", at: 5)]),
                                transcript: "[00:05] Others: That's on Friday at 10, so I'll send you the list around 1230 after that meeting.")
    check("summary.timeOfDay", clockCk.summary.todos.count == 1, "\(clockCk.dropped) \(clockCk.notTasks)")
    check("summary.namesPlural", Meeting.unknownNames("Meet them at Hogan's. Tie it to ticket IDs.", transcript: "[00:01] Others: at Hogan's on the 17th, the ticket ID") == [])

    let sm = Meeting.summaryMarkdown(ck, transcript: tx)
    check("summary.mdLabel", sm.hasPrefix("## Summary\n\n" + Meeting.summaryLabel + "\n\n### Overview\n\nA planning call about the Q3 budget.\n\n"))
    check("summary.mdTimes", sm.contains("- The marketing budget rises 20% for Q3. [00:05]") && sm.contains("- Me: Send the revised budget deck to Priya by Friday. (by Friday) [01:10]"))
    check("summary.mdNone", sm.contains("### Decisions\n\nNone heard.\n"))
    check("summary.mdDropped", sm.contains("2 more items were left out because no line of the transcript says them."))
    let empty = Meeting.summaryMarkdown(Meeting.check(Meeting.Summary(), transcript: "[00:01] Others: Hello there."), transcript: tx)
    check("summary.mdEmpty", empty.contains("### Overview\n\nNone heard.") && empty.contains("### To-dos\n\nNone heard.\n") && !empty.contains("left out"))
    check("summary.mdNames", Meeting.summaryMarkdown(Meeting.Checked(summary: Meeting.Summary(overview: "The call was led by Marcus.")), transcript: tx).contains("check them: Marcus"))

    let written = """
    Here are the notes.

    ### Overview
    A planning call. The budget goes up.

    ### Key points
    - The marketing budget rises 20% for Q3. [00:05]
    - **Studio** booked for March 3. [02:30]

    ### Decisions
    None heard.

    ### To-dos
    - Me: Send the deck to Priya by Friday. [01:10]
    - Book the studio [02:30]
    """
    let parsed = Meeting.parse(written: written)
    check("summary.parse", parsed?.overview == "A planning call. The budget goes up." && parsed?.points.count == 2 && parsed?.decisions.isEmpty == true, "\(String(describing: parsed))")
    check("summary.parseItems", parsed?.points.last == Meeting.Cited("Studio booked for March 3.", at: 150)
          && parsed?.todos == [Meeting.ToDo(who: "Me", task: "Send the deck to Priya by Friday.", at: 70), Meeting.ToDo(who: "Not clear", task: "Book the studio", at: 150)])
    check("summary.parseBold", Meeting.parse(written: "**Overview**\nShort.\n**Key points**\n1. One thing [00:05]\n")?.points == [Meeting.Cited("One thing", at: 5)])
    check("summary.parseNothing", Meeting.parse(written: "Sorry, I can't help with that.") == nil)

    // Where it goes: above the transcript, once; a better summary on top with Apple's kept below it.
    let free = "## Summary\n\n" + Meeting.summaryLabel + "\n\n### Overview\n\nFree.\n"
    let better = "## Summary\n\n" + Meeting.betterLabel("Claude") + "\n\n### Overview\n\nBetter.\n"
    let placed = Meeting.placing(free, in: file)
    check("summary.placeAbove", placed.contains("- Date: 2026-10-31\n\n## Summary\n") && placed.range(of: "## Summary")!.lowerBound < placed.range(of: "## Transcript")!.lowerBound)
    check("summary.placeOnce", Meeting.placing(free, in: placed) == placed)
    check("summary.placeKeepsTranscript", Meeting.said(Meeting.transcript(inFile: placed)) == heard)
    let oldFile = file + "\n" + free
    check("summary.placeMovesOld", Meeting.placing(free, in: oldFile) == placed)
    let both = Meeting.placingBetter(better, in: placed)
    let iB = both.range(of: "Better.")!.lowerBound, iF = both.range(of: Meeting.freeHeading)!.lowerBound, iT = both.range(of: "## Transcript")!.lowerBound
    check("summary.betterOnTop", iB < iF && iF < iT && both.components(separatedBy: "\n## Summary\n").count == 2)
    check("summary.betterAgain", Meeting.placingBetter(better, in: both) == both)
    check("summary.freeAfterBetter", Meeting.placing(free, in: both) == both)
    check("summary.betterTranscript", Meeting.said(Meeting.transcript(inFile: both)) == heard)
    check("meeting.noSummary", Meeting.noSummary("Apple's model is off on this Mac.").contains("No summary was written. Apple's model"))

    // What has to happen (D-1108, D-1126): dates and what is critical come from the lines, never the model.
    check("steps.date", Meeting.date(in: "I'll redraw it tonight and send it over.") == "tonight"
          && Meeting.date(in: "Can you place the order Monday morning?") == "Monday morning"
          && Meeting.date(in: "Let's get it done by the end of the week.") == "end of the week"
          && Meeting.date(in: "We need it first thing tomorrow") == "first thing tomorrow", "\(String(describing: Meeting.date(in: "Can you place the order Monday morning?")))")
    check("steps.dateNone", Meeting.date(in: "You may want to check the hood fan.") == nil && Meeting.date(in: "I'll call the city.") == nil)
    check("steps.dateAfterCommitment", Meeting.date(in: "We met Monday, and I'll send it Friday.") == "Friday")
    check("steps.soon", Meeting.isSoon("tomorrow morning") && Meeting.isSoon("tonight") && Meeting.isSoon("ASAP") && !Meeting.isSoon("Monday") && !Meeting.isSoon("end of the week"))
    let room = """
    [15:01] Lena: The inspection is the one thing that could push the kitchen past Christmas.

    [15:09] Me: I'll call the city tomorrow morning and ask for the first open inspection slot.

    [15:15] Marco: Does the permit even cover the hood fan? Nobody knows.

    [16:00] Marco: I'll redraw the island 15 cm shorter.

    [17:00] Lena: Can you place the cabinet order Monday?

    [17:05] Me: Sure.
    """
    let roomLines = Meeting.said(room)
    check("steps.waits", Meeting.waitsOn(around: 1, in: roomLines) && !Meeting.waitsOn(around: 3, in: roomLines))
    check("steps.deadlineReply", Meeting.deadline(around: 4, in: roomLines) == "Monday" && Meeting.deadline(around: 3, in: roomLines) == nil
          && Meeting.deadline(around: 0, in: Meeting.said("[00:01] Me: I'll send the deck.\n\n[00:04] Others: Sure, by Friday works.")) == "Friday")
    let rc = Meeting.check(Meeting.Summary(overview: "A kitchen walk-through.",
        decisions: [Meeting.Cited("The island gets 15 cm shorter.", at: 960)],
        todos: [Meeting.ToDo(who: "Marco", task: "Redraw the island 15 cm shorter.", at: 960),
                Meeting.ToDo(who: "Me", task: "Place the cabinet order.", at: 1020),
                Meeting.ToDo(who: "Me", task: "Call the city and ask for the first open inspection slot.", at: 909, when: "next year", critical: false)],
        open: [Meeting.Cited("Does the permit cover the hood fan?", at: 915), Meeting.Cited("Is the budget approved?", at: 915)]), transcript: room)
    let call = rc.summary.todos.first { $0.task.hasPrefix("Call the city") }
    check("steps.checkDate", call?.when == "tomorrow morning" && call?.critical == true, "\(String(describing: call))")
    check("steps.checkOpen", rc.summary.open.map(\.text) == ["Does the permit cover the hood fan?"] && rc.dropped >= 1, "\(rc.summary.open)")
    let ranked = Meeting.ranked(rc.summary.todos + [Meeting.ToDo(who: "Not clear", task: "Check the hood fan.", at: 915)])
    check("steps.ranked", ranked.map { Meeting.urgency($0) } == [.critical, .dated, .undated, .unowned], "\(ranked)")
    check("steps.why", Meeting.why(call!) == "Due tomorrow morning" && Meeting.why(Meeting.ToDo(who: "Me", task: "x", critical: true)) == "Something waits on it" && Meeting.why(ranked[2]) == nil)
    let rmd = Meeting.summaryMarkdown(rc, transcript: room)
    check("steps.mdFirst", rmd.range(of: "### To-dos")!.lowerBound < rmd.range(of: "### Still open")!.lowerBound
          && rmd.range(of: "### Still open")!.lowerBound < rmd.range(of: "### Decisions")!.lowerBound
          && rmd.range(of: "### Decisions")!.lowerBound < rmd.range(of: "### Key points")!.lowerBound)
    check("steps.mdLine", rmd.contains("- Me: Call the city and ask for the first open inspection slot. (critical, by tomorrow morning) [15:09]"), rmd)
    let back2 = Meeting.parse(written: rmd)
    check("steps.parseBack", Set((back2?.todos ?? []).map(\.task)) == Set(rc.summary.todos.map(\.task)))
    let backCall = back2?.todos.first { $0.task.hasPrefix("Call the city") }
    check("steps.parseMarks", backCall?.when == "tomorrow morning" && backCall?.critical == true && backCall?.who == "Me"
          && back2?.open.map(\.text) == ["Does the permit cover the hood fan?"], "\(String(describing: back2))")
    // From the code review: each of these once put a wrong owner, a wrong date or a made-up job on the list.
    let sameSecond = Meeting.check(Meeting.Summary(todos: [Meeting.ToDo(who: "Me", task: "Send the budget deck tomorrow morning.", at: 60)]),
                                   transcript: "[01:00] Others: I'll handle the venue booking.\n\n[01:00] Me: I'll send the budget deck tomorrow morning.")
    check("review.sameSecond", sameSecond.summary.todos.first { $0.task.contains("budget") }.map { $0.who == "Me" && $0.when == "tomorrow morning" && $0.critical } == true, "\(sameSecond.summary.todos)")
    let samePage = AfterCallPage.html(AfterCallPage.read("# Meeting notes, x\n\n## Summary\n\n### To-dos\n\n- Me: Send the budget deck. (critical, by tomorrow morning) [01:00]\n\n## Transcript\n\n[01:00] Others: I'll handle the venue booking.\n\n[01:00] Me: I'll send the budget deck tomorrow morning.\n"), sender: "", audio: true)
    check("review.sameSecondPage", samePage.contains("data-line=\"1\" data-track=\"me\""), "page")
    check("review.letMeKnow", Meeting.promiser(around: 0, in: Meeting.said("[00:01] Me: Let me know when you have sent the signed contract to legal."), task: "Send the signed contract to legal.") == nil)
    let noJobs = Meeting.promises(in: Meeting.said("[00:01] Me: I can't make it tomorrow, sorry.\n\n[00:05] Me: I have to leave at noon today.\n\n[00:09] Me: Let me know by Friday what you think.\n\n[00:12] Me: I'll go with the 3rd option.\n\n[00:15] Me: I can tell you that on Monday the client was angry.\n\n[00:20] Me: I won't send it tomorrow."))
    check("review.noMadeUpJobs", noJobs.isEmpty, "\(noJobs)")
    check("review.ordinalDate", Meeting.date(in: "Go with the 3rd option.") == nil && Meeting.date(in: "Send it by the 3rd.") == "the 3rd" && Meeting.date(in: "On the 3rd of May.") != nil, "\(String(describing: Meeting.date(in: "Send it by the 3rd.")))")
    let twoPeople = Meeting.check(Meeting.Summary(todos: [Meeting.ToDo(who: "Me", task: "Send the contract to legal.", at: 1), Meeting.ToDo(who: "Person 2", task: "Review the contract with legal.", at: 5)]),
                                  transcript: "[00:01] Me: I'll send the contract to legal.\n\n[00:05] Person 2: I'll review the contract with legal.")
    check("review.twoPeople", twoPeople.summary.todos.count == 2, "\(twoPeople.summary.todos)")
    check("review.morningRoundTrip", Meeting.todoMark("Call them (critical, by the morning)") == ("Call them", "the morning", true))
    check("real.sweepMidSentence", Meeting.promises(in: Meeting.said("[07:54] Others: uh that's taking place on friday at 10 so i'll be able to find a lot give you kind of where we're headed.")).isEmpty
          && Meeting.promises(in: Meeting.said("[00:01] Others: Uh, so I'll send the list on Friday.")).map(\.task) == ["Send the list on Friday."])
    let longOpen = Array(repeating: "There are pieces here and pieces there but not one plan.", count: 5).joined(separator: " ")
    check("real.openItem", Meeting.openItem(longOpen) == nil && Meeting.openItem(longOpen + " Is the influencer list finalized? " + longOpen) == "Is the influencer list finalized?"
          && Meeting.openItem("How deep should we segment?") == "How deep should we segment?")
    check("real.monthThe", Meeting.date(in: "Our goal is to have it complete by June the 10th.") == "June the 10th")
    // Claude notes by default (D-1272): labels, the backup, the link, and deadlines nobody said.
    check("d1272.basicLabel", Meeting.summaryLabel.hasPrefix("*Basic notes, made on this Mac") && Meeting.isBasic(Meeting.summaryLabel)
          && Meeting.isBasic("*Written on this Mac by Apple's model. Check it against the transcript.*") && !Meeting.isBasic(Meeting.betterLabel("Claude")))
    let fb = Meeting.fallbackLabel("Claude didn't answer within 5 minutes. Try again later.")
    check("d1272.fallbackLabel", fb == "*Basic notes, made on this Mac by Apple's model, because Claude didn't write them this time: Claude didn't answer within 5 minutes. Try again later. Check them against the transcript.*"
          && Meeting.isBasic(fb) && Meeting.fallbackLabel("").contains("this time. Check"), fb)
    let fbSection = Meeting.summaryMarkdown(Meeting.Checked(summary: Meeting.Summary(overview: "A call.")), transcript: tx, label: fb)
    let fbFile = Meeting.placing(fbSection, in: "# Meeting notes, x\n\n## Transcript\n\n" + tx + "\n")
    check("d1272.fallbackPlaced", fbFile.contains("## Summary\n\n" + fb) && Meeting.placingBetter(Meeting.summaryMarkdown(Meeting.Checked(summary: Meeting.Summary(overview: "Better.")), transcript: tx, label: Meeting.betterLabel("Claude")), in: fbFile).contains(Meeting.freeHeading + "\n\n" + fb))
    let unsaid = Meeting.said("[01:10] Me: I'll send the revised budget deck to Priya.\n\n[01:20] Others: Great.")
    check("d1272.unsaidDate", Meeting.withoutUnsaidDates("Send the revised budget deck to Priya by this afternoon.", around: 0, in: unsaid) == "Send the revised budget deck to Priya."
          && Meeting.withoutUnsaidDates("Send the deck by Friday, with the numbers.", around: 0, in: unsaid) == "Send the deck, with the numbers."
          && Meeting.withoutUnsaidDates("Send the deck by Friday.", around: 0, in: Meeting.said("[00:01] Me: I'll send the deck by Friday.")) == "Send the deck by Friday."
          && Meeting.withoutUnsaidDates("Send the deck.", around: 0, in: unsaid) == "Send the deck.", Meeting.withoutUnsaidDates("Send the deck by Friday, with the numbers.", around: 0, in: unsaid))
    let unsaidCk = Meeting.check(Meeting.Summary(todos: [Meeting.ToDo(who: "Me", task: "Send the revised budget deck to Priya by this afternoon.", at: 70)]), transcript: "[01:10] Me: I'll send the revised budget deck to Priya.")
    check("d1272.unsaidDateChecked", unsaidCk.summary.todos.first.map { $0.task == "Send the revised budget deck to Priya." && $0.when == nil && !$0.critical } == true, "\(unsaidCk.summary.todos)")
    let basicPage = AfterCallPage.read("# Meeting notes, x\n\n" + fbSection + "\n## Transcript\n\n" + tx + "\n")
    let basicHTML = AfterCallPage.html(basicPage, sender: "", audio: false)
    check("d1272.pageBasic", basicPage.basic && basicHTML.contains("data-act=\"better\">Get better notes") && basicHTML.contains("because Claude didn&#39;t write them this time")
          && !basicHTML.contains("Check them against"), basicPage.byline ?? "nil")
    let claudePage = AfterCallPage.read("# Meeting notes, x\n\n" + Meeting.summaryMarkdown(Meeting.Checked(summary: Meeting.Summary(overview: "A call.")), transcript: tx, label: Meeting.betterLabel("Claude")) + "\n## Transcript\n\n" + tx + "\n")
    check("d1272.pageClaude", !claudePage.basic && claudePage.byline == "Written by Claude (your account)." && !AfterCallPage.html(claudePage, sender: "", audio: false).contains("Get better notes"), claudePage.byline ?? "nil")
    // From the second review: dates that name something, or that someone said, are never taken out.
    let near = Meeting.said("[00:01] Me: Let's grow repeat sales by the third quarter, prep for the board meeting, the weekly numbers, the early shift, and send it tomorrow.")
    let keep = ["Grow repeat sales by the 3rd quarter.", "Prep the deck for Friday's board meeting.", "Review this week's numbers with Sam.",
                "Brief the morning shift on the new layout.", "Book the Sunday Times ad.", "Send it by tomorrow morning.", "Send Priya the notes from the May 12 workshop."]
    let kept = keep.map { Meeting.withoutUnsaidDates($0, around: 0, in: near) }
    check("review2.datesKept", kept == keep, "\(zip(keep, kept).filter { $0 != $1 })")
    check("review2.deadlineStillOut", Meeting.withoutUnsaidDates("Send the deck by Friday.", around: 0, in: near) == "Send the deck."
          && Meeting.withoutUnsaidDates("Send the deck on Monday, then call Sam.", around: 0, in: near) == "Send the deck, then call Sam.")
    // From the Nov 6 regrade: a deadline said about something else, and names guessed from the topic.
    let julian = Meeting.said("[55:48] Others: I did talk to my friend Nancy. But I talked to Nancy this afternoon and she said her nephew is Julian, the ag director.\n\n[56:35] Others: His aunt feels exposed as it is. I'll talk to Julian and see.")
    check("regrade.deadlineOtherTopic", Meeting.deadline(around: 0, in: julian, task: "Talk to Julian.") == nil && Meeting.deadline(around: 1, in: julian, task: "Talk to Julian.") == nil)
    let jc = Meeting.check(Meeting.Summary(todos: [Meeting.ToDo(who: "Joe", task: "Talk to Julian, the ag director.", at: 3348),
                                                   Meeting.ToDo(who: "Joe", task: "Raise the alcohol in the barns at the board meeting.", at: 3513)]),
                           transcript: "[03:11] Others: So we've taken your feedback, Joe.\n\n[55:48] Others: I talked to Nancy this afternoon and she said her nephew is Julian, the ag director. I'll talk to Julian.\n\n[58:33] Others: The board meeting should hear about the alcohol in the barns, can someone raise it.\n")
    check("regrade.noGuessedNames", jc.summary.todos.allSatisfy { $0.who != "Joe" } && jc.summary.todos.allSatisfy { $0.when != "this afternoon" }, "\(jc.summary.todos)")
    let barns = Meeting.said("[58:33] Others: Okay. I'm just going to raise that at the board meeting. Joe told us to model it out we're gonna move please don't do that okay i'll see you guys tomorrow then")
    check("regrade.otherPromise", Meeting.deadline(around: 0, in: barns, task: "Raise the alcohol in the barns at the board meeting.") == nil)
    check("regrade.nameSaidKept", Meeting.ownerSaid("Sam", around: 0, in: Meeting.said("[00:01] Me: Sam, can you send the deck?")) == "Sam"
          && Meeting.ownerSaid("Sam", around: 0, in: Meeting.said("[00:01] Me: Can you send the deck?")) == "Not clear"
          && Meeting.ownerSaid("Lena", around: 0, in: Meeting.said("[00:01] Lena: I'll order it.")) == "Lena")
    check("review.byEmail", Meeting.todoMark("Send the file (by email)") == ("Send the file (by email)", nil, false) && Meeting.todoMark("Send it (by Friday)") == ("Send it", "Friday", false))
    check("steps.markPlain", Meeting.todoMark("Book the room (10:30)") == ("Book the room (10:30)", nil, false) && Meeting.todoMark("Ship it (critical)") == ("Ship it", nil, true))
    let renamed = Meeting.renaming([(Speaker(rawValue: "Marco"), "Marc")], in: "## Summary\n\n### To-dos\n\n- " + Meeting.todoLine(rc.summary.todos[0]) + " [16:00]\n\n## Transcript\n\n" + room)
    check("steps.renameKeepsMarks", renamed?.contains("- Marc: Redraw the island 15 cm shorter.") == true)
    let mail = Meeting.followUp(rc.summary, meeting: "the kitchen walk-through", sender: "Cedric", people: ["Marco", "Lena"])
    check("steps.emailSubject", mail.subject == "Next steps from the kitchen walk-through")
    check("steps.emailBody", mail.body.hasPrefix("Hi Marco and Lena,") && mail.body.contains("- Cedric: Call the city and ask for the first open inspection slot, by tomorrow morning")
          && mail.body.contains("Decided\n- The island gets 15 cm shorter") && mail.body.contains("Still open\n- Does the permit cover the hood fan?")
          && mail.body.hasSuffix("Cedric\n") && !mail.body.contains("—"), mail.body)
    check("steps.emailEmpty", Meeting.followUp(Meeting.Summary(), meeting: "x", sender: "", people: []).body.contains("Hi all,\n\nHere's what we agreed"))

    // From the first real run: one turn holds several promises, a model names the wrong owner, and says things twice.
    let turn = Meeting.said("[03:26] Person 2: The wood is warmer. I'll sit with it for a few days. So I'll send the drawing tonight, and you'll hear from me. And I'll call them in the morning.\n\n[03:40] Person 3: I'll order Monday.")
    check("steps.sentenceDate", Meeting.deadline(around: 0, in: turn, task: "Call them in the morning.") == "the morning"
          && Meeting.deadline(around: 0, in: turn, task: "Send the drawing tonight.") == "tonight"
          && Meeting.deadline(around: 0, in: turn, task: "Sit with the wood for a few days.") == nil)
    check("steps.promiser", Meeting.promiser(around: 0, in: turn, task: "Send the drawing tonight.") == "Person 2"
          && Meeting.promiser(around: 0, in: Meeting.said("[00:01] Person 3: Can you send the drawing?"), task: "Send the drawing.") == nil)
    let twice = Meeting.check(Meeting.Summary(todos: [Meeting.ToDo(who: "Me", task: "Send the drawing tonight.", at: 206),
                                                      Meeting.ToDo(who: "Me", task: "Send the drawing tonight, and you'll hear from me.", at: 206),
                                                      Meeting.ToDo(who: "Me", task: "Order the cabinets Monday.", at: 220)]), transcript: Meeting.transcript(inFile: "## Transcript\n\n[03:26] Person 2: The wood is warmer. I'll sit with it for a few days. So I'll send the drawing tonight, and you'll hear from me. And I'll call them in the morning.\n\n[03:40] Person 3: I'll order the cabinets Monday.\n"))
    check("steps.distinctOwner", twice.summary.todos.map(\.who) == ["Person 2", "Person 3", "Person 2"] && twice.summary.todos[0].when == "tonight" && twice.summary.todos[0].critical
          && twice.summary.todos[2].task == "Call them in the morning." && twice.summary.todos[2].critical, "\(twice.summary.todos)")

    let missed = Meeting.promises(in: Meeting.said("[01:01] Person 2: I'll redraw it tonight and send it over. Perfect.\n\n[01:42] Person 3: Then I'll place the order Monday morning, as soon as Marco's drawing is in.\n\n[03:22] Person 3: They're in the car. I'll bring them in.\n\n[03:30] Me: Will I see you Friday?"))
    check("steps.promises", missed.map(\.task) == ["Redraw it tonight and send it over.", "Place the order Monday morning, as soon as Marco's drawing is in."]
          && missed.map(\.who) == ["Person 2", "Person 3"] && missed[0].critical && !missed[1].critical && missed[1].when == "Monday morning", "\(missed)")
    // The After the call page (D-1126): built from the file, nothing said can become markup.
    let notesFile = "# Meeting notes, Monday 2 November 2026\n\n- Date: 2026-11-02\n- Started: 10:05\n- Length: 34 min\n\n" + rmd + "\n## Transcript\n\n" + room
        + "\n\n[18:00] Person 3: <script>alert('x')</script> & \"quotes\"\n"
    let pn = AfterCallPage.read(notesFile)
    check("page.read", pn.title == "Meeting notes, Monday 2 November 2026" && pn.started == "10:05" && pn.length == "34 min"
          && pn.summary?.todos.count == 3 && pn.unnamed && pn.people == ["Lena", "Marco"], "\(pn.people) \(String(describing: pn.summary?.todos.count))")
    let ph = AfterCallPage.html(pn, sender: "Cedric", audio: true)
    check("page.escaped", !ph.contains("<script>alert") && ph.contains("&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp; &quot;quotes&quot;"))
    check("page.oneScript", ph.components(separatedBy: "<script>").count == 2 && ph.contains("default-src 'none'"))
    check("page.actionsFirst", ph.range(of: "What has to happen")!.lowerBound < ph.range(of: "Follow-up email")!.lowerBound
          && ph.range(of: "Follow-up email")!.lowerBound < ph.range(of: "Go deeper")!.lowerBound)
    check("page.critical", ph.contains("r-critical\">Critical</div><div class=\"act-what\">Call the city") && !ph.contains("Due tomorrow morning") && ph.contains("Tomorrow morning") && ph.contains("Hear it · 15:09"))
    check("page.sound", ph.contains("data-track=\"me\" data-from=\"908.7\" data-to=\"915.0\""), "sound")
    check("page.noAudio", AfterCallPage.html(pn, sender: "Cedric", audio: false).contains("Show what was said · 15:09"))
    check("page.names", ph.contains("data-act=\"names\">Name the voices"))
    check("page.noSummary", AfterCallPage.html(AfterCallPage.read("# Meeting notes, x\n\n" + Meeting.noSummary("Apple Intelligence is off.") + "\n## Transcript\n\n[00:01] Me: Hi there.\n"), sender: "", audio: false)
          .contains("No summary was written. Apple Intelligence is off.") )

    // Cutting long audio: at the quietest moment before the target, never past it.
    var wave = [Float](repeating: 0.5, count: 16_000 * 10)
    for i in (16_000 * 7)..<(16_000 * 7 + 4_800) { wave[i] = 0 }
    let cut = Meeting.cutPoint(wave, target: 16_000 * 9, search: 16_000 * 5)
    check("meeting.cutQuiet", cut >= 16_000 * 7 && cut <= 16_000 * 7 + 4_800, "\(cut)")
    check("meeting.cutEnd", Meeting.cutPoint(wave, target: wave.count + 10, search: 100) == wave.count)
    check("meeting.cutNeverAfter", Meeting.cutPoint([Float](repeating: 0.5, count: 1000), target: 900, search: 500) <= 900)

    // Gaps with no line in them, for asking Whisper again, and how much of a stretch sounds like talk.
    let lined = [MeetingSegment(start: 2, end: 10, text: "a"), MeetingSegment(start: 11, end: 20, text: "b"), MeetingSegment(start: 45, end: 50, text: "c")]
    let gaps = Meeting.gaps(lined, length: 120, minimum: 6)
    check("meeting.gaps", gaps.count == 2 && abs(gaps[0].lowerBound - 20.2) < 0.001 && abs(gaps[0].upperBound - 44.8) < 0.001 && abs(gaps[1].upperBound - 119.8) < 0.001, "\(gaps)")
    check("meeting.gapsNone", Meeting.gaps([], length: 4, minimum: 6).isEmpty && Meeting.gaps([], length: 30, minimum: 6).count == 1)
    check("meeting.gapsOverlap", Meeting.gaps([MeetingSegment(start: 0, end: 30, text: "a"), MeetingSegment(start: 5, end: 8, text: "b"), MeetingSegment(start: 31, end: 40, text: "c")], length: 40, minimum: 6).isEmpty)
    var talk = [Float](repeating: 0, count: 16_000 * 4)
    for i in 0..<(16_000 * 2) { talk[i] = i % 2 == 0 ? 0.05 : -0.05 }
    check("meeting.talkSeconds", abs(Meeting.talkSeconds(talk[...]) - 2) < 0.05 && Meeting.talkSeconds(talk[(16_000 * 2)...]) == 0)

    // Folders that may sync to iCloud are flagged; the default is not.
    check("meeting.syncDefault", !Meeting.mightSync("/Users/a/Redpen Meetings", home: "/Users/a"))
    check("meeting.syncDocuments", Meeting.mightSync("/Users/a/Documents/Notes", home: "/Users/a") && Meeting.mightSync("/Users/a/Desktop", home: "/Users/a/"))
    check("meeting.syncLookalike", !Meeting.mightSync("/Users/a/Documents2", home: "/Users/a"))

    // The manifest survives a round trip, so a crashed meeting can be finished.
    var mf = MeetingManifest(started: start); mf.meOffset = -0.6; mf.othersOffset = 0.12
    let back = try? JSONDecoder().decode(MeetingManifest.self, from: JSONEncoder().encode(mf))
    check("meeting.manifest", back == mf && MeetingManifest.samples(bytes: 32_000) == 16_000)
}

// Better summary on this Mac (D-1010): which writer each Mac gets, the pinned download, the hash check, and its
// summary's place in the notes.
do {
    let gib: UInt64 = 1 << 30
    check("writer.8GB", LocalWriter.forMac(memory: 8 * gib) == nil)
    check("writer.justUnder16", LocalWriter.forMac(memory: 16 * gib - 1) == nil)
    check("writer.16GB", LocalWriter.forMac(memory: 16 * gib) == .gemma)
    check("writer.32GB", LocalWriter.forMac(memory: 32 * gib) == .gemma)
    check("writer.36GB", LocalWriter.forMac(memory: 36 * gib) == .gemma)
    check("writer.48GB", LocalWriter.forMac(memory: 48 * gib) == .qwen)
    check("writer.128GB", LocalWriter.forMac(memory: 128 * gib) == .qwen)
    check("writer.sizes", LocalWriter.qwen.sizeText == "20.4 GB" && LocalWriter.gemma.sizeText == "5.2 GB", "\(LocalWriter.qwen.sizeText) \(LocalWriter.gemma.sizeText)")
    check("writer.gb", LocalWriter.gb(850_000_000) == "850 MB" && LocalWriter.gb(1_250_000_000) == "1.2 GB")
    check("writer.progress", LocalWriter.gemma.progressText(done: 3_100_000_000) == "3.1 of 5.2 GB" && LocalWriter.gemma.progressText(done: 9_000_000_000) == "5.2 of 5.2 GB")
    let hex40 = try! NSRegularExpression(pattern: "^[0-9a-f]{40}$")
    for w in LocalWriter.all {
        check("writer.\(w.id).pinned", hex40.firstMatch(in: w.revision, range: NSRange(location: 0, length: 40)) != nil)
        check("writer.\(w.id).hashed", w.files.allSatisfy { ($0.sha256 == nil) != ($0.gitSHA1 == nil) && ($0.sha256?.count ?? 64) == 64 && ($0.gitSHA1?.count ?? 40) == 40 })
        check("writer.\(w.id).needed", ["config.json", "tokenizer.json", "tokenizer_config.json", "chat_template.jinja"].allSatisfy { n in w.files.contains { $0.name == n } }
              && !w.files.contains { $0.name == "README.md" || $0.name.hasPrefix(".") })
        let u = w.url(w.files[0])
        check("writer.\(w.id).url", u.scheme == "https" && u.host == "huggingface.co" && u.path == "/\(w.repo)/resolve/\(w.revision)/\(w.files[0].name)", u.absoluteString)
        check("writer.\(w.id).named", LocalWriter.named(w.id) == w)
    }
    check("writer.hubFolder", LocalWriter.gemma.cacheSnapshot(hub: URL(fileURLWithPath: "/h")).path
          == "/h/models--mlx-community--gemma-4-e4b-it-4bit/snapshots/475b9088d29754a3379866cf5aeb6b41acd313c2")
    check("writer.ownFolder", LocalWriter.qwen.ownFolder(models: URL(fileURLWithPath: "/m")).path
          == "/m/notes-writers/mlx-community/Qwen3.6-35B-A3B-4bit/38740b847e4cb78f352aba30aa41c76e08e6eb46")

    // The hash check: "hello\n" as git stores it, and its SHA-256; one byte off or a wrong size fails.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rv-writer-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let hello = dir.appendingPathComponent("hello.txt")
    try? Data("hello\n".utf8).write(to: hello)
    check("writer.matchGit", LocalWriter.matches(.init("hello.txt", 6, git: "ce013625030ba8dba906f756967f9e9ca394464a"), at: hello))
    check("writer.matchSHA256", LocalWriter.matches(.init("hello.txt", 6, sha256: "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"), at: hello))
    check("writer.wrongHash", !LocalWriter.matches(.init("hello.txt", 6, sha256: String(repeating: "0", count: 64)), at: hello))
    check("writer.wrongSize", !LocalWriter.matches(.init("hello.txt", 7, git: "ce013625030ba8dba906f756967f9e9ca394464a"), at: hello))
    check("writer.noHashNeverMatches", !LocalWriter.matches(.init("hello.txt", 6), at: hello))
    check("writer.missing", !LocalWriter.matches(.init("gone.txt", 6, git: "ce013625030ba8dba906f756967f9e9ca394464a"), at: dir.appendingPathComponent("gone.txt")))
    check("writer.cancelledCheck", !LocalWriter.matches(.init("hello.txt", 6, git: "ce013625030ba8dba906f756967f9e9ca394464a"), at: hello, cancelled: { true }))
    // A whole writer by sizes alone, links followed as in Hugging Face's cache.
    let one = LocalWriter(id: "t", name: "T", repo: "a/b", revision: String(repeating: "a", count: 40),
                          files: [.init("hello.txt", 6, git: "ce013625030ba8dba906f756967f9e9ca394464a")], minimumGB: 1)
    let linked = dir.appendingPathComponent("linked", isDirectory: true)
    try? FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
    check("writer.incomplete", !one.complete(in: linked))
    try? FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("hello.txt"), withDestinationURL: hello)
    check("writer.completeThroughLink", one.complete(in: linked) && LocalWriter.matches(one.files[0], at: linked.appendingPathComponent("hello.txt")))
    try? FileManager.default.removeItem(at: dir)

    // Thinking is never part of the notes.
    check("writer.answerPlain", LocalWriter.answer("\n### Overview\nA call.\n") == "### Overview\nA call.")
    check("writer.answerThink", LocalWriter.answer("<think>\nhmm\n</think>\n\n### Overview\nA call.") == "### Overview\nA call.")
    check("writer.answerOpenThink", LocalWriter.answer("plan first\n</think>\n### Overview\nA call.") == "### Overview\nA call.")

    // Its summary goes on top like Claude's, replaces itself or Claude's, and keeps Apple's below.
    let notes = "# Meeting\n\n## Transcript\n\n[00:01] Me: Hello.\n"
    let free = "## Summary\n\n" + Meeting.summaryLabel + "\n\n### Overview\n\nFree.\n"
    let mine = "## Summary\n\n" + Meeting.localLabel("Gemma 4 small") + "\n\n### Overview\n\nLocal.\n"
    let claude = "## Summary\n\n" + Meeting.betterLabel("Claude") + "\n\n### Overview\n\nBetter.\n"
    let both = Meeting.placingBetter(mine, in: Meeting.placing(free, in: notes))
    let iL = both.range(of: "Local.")!.lowerBound, iF = both.range(of: Meeting.freeHeading)!.lowerBound, iT = both.range(of: "## Transcript")!.lowerBound
    check("writer.summaryOnTop", iL < iF && iF < iT && both.components(separatedBy: "\n## Summary\n").count == 2)
    check("writer.summaryAgain", Meeting.placingBetter(mine, in: both) == both)
    check("writer.freeAfterLocal", Meeting.placing(free, in: both) == both)
    let swapped = Meeting.placingBetter(claude, in: both)
    check("writer.claudeReplacesLocal", swapped.contains("Better.") && !swapped.contains("Local.") && swapped.contains("Free."))
    check("writer.labelSaysMac", Meeting.localLabel("Qwen3.6 35B").contains("on this Mac") && !Meeting.localLabel("Qwen3.6 35B").contains("your account"))

    // Your own command's summary (D-1012) is a better one too: a second one replaces it, Apple's stays below.
    let cmd = "## Summary\n\n" + Meeting.commandLabel + "\n\n### Overview\n\nCommand.\n"
    let withCmd = Meeting.placingBetter(cmd, in: Meeting.placing(free, in: notes))
    check("command.summaryAgain", Meeting.placingBetter(cmd, in: withCmd) == withCmd)
    check("command.freeAfter", Meeting.placing(free, in: withCmd) == withCmd)
    let overCmd = Meeting.placingBetter(claude, in: withCmd)
    check("command.claudeReplaces", overCmd.contains("Better.") && !overCmd.contains("Command.") && overCmd.contains("Free."))
}

// Voices in the room (D-1034).
do {
    check("room.meClear", Meeting.whichIsMe([0.724, -0.129, -0.053]) == 0)
    check("room.meSecondMeeting", Meeting.whichIsMe([0.184, -0.050, 0.810, -0.085]) == 2)
    check("room.meTooFar", Meeting.whichIsMe([0.42, 0.1]) == nil)
    check("room.meTooClose", Meeting.whichIsMe([0.7, 0.55]) == nil)
    check("room.meEmpty", Meeting.whichIsMe([]) == nil)
    check("room.oneVoiceIsMe", Meeting.roomNames(count: 1, me: nil) == [.me])
    check("room.namesWithMe", Meeting.roomNames(count: 3, me: 1).map(\.rawValue) == ["Person 2", "Me", "Person 3"])
    check("room.namesWithoutMe", Meeting.roomNames(count: 2, me: nil).map(\.rawValue) == ["Person 1", "Person 2"])
    let segs = [MeetingSegment(start: 0, end: 4, text: "a"), MeetingSegment(start: 4, end: 10, text: "b"),
                MeetingSegment(start: 11, end: 12, text: "c"), MeetingSegment(start: 30, end: 31, text: "d")]
    let turns = [RoomTurn(start: 0, end: 5, voice: 0), RoomTurn(start: 5, end: 10.5, voice: 1)]
    let names = Meeting.roomNames(count: 2, me: 0)
    check("room.lineMostHeard", Meeting.voices(for: segs, turns: turns, names: names).map(\.rawValue) == ["Me", "Person 2", "Person 2", "Me"])
    let lines = Meeting.merge(me: segs, others: [MeetingSegment(start: 4, end: 5, text: "o")], voices: Meeting.voices(for: segs, turns: turns, names: names))
    check("room.mergeLabels", lines.map(\.markdown) == ["[00:00] Me: a", "[00:04] Others: o", "[00:04] Person 2: b", "[00:11] Person 2: c", "[00:30] Me: d"])
    let said = Meeting.said("[00:04] Person 2: I'll send the list.\n[00:09] Monica: Thanks: really.\n[00:10] Others: Fine.")
    check("room.saidPerson", said.map(\.speaker) == ["Person 2", "Monica", "Others"] && said[1].text == "Thanks: really.")
    let t = "[00:04] Person 2: I'll send the list.\n[00:06] Me: Good."
    check("room.ownerPerson", Meeting.who("Person 2", transcript: t) == "Person 2")
    check("room.ownerMadeUp", Meeting.who("Person 3", transcript: t) == "Not clear")
    check("room.ownerBracket", Meeting.who("Rima (VMC)", transcript: "[00:01] Others: Rima VMC will do it") == "Rima (VMC)")
    let file = "# Notes\n\n## Summary\n\n### To-dos\n\n- Person 2: send the list. [00:04]\n- Person 22: not this one.\n\n## Transcript\n\n[00:04] Person 2: I'll send the list.\n\n[00:08] Person 22: Hi.\n"
    let renamed = Meeting.renaming(.person(2), to: "Monica", in: file) ?? ""
    check("room.renameLines", renamed.contains("] Monica: I'll send") && renamed.contains("- Monica: send the list.") && renamed.contains("] Person 22: Hi.") && renamed.contains("- Person 22: not"))
    check("room.renameRefused", Meeting.renaming(.person(2), to: "Others", in: file) == nil && Meeting.renaming(.person(2), to: " ", in: file) == nil
          && Meeting.renaming(.person(2), to: "A: B", in: file) == nil)
    let swapped = Meeting.renaming([(.person(1), "Person 2"), (.person(2), "Monica")], in: "[00:01] Person 1: a\n[00:02] Person 2: b\n") ?? ""
    check("room.renameSwap", swapped == "[00:01] Person 2: a\n[00:02] Monica: b\n")
    check("room.renameMe", Meeting.renaming([(.person(1), "Me")], in: "[00:01] Person 1: a\n") == "[00:01] Me: a\n")
    let spoken = "Me is your own voice and Person 2 is another voice on your microphone, told apart on this Mac. To give them names, choose Name the voices in the menu.\n\n## Summary\n\n### Key points\n\n- Me said the plan is set. [00:10]\n\n### To-dos\n\n- Me: send it. [00:12]\n\n## Transcript\n\n[00:10] Person 2: Me too, and Sam agrees.\n\n[00:12] Me: I'll send it.\n"
    let named = Meeting.renaming([(.me, "Cedric"), (.person(2), "Monica")], in: spoken) ?? ""
    check("room.renameOnlyLabels", named.contains("] Monica: Me too, and Sam agrees.") && named.contains("] Cedric: I'll send it.")
          && named.contains("- Cedric: send it.") && named.contains("- Me said the plan is set."))
    check("room.renameNote", named.hasPrefix("Monica and Cedric are the voices on your microphone"))
    check("room.nameRules", Meeting.canName("dr Patel") && Meeting.canName("王伟") && Meeting.canName("Jean Paul de la Croix")
          && !Meeting.canName("A: B") && !Meeting.canName("**Bold**") && !Meeting.canName("Others"))
    check("room.namedLineRead", Meeting.said("[00:01] dr Patel: Fine.\n[00:02] 王伟: Yes.").map(\.speaker) == ["dr Patel", "王伟"])
    check("room.madeUpPerson", Meeting.who("Person 3", transcript: "[00:01] Person 2: I'll call 3 people.") == "Not clear")
    check("room.voicesInFile", Meeting.voices(inFile: file).map(\.rawValue) == ["Person 2", "Person 22"])
    check("room.note", Meeting.roomNote(names)?.hasPrefix("Me is your own voice and Person 2 is another voice") == true && Meeting.roomNote([.me]) == nil)
    check("room.noteNoMe", Meeting.roomNote(Meeting.roomNames(count: 3, me: nil))?.hasPrefix("Person 1, Person 2 and Person 3 are the voices") == true)
    // An item naming a voice ("Person 3 said...") is checked on what was said, not on the label's number.
    let lab = "[07:25] Person 3: The list doesn't need to be final, a range of twenty names and a budget is enough."
    let point = Meeting.Summary(overview: "", points: [Meeting.Cited("Person 3 said the list need not be final; a range of twenty names and a budget is enough.", at: 445)], decisions: [], todos: [])
    check("room.labelNotANumber", Meeting.check(point, transcript: lab).summary.points.count == 1)
    let meet = Meeting.Summary(overview: "", points: [Meeting.Cited("Meeting moved to June 12.", at: 1)], decisions: [], todos: [])
    check("room.labelWholeWord", Meeting.check(meet, transcript: "[00:01] Me: The meeting moved to June 12.").summary.points.count == 1)
    // A to-do owned by Person 2 survives the check.
    let sum = Meeting.Summary(overview: "", points: [], decisions: [], todos: [Meeting.ToDo(who: "Person 2", task: "send the list", at: 4)])
    check("room.todoKept", Meeting.check(sum, transcript: t).summary.todos.first?.who == "Person 2")
}

// Words landed (D-1034): made-up log lines in the real formats, never real log content.
do {
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
    func at(_ day: Int, _ t: String) -> String { "2026-10-\(day)T\(t)Z" }
    func L(_ day: Int, _ t: String, _ m: String) -> String { at(day, t) + " " + m }
    func dictation(_ day: Int, _ t: String, words: Int, into app: String = "Secret Plans App", inserted: Bool) -> String {
        L(day, t, "dictation 4s, \(words) words, write 200ms, engine 1500ms, key up to done 2100ms, into \(app), inserted \(inserted)")
    }
    let iso = ISO8601DateFormatter()
    check("landed.time", WordsLanded.time(Substring(L(31, "08:57:20", "launched"))) == iso.date(from: "2026-10-31T08:57:20Z"))
    check("landed.timeLeap", WordsLanded.time("2028-02-29T23:59:59Z x") == iso.date(from: "2028-02-29T23:59:59Z"))
    check("landed.timeBad", WordsLanded.time("right Option, double tap true)") == nil && WordsLanded.time("2026-13-01T00:00:00Z x") == nil)
    check("landed.lineParse", WordsLanded.dictationLine("dictation 2s, 7 words, write 215ms, engine 1993ms, key up to done 2322ms, into T3 Code (Beta), inserted true")! == (7, true))
    check("landed.lineCommaApp", WordsLanded.dictationLine("dictation 2s, 7 words, write 1ms, into A, inserted true, B, inserted false")! == (7, false))

    // One of each ending, in order. Two on Oct 29, the rest on Oct 31.
    func log(app: String = "Secret Plans App", file: String = "secret-recording.wav", mic: String = "Scarlett 2i2 4th Gen", why: String = "/Users/someone/Private/thing") -> String { [
        L(29, "10:00:00", "launched"),
        L(29, "10:00:05", "recording from \(mic)"),
        L(29, "10:00:09", "audio: 63344 frames (4.0s), peak 0.344"),
        L(29, "10:00:10", "insert: focus AXTextArea, text"),
        dictation(29, "10:00:10", words: 9, into: app, inserted: true),                                  // landed
        L(29, "10:01:00", "audio: 63344 frames (4.0s), peak 0.344"),
        L(29, "10:01:01", "insert: you typed or clicked, stopped"),
        dictation(29, "10:01:01", words: 5, into: app, inserted: false),                                 // kept, typing stopped
        L(31, "06:00:00", "media: apps [\(app)], loudness 0.0504, paused true"),
        // A draft line from while you talked, before this ending's audio line, doesn't count against it.
        L(31, "06:00:01", "insert: draft typing not confirmed, kept for Paste last"),
        L(31, "06:00:02", "audio: 63344 frames (4.0s), peak 0.344"),
        L(31, "06:00:03", "draft: first words 900ms after you started talking, 3 runs, checks 3, changed 1 (2 words), checked text confirmed, ending finished 800ms after release"),
        dictation(31, "06:00:03", words: 12, into: app, inserted: true),                                 // landed
        L(31, "06:01:00", "audio: 63344 frames (4.0s), peak 0.344"),
        L(31, "06:01:01", "insert: typing not seen in the box after a second"),
        dictation(31, "06:01:01", words: 6, into: app, inserted: true),                                  // kept, typing not seen
        L(31, "06:02:00", "audio: 63344 frames (4.0s), peak 0.344"),
        L(31, "06:02:01", "insert: the box you started in was sent after Voice typed into it, nothing typed again, kept for paste"),
        L(31, "06:02:01", "draft: first words 900ms after you started talking, 3 runs, checks 3, changed 1 (2 words), checked text kept for Paste last, ending finished 800ms after release"),
        dictation(31, "06:02:01", words: 30, into: app, inserted: false),                                // kept, box was sent
        L(31, "06:03:00", "audio: 63344 frames (4.0s), peak 0.344"),
        L(31, "06:03:01", "insert: cursor not in a text box (AXWebArea), waiting for a click"),
        dictation(31, "06:03:01", words: 8, into: app, inserted: false),
        L(31, "06:03:20", "insert: pasted after a click into AXTextArea, true"),                       // landed after a click
        L(31, "06:04:00", "audio: 63344 frames (4.0s), peak 0.344"),
        L(31, "06:04:01", "insert: cursor not in a text box (AXGroup), waiting for a click"),
        dictation(31, "06:04:01", words: 8, into: app, inserted: false),
        L(31, "06:14:02", "insert: nobody clicked a text box in 10 minutes, kept for paste"),            // kept
        L(31, "06:15:00", "audio: 63344 frames (4.0s), peak 0.344"),
        L(31, "06:15:01", "engine: the ending failed, 3 pieces kept"),
        L(31, "06:15:02", "engine finish: waited 0ms for the stream, ending 1202ms, 3 pieces"),
        dictation(31, "06:15:02", words: 80, into: app, inserted: true),                                 // lost, ending failed
        L(31, "06:16:00", "audio: 63344 frames (4.0s), peak 0.344"),
        L(31, "06:16:09", "engine: instant stopped answering after 5s, loading a fresh one"),
        dictation(31, "06:16:09", words: 0, into: app, inserted: false),                                 // lost, whole
        L(31, "06:17:00", "audio: 63344 frames (4.0s), peak 0.344"),
        L(31, "06:17:01", "finish failed: \(why)"),
        dictation(31, "06:17:01", words: 0, into: app, inserted: false),                                 // lost, engine failed
        L(31, "06:18:00", "audio: 63344 frames (4.0s), peak 0.001"),
        dictation(31, "06:18:00", words: 0, into: app, inserted: false),                                 // empty press, not counted
        L(31, "06:18:30", "cancelled: quick tap"),
        L(31, "06:18:40", "cancelled: Escape, nothing left in the box"),
        L(31, "06:18:50", "cancelled: another key while holding"),
        L(31, "06:19:00", "audio: 63344 frames (4.0s), peak 0.344"),
        dictation(31, "06:19:00", words: 4, into: app, inserted: false),                                 // kept, not typed
        L(31, "06:20:00", "watchdog: the app ended without quitting, reopening"),
        L(31, "07:30:00", "launched 0.12.2 (14), built 2026-10-31T07:00:00Z"),
        L(31, "07:40:00", "audio: 63344 frames (4.0s), peak 0.344"),
        L(31, "07:40:01", "insert: cursor not in a text box (AXWebArea) and a new press began, kept for paste"),
        dictation(31, "07:40:01", words: 3, into: app, inserted: false),                                 // kept, a new press
        L(31, "08:00:00", "launched 0.12.2 (14), built 2026-10-31T07:00:00Z"),
        L(31, "08:10:00", "audio: 63344 frames (4.0s), peak 0.344"),
        L(31, "08:10:01", "insert: cursor not in a text box (AXWebArea), waiting for a click"),
        dictation(31, "08:10:01", words: 5, into: app, inserted: false),
        L(31, "08:10:05", "insert: typing not seen in the box after a second"),
        L(31, "08:10:05", "insert: pasted after a click into AXTextArea, true"),                       // kept, unseen after click
        L(31, "08:11:00", "audio: 63344 frames (4.0s), peak 0.344"),
        L(31, "08:11:01", "insert: cursor not in a text box (AXWebArea), waiting for a click"),
        dictation(31, "08:11:01", words: 5, into: app, inserted: false),                                 // kept, quit while waiting
        L(31, "08:12:00", "paste: shortcut keys released, posting Command-V; value readable true, cursor readable true"),
        L(31, "08:12:01", "paste: target changed; clipboard kept for Command-V"),
        L(31, "08:12:02", "draft blocked: hardware click (draft)"),
        L(31, "08:12:03", "draft blocked: \(app) (draft)"),
        L(31, "08:12:04", "meeting: could not start, NSOSStatusErrorDomain -50"),
        L(31, "08:12:05", "meeting: notes failed, \(why) 4"),
        L(31, "08:12:06", "meeting: write failed on \(file), NSCocoaErrorDomain 640"),
        L(31, "08:12:07", "meeting: summary failed (GenerationError, FoundationModels.LanguageModelSession.GenerationError 2)"),
        L(31, "08:12:08", "meeting: better summary failed (\(app)) after 3s"),
        L(31, "08:12:09", "test: saved \(file), 4s"),
        L(31, "08:57:20", "launched 0.12.3 (15), built 2026-10-31T08:50:00Z"),
        L(31, "09:00:00", "audio: 63344 frames (4.0s), peak 0.344"),
        dictation(31, "09:00:00", words: 233, into: app, inserted: true),                               // landed
    ].joined(separator: "\n") + "\n" }

    let r = WordsLanded.read(log())
    let outcomes = r.dictations.map { "\($0.outcome)" + ($0.why.map { ":" + $0 } ?? "") }
    check("landed.outcomes", outcomes == [
        "landed", "kept:typing stopped", "landed", "kept:typing not seen", "kept:box was sent", "landed",
        "kept:no text box, nobody clicked one in 10 minutes", "lost:ending failed", "lost:engine stopped answering",
        "lost:engine failed", "kept:not typed", "kept:a new press began", "kept:no text box, typing not seen after the click",
        "kept:no text box, Voice quit or restarted", "landed",
    ], "\(outcomes)")
    check("landed.emptyPressNotCounted", r.dictations.count == 15)
    check("landed.escapeOnItsOwn", r.thrownAway.count == 1)
    let all = WordsLanded.tally(r)
    check("landed.tally", all == WordsLanded.Tally(landed: 4, kept: 8, lost: 3, thrownAway: 1), "\(all)")

    // Days on this Mac's calendar, today first; a day with nothing says so.
    let now = iso.date(from: "2026-10-31T12:00:00Z")!
    let table = WordsLanded.table(r, now: now, calendar: utc)
    check("landed.table7", table.count == 7)
    check("landed.today", table[0] == "Today: 3 of 13 landed in full, 7 kept for ⌃⌥V, 3 lost, 1 thrown away with Escape", table[0])
    check("landed.yesterday", table[1] == "Yesterday: no dictations", table[1])
    check("landed.older", table[2] == "Thu Oct 29: 1 of 2 landed in full, 1 kept for ⌃⌥V, 0 lost", table[2])
    check("landed.specLine", WordsLanded.line("Today", .init(landed: 46, kept: 2)) == "Today: 46 of 48 landed in full, 2 kept for ⌃⌥V, 0 lost")
    check("landed.onlyEscape", WordsLanded.line("Today", .init(thrownAway: 2)) == "Today: no dictations, 2 thrown away with Escape")

    // Since this build: the newest launch, back through launches naming the same build; old logs name none.
    check("landed.buildNew", WordsLanded.buildStarted(r) == iso.date(from: "2026-10-31T08:57:20Z"))
    let sameBuild = WordsLanded.read(log().replacingOccurrences(of: "0.12.3 (15), built 2026-10-31T08:50:00Z", with: "0.12.2 (14), built 2026-10-31T07:00:00Z"))
    check("landed.buildSameBack", WordsLanded.buildStarted(sameBuild) == iso.date(from: "2026-10-31T07:30:00Z"))
    let oldLog = WordsLanded.read(log().replacingOccurrences(of: #"launched [^\n]*"#, with: "launched", options: .regularExpression))
    check("landed.buildOldLog", WordsLanded.buildStarted(oldLog) == iso.date(from: "2026-10-31T08:57:20Z"))
    check("landed.since", WordsLanded.sinceLine(r, calendar: utc, utc: true) == "Since this build started, 2026-10-31 08:57 UTC: 1 of 1 landed in full (100%), 0 kept, 0 lost",
          WordsLanded.sinceLine(r, calendar: utc, utc: true) ?? "nil")
    check("landed.sinceNone", WordsLanded.sinceLine(WordsLanded.read(L(31, "08:00:00", "launched")), calendar: utc, utc: true)?.hasSuffix("no dictations yet") == true)
    check("landed.percentCap", WordsLanded.Tally(landed: 199, kept: 1).percent == 99 && WordsLanded.Tally(landed: 3).percent == 100
          && WordsLanded.Tally().percent == nil)
    check("landed.reasons", WordsLanded.reasonsLine(sameBuild, from: iso.date(from: "2026-10-31T07:00:00Z")!)
          == "Kept: a new press began (1), no text box, Voice quit or restarted (1), no text box, typing not seen after the click (1).",
          WordsLanded.reasonsLine(sameBuild, from: iso.date(from: "2026-10-31T07:00:00Z")!) ?? "nil")
    check("landed.summaryEnds", WordsLanded.summary(r, now: now, calendar: utc).last == "The log goes back to Oct 29 10:00 AM.")
    check("landed.emptyLog", WordsLanded.read("").dictations.isEmpty && WordsLanded.summary(WordsLanded.read(""), now: now, calendar: utc).last == "The log is empty.")

    // Counted events: fixed names only; codes only in their own shape.
    let names = Set(r.events.map(\.name))
    check("landed.events", names.isSuperset(of: ["quick tap", "stopped by another key while holding", "restarted after a crash",
                                                 "paste: target changed", "typing stopped while talking: hardware click",
                                                 "meeting could not start (NSOSStatusErrorDomain -50)", "meeting notes failed (other)",
                                                 "meeting: audio write failed", "better summary failed (other)",
                                                 "meeting summary failed (FoundationModels.LanguageModelSession.GenerationError 2)"]), "\(names.sorted())")
    check("landed.pasteNotFailure", !names.contains("paste: other"))
    check("landed.unknownDraftReason", !names.contains { $0.contains("Secret") })
    check("landed.retryNotLoad", WordsLanded.eventName("engine: whisper failed once, trying again") == "Whisper tried a piece again"
          && WordsLanded.eventName("engine: whisper failed The model is missing") == "engine failed to load"
          && WordsLanded.eventName("engine: instant failed while you talked, the ending writes it again") == "a piece failed, the ending covers it")

    // The report: counts and settings only. Nothing from a log line but what it counts.
    let settings: [(String, String)] = [("engine", "whisper"), ("language", "en-CA"), ("words", "raw"), ("talk key", "fnOrOption"),
                                        ("microphone", "Scarlett 2i2 4th Gen"), ("meetings folder", "/Users/someone/Private"),
                                        ("better summary", "my-secret-script.sh"), ("typing speed", "40"), ("secret setting", "x"),
                                        ("language", "../../etc"), ("Enter stops and sends", "on")]
    func report(_ text: String, note: String = "", version: String = "0.12.3", model: String = "MacBookPro18,2") -> String {
        VoiceReport.text(.init(version: version, build: "15", macOS: "27.0.1", model: model, memoryGB: 64, settings: settings,
                               log: text, now: now, calendar: utc, note: note))
    }
    let rep = report(log())
    for secret in ["Secret", "secret", "Scarlett", "/Users", "Private", ".wav", ".sh", "AXWebArea", "AXTextArea", "What happened", "etc"] {
        check("report.no \(secret)", !rep.contains(secret))
    }
    check("report.sameWhateverTheNames", rep == report(log(app: "Mail", file: "notes.caf", mic: "MacBook Pro Microphone", why: "C:/other")))
    check("report.version", rep.contains("Redpen Voice: 0.12.3 (15)\nmacOS: 27.0.1\nMac: MacBookPro18,2, 64 GB memory\n"))
    check("report.settingsKept", rep.contains("  engine: whisper\n") && rep.contains("  language: en-CA\n") && rep.contains("  typing speed: 40\n")
          && rep.contains("  Enter stops and sends: on\n"))
    check("report.settingsOther", rep.contains("  microphone: other\n") && rep.contains("  meetings folder: other\n")
          && rep.contains("  better summary: other\n") && rep.contains("  language: other\n"))
    check("report.unknownSettingGone", !rep.contains("secret setting"))
    check("report.table", rep.contains("  Today: 3 of 13 landed in full, 7 kept for ⌃⌥V, 3 lost, 1 thrown away with Escape\n"))
    check("report.since", rep.contains("  Since this build started, 2026-10-31 08:57 UTC: 1 of 1 landed in full (100%), 0 kept, 0 lost\n"))
    check("report.reasons", rep.contains("  kept, box was sent: 1\n") && rep.contains("  lost, ending failed: 1\n"))
    check("report.counts", rep.contains("  Voice started: 4\n") && rep.contains("  restarted after a crash: 1\n")
          && rep.contains("  meeting could not start (NSOSStatusErrorDomain -50): 1\n"))
    check("report.noCrashLine", report(L(31, "08:00:00", "launched")).contains("  restarted after a crash: 0\n"))
    check("report.badShapes", report("", version: "Cedric 1", model: "Cedric's Mac").contains("Redpen Voice: unknown (15)")
          && report("", model: "Cedric's Mac").contains("Mac: unknown,"))
    // Every line but the typed note is a fixed word, a number, or an allowed setting: no slash, no quote marks.
    check("report.plainLines", rep.split(separator: "\n").allSatisfy { !$0.contains("/") && !$0.contains("\"") && !$0.contains("[") })
    check("report.noNoteUnlessTyped", !rep.contains("What happened") && !report(log(), note: "  \n ").contains("What happened"))
    let noted = report(log(), note: "It stopped halfway\nin Mail")
    check("report.noteTyped", noted.hasSuffix("What happened (typed by the person sending this)\n  It stopped halfway in Mail\n"))
    check("report.noteCapped", VoiceReport.note(String(repeating: "a", count: 2000)).count == 1001)
    check("report.noteAppended", noted == rep + VoiceReport.noteSection("It stopped halfway\nin Mail"))
    check("report.noColonConnector", !rep.contains("only:"))
}

print("\(pass) passed, \(fail) failed")
exit(fail == 0 ? 0 : 1)
