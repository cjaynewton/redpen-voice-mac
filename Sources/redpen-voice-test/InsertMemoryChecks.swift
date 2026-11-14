import Foundation
import VoiceCore

/// The app-by-app memory of an Accessibility insert that does nothing. Pure values, no app is asked anything.
func insertMemoryChecks(_ check: (String, Bool, String) -> Void) {
    func c(_ name: String, _ ok: Bool) { check("insertMemory." + name, ok, "") }
    let t3 = InsertMemory.App(pid: 700, launched: 100), notes = InsertMemory.App(pid: 800, launched: 100)
    var memory = InsertMemory()
    c("nothingSkippedAtFirst", !memory.skips(t3))
    c("oneMissIsNotEnough", !memory.missed(t3) && !memory.skips(t3))
    c("secondMissInARowStartsTheSkipOnce", memory.missed(t3) && memory.skips(t3))
    c("skipIsSaidOnlyOnce", !memory.missed(t3) && !memory.missed(t3) && memory.skips(t3))
    c("otherAppsAreUntouched", !memory.skips(notes))
    memory.landed(t3)
    c("skipLastsForTheProcess", memory.skips(t3))
    // Misses must be in a row: one that lands in between starts the count again.
    c("aLandedInsertBreaksTheRow", !memory.missed(notes) && { memory.landed(notes); return !memory.missed(notes) }() && !memory.skips(notes))
    c("thenTwoInARowStillCount", memory.missed(notes) && memory.skips(notes))
    // The same process number after a relaunch is a new process.
    let relaunched = InsertMemory.App(pid: 700, launched: 250)
    c("relaunchStartsClean", !memory.skips(relaunched) && !memory.missed(relaunched) && memory.missed(relaunched) && memory.skips(relaunched) && !memory.skips(t3))
    var stale = InsertMemory()
    _ = stale.missed(t3)
    c("oneMissFromAnOlderProcessIsForgotten", !stale.missed(relaunched) && !stale.skips(relaunched))
    c("twoMissesNeeded", InsertMemory.missesBeforeSkip == 2)
}

/// What kind of key stopped live words. The kind is for the log only: a modifier still stops them, as before.
func draftInputKindChecks(_ check: (String, Bool, String) -> Void) {
    func c(_ name: String, _ ok: Bool) { check("draftInputKind." + name, ok, "") }
    let talkOnly = DraftInput(since: 0)
    talkOnly.record(talkKey: true, at: 1)
    c("talkKeyAloneIsNoTyping", talkOnly.snapshot().typingAt == nil && talkOnly.snapshot().kind == nil)
    let shift = DraftInput(since: 0)
    shift.record(talkKey: true, at: 1); shift.record(talkKey: false, modifier: true, at: 2); shift.record(talkKey: false, modifier: true, at: 2.1)
    c("modifierTapIsNamedAModifier", shift.snapshot().kind == .modifier)
    // Behaviour unchanged: a modifier tap is still typing, still sticky, and still stops live words.
    c("modifierTapStillCountsAsTyping", shift.snapshot().typingAt == 2.1)
    shift.record(talkKey: true, at: 5)
    c("modifierTapStaysStickyAfterALaterTalkTap", shift.snapshot().typingAt == 2.1 && shift.snapshot().kind == .modifier)
    c("modifierTapStillStopsLiveWords", DraftSafety.hardwareFailure(since: 0, at: 6, keyDownAgo: 1, leftClickAgo: 99, rightClickAgo: 99,
        talkKeyDownTimes: shift.snapshot().talkTimes, typingKeyDownAt: shift.snapshot().typingAt) == .hardwareKey)
    let both = DraftInput(since: 0)
    both.record(talkKey: false, modifier: true, at: 2); both.record(talkKey: false, at: 3)
    c("anotherKeyOutweighsAModifier", both.snapshot().kind == .otherKey && both.snapshot().typingAt == 3)
    let letter = DraftInput(since: 0)
    letter.record(talkKey: false, at: 2)
    c("ordinaryKeyIsNamedOtherKey", letter.snapshot().kind == .otherKey)
    let fnRelease = DraftInput(since: 0)
    fnRelease.record(talkKey: true, at: 4); fnRelease.record(talkKey: false, modifier: true, at: 4.0001)
    c("talkKeysOwnFlagChangeIsNotTyping", fnRelease.snapshot().typingAt == nil && fnRelease.snapshot().kind == nil)
    c("kindsAreWordsNotKeys", DraftInput.Kind.modifier.rawValue == "modifier" && DraftInput.Kind.otherKey.rawValue == "other key")
    // The report reader still counts the new log line under the same name.
    c("reportStillReadsTheBlockedLine", WordsLanded.eventName("draft blocked: hardware key (draft); category=modifier, 12ms before this check") == "typing stopped while talking: hardware key"
        && WordsLanded.eventName("draft blocked: hardware click (typing draft); category=click") == "typing stopped while talking: hardware click")
}
