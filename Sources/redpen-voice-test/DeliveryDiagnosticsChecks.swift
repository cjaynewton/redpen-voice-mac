import Foundation
import VoiceCore

/// In-memory browser replies and text-box snapshots only. No AX, clipboard, audio or posted input.
func deliveryDiagnosticsChecks(_ check: (String, Bool, String) -> Void) {
    func c(_ name: String, _ ok: Bool, _ detail: String = "") { check("delivery.diagnostics." + name, ok, detail) }
    let discovery = BrowserPauseOperation.Action.discover(excluding: [])
    let known = BrowserPauseOperation.Action.pause(7, document: "synthetic", retry: false)
    let privateError = "PRIVATE_TITLE https://private.invalid/query?secret=PRIVATE_WORDS error (-1728)"
    let failed = BrowserActionReport(action: discovery, status: 1, output: "", error: privateError, timedOut: false)
    c("runnerErrorIsNotCalledSlow", failed.reply == .discovered(counts: [:], touched: [], slow: false, refused: false,
        unanswered: [], failed: true) && failed.fields.contains("reason=runner_error") && failed.fields.contains("apple_errors=-1728"), failed.fields)
    c("noPrivateErrorContent", !failed.fields.contains("PRIVATE") && !failed.fields.contains("https") && !failed.fields.contains("secret"))
    let denied = BrowserActionReport(action: discovery, status: 1, output: "", error: "not authorized (-1743)", timedOut: false)
    c("automationDenialNamed", denied.fields.contains("reason=not_allowed") && denied.reply == .discovered(counts: [:], touched: [], slow: false, refused: false, unanswered: [], notAllowed: true))
    let timeout = BrowserActionReport(action: known, status: 1, output: "", error: "PRIVATE (-1712)", timedOut: false)
    c("appleEventTimeoutNamed", timeout.reply == .timeout && timeout.fields.contains("reason=timeout"))
    let cut = BrowserActionReport(action: discovery, status: 1, output: "", error: "", timedOut: true,
        journal: ["1", "=1:1", "2", "=2:3", "3"])
    c("killedRunnerKeepsTwoConfirmedTabs", cut.reply == .discovered(counts: [1:1,2:3], touched: [1,2,3], slow: true, refused: false, unanswered: [3]), cut.fields)
    let completeCut = BrowserActionReport(action: discovery, status: 1, output: "", error: "", timedOut: true,
        journal: ["1", "=1:1", "2", "=2:0"])
    c("completedZeroIsNotAnUnansweredPause", completeCut.reply == .discovered(counts: [1:1], touched: [1,2], slow: true, refused: false, unanswered: []))
    let malformed = BrowserActionReport(action: discovery, status: 0, output: "PRIVATE_PAGE,https://example.invalid:secret", error: "", timedOut: false)
    c("malformedOutputCannotInventSuccess", malformed.fields.contains("confirmed=0") && !malformed.fields.contains("PRIVATE"))
    let stale = BrowserActionReport(action: known, status: 0, output: "-1", error: "", timedOut: false)
    c("stalePageNamed", stale.reply == .navigated && stale.fields.contains("reason=stale_page"))

    // Actual operation receives the parsed report, so a fast script error is distinct from a deadline.
    let op = BrowserPauseOperation(token: "error", owner: 1, now: { 0 }) { _, _, reply in reply(failed.reply) }
    op.start()
    c("fastErrorOutcomeDistinctFromSlow", op.finished && op.outcome == .failed("browser action failed") && op.timeouts == 0)
    let permissionOp = BrowserPauseOperation(token: "denied", owner: 1, now: { 0 }) { _, _, reply in reply(denied.reply) }
    permissionOp.start()
    c("permissionOutcomeDistinctFromSlow", permissionOp.outcome == .notAllowed)
    let nine = Dictionary(uniqueKeysWithValues: (1...9).map { ($0,1) })
    let many = BrowserPauseOperation(token: "nine", owner: 1, now: { 0 }) { _, _, reply in
        reply(.discovered(counts: nine, touched: Array(1...9), slow: false, refused: false, unanswered: []))
    }
    many.start()
    c("nineConfirmedPausesTracked", many.counts == nine && many.hold.held == Array(1...9))
    var clock = 0.0, resumed: [Int] = []
    let release = BrowserResumeOperation(tabs: many.hold.releaseTabs, now: { clock }, allowed: { true }) { tab, _, reply in
        clock += 0.1; resumed.append(tab); reply(1)
    }
    release.start()
    c("nineFastSimulatedTabsResumeOnce", release.finished && resumed == Array(1...9) && release.result.resumed == Set(1...9))

    // Enumerate both pre-post and post-post snapshots. Logging must not change the old target decision.
    for mask in 0..<128 {
        let flags = (0..<7).map { mask & (1 << $0) != 0 }
        let snapshot = PasteTargetCheck(sameElement: flags[0], sameApp: flags[1], sameTitle: flags[2], sameAddress: flags[3],
            sameValue: flags[4], sameSelection: flags[5], posted: flags[6], landed: false)
        let original = flags[0] && flags[1] && flags[2] && flags[3] && (flags[6] || flags[4] && flags[5])
        c("targetPolicyPreserved.\(mask)", snapshot.sameTarget == original)
    }
    let changed = PasteTargetCheck(sameElement: false, sameApp: true, sameTitle: nil, sameAddress: nil,
        sameValue: false, sameSelection: false, posted: true, landed: true)
    c("uncertainPasteNotRetried", !changed.sameTarget && changed.fields.contains("posted=1") && changed.fields.contains("landed_evidence=1"))
    c("unreadContextExplicit", changed.fields.contains("title_same=-1") && changed.fields.contains("address_same=-1"))
    let title = PasteTargetCheck(sameElement: true, sameApp: true, sameTitle: false, sameAddress: true,
        sameValue: true, sameSelection: true, posted: true, landed: false)
    c("titleChangeDistinguished", !title.sameTarget && title.fields.contains("title_same=0") && title.fields.contains("element_same=1"))
    let moved = PasteTargetCheck(sameElement: true, sameApp: true, sameTitle: true, sameAddress: true,
        sameValue: true, sameSelection: false, posted: false, landed: false)
    c("caretMoveBeforePasteDistinguished", !moved.sameTarget && moved.fields.contains("selection_same=0"))
    var attempt = PasteAttempt(at: 0)
    c("pasteStartsWithStableRelease", attempt.next(at: 0, modifiersDown: false, sameTarget: true, clipboardOwned: true, landed: false) == .wait)
    c("pastePostsOnce", attempt.next(at: 0.04, modifiersDown: false, sameTarget: true, clipboardOwned: true, landed: false) == .post)
    c("changedTargetStillRefusesEvenWithTextEvidence", attempt.next(at: 0.05, modifiersDown: false,
        sameTarget: changed.sameTarget, clipboardOwned: true, landed: changed.landed) == .failed("target changed"))
}
