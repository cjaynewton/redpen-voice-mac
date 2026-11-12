// Compiled by check-first-words.py with the production draftQuiet and draftBlocked bodies.
// AX focus, HID time and text posting below are inert test doubles.
@MainActor final class BarClickHost {
    final class Owner { var isCancelled = false }
    final class StartBox { let element = Insert.element; var sent = false; var userEdited = false }
    final class Drafting {
        let owner: Owner
        let generation = 1
        let startBox: StartBox? = StartBox()
        let startedUptime = ProcessInfo.processInfo.systemUptime
        var quietUptime: Double { startedUptime }
        let quietAt = Date()
        lazy var input = DraftInput(since: startedUptime)
        var hardwareSample: DraftSafety.HardwareSample?
        var clickPaused = false, checksStopped = false
        var stopWhy: TalkingWords.Stop?
        var reportedFailures: Set<DraftSafety.Failure> = []
        init(_ owner: Owner) { self.owner = owner }
    }
    let owner = Owner()
    lazy var draft = Drafting(owner)
    var delivery = 1
    var session: Owner?
    var finishingDrafting: Drafting?
    var userActedAt = Date.distantPast
    var sameContext = true
    init() { session = owner }
    func focusedStart(_ start: StartBox) -> NSObject? {
        !start.sent && !DictationEnding.looksSent(Insert.box) && sameContext && Insert.focusIsOriginal ? Insert.element : nil
    }
    func permits(completing: Bool = true) async -> Bool {
        await draftQuiet(draft, during: "typing draft", completingDraft: completing)
    }
    __DRAFT_BLOCKED__
    __DRAFT_QUIET__
}

@MainActor func runBarClickAdapterChecks(_ check: (String, Bool) -> Void) async {
    let words = "These synthetic words cross several chunks and finish in the same box."
    // Bar drag / menu / button clicks can arrive at the monitor after HID sees the down.
    for lateMonitor in [false, true] {
        // Independent simulated gestures are farther apart than the specified 50 ms HID tolerance.
        try? await Task.sleep(for: .milliseconds(60))
        Insert.reset("Original ")
        let host = BarClickHost(); _ = host.draft
        Insert.onTypeChunk = {
            let at = ProcessInfo.processInfo.systemUptime
            CGEventSource.times[.leftMouseDown] = at
            if lateMonitor {
                Task { @MainActor in
                    await Task.yield()
                    OwnWindowClicks.shared.record(.left, at: at)
                }
            } else { OwnWindowClicks.shared.record(.left, at: at) }
        }
        let landed = await Insert.text(words, joining: 1, confirmed: true, while: { await host.permits() })
        check("bar click during actual draft keeps full typing (late=\(lateMonitor))", landed && Insert.box == "Original " + words)
        check("bar click never marks a pause or typing reason", !host.draft.clickPaused && host.draft.stopWhy == nil)
    }
    for change in ["same box", "other box", "selection", "caret", "key", "send", "conversation", "cancel", "new dictation"] {
        // Independent simulated gestures are farther apart than the specified 50 ms HID tolerance.
        try? await Task.sleep(for: .milliseconds(60))
        Insert.reset("Original ")
        let host = BarClickHost(); _ = host.draft
        var clicked = false
        Insert.onTypeChunk = {
            guard !clicked else { return }; clicked = true
            let at = ProcessInfo.processInfo.systemUptime
            CGEventSource.times[.leftMouseDown] = at
            OwnWindowClicks.shared.recordExternal(.left, at: at)
            host.userActedAt = Date()
            if change == "other box" { Insert.focusIsOriginal = false }
            if change == "selection" { Insert.cursorOverride = NSRange(location: 0, length: 8) }
            if change == "caret" { Insert.cursorOverride = NSRange(location: 1, length: 0) }
            if change == "key" { host.draft.input.record(talkKey: false, at: at); CGEventSource.times[.keyDown] = at }
            if change == "send" { host.draft.startBox?.sent = true; Insert.box = "" }
            if change == "conversation" { host.sameContext = false }
            if change == "cancel" { host.owner.isCancelled = true }
            if change == "new dictation" { host.delivery += 1 }
        }
        let landed = await Insert.text(words, joining: 1, confirmed: true, while: { await host.permits() })
        if change == "same box" {
            check("real click finishes current draft in same box", landed && Insert.box == "Original " + words)
            check("real click is reported as click", host.draft.clickPaused && host.draft.stopWhy == .clicked)
            check("real click still blocks future draft without fresh proof", !(await host.permits(completing: false)))
        } else {
            check("draft continuation refuses \(change)", !landed && Insert.typedCount == 20)
        }
        if change == "other box" {
            let attempt = Insert.draftAttempt!.draft
            check("actual stopped adapter retains exact 20 posted units", attempt.exactPostedPrefix && attempt.text.utf16.count == 20)
            let start = BoxPrint(role: "AXTextArea", identifier: "box", frame: nil, text: "Original ", title: "Chat", url: "chat://one")
            let match = DictationEnding.reconcileLateDraft(attempt, confirmedDrafts: "", start: start, now: start,
                actual: Insert.box, cursor: nil, sameElement: true, sameWindow: true, userEdited: false,
                inStartBox: false, allowUnfocused: true)
            check("actual partial click draft is accounted for", match?.box.text == Insert.box && match?.text == Insert.typed)
            Insert.focusIsOriginal = true; Insert.onTypeChunk = nil; CGEventSource.times = [:]
            let final = await Insert.replaceDraft(match!.text, with: words, expectedBox: match!.box.text!, in: Insert.element, while: { true })
            check("06:00:44 replay finishes all words in original box", final && Insert.box == "Original " + words)
        }
        if change == "send" {
            check("sent box remains empty", Insert.box.isEmpty)
        }
    }
    for own in [true, false] {
        try? await Task.sleep(for: .milliseconds(60))
        Insert.reset("Original ")
        Insert.onTypeChunk = {
            let at = ProcessInfo.processInfo.systemUptime
            CGEventSource.times[.rightMouseDown] = at
            if own { OwnWindowClicks.shared.record(.right, at: at) }
            else { OwnWindowClicks.shared.recordExternal(.right, at: at) }
        }
        let landed = await Insert.finishingText(words, while: { true })
        check("finishing adapter filters only own clicks (own=\(own))", own ? landed && Insert.box == "Original " + words : !landed && Insert.typedCount == 20)
    }
    Insert.reset("")
}
