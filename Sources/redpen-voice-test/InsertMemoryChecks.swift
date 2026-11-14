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
