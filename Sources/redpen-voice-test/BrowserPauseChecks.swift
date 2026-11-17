import Foundation
import VoiceCore

/// Passive fakes drive the same transaction used by Media. No AppleEvents, hardware or ASR.
func browserPauseChecks(_ check: (String, Bool, String) -> Void) {
    browserDiscoveryChecks(check)
    typealias Op = BrowserPauseOperation
    final class Fake {
        var time: Double = 0
        var actions: [Op.Action] = []
        var limits: [Double] = []
        var reply: ((Op.Reply) -> Void)?
        var finishes = 0, slows = 0
        var preferred: Int? = 101
        var budget = MediaPauseBudget.heard
        lazy var op: Op = {
            let result = Op(token: "fake", owner: 1, preferredTab: preferred, budget: budget, now: { self.time }) { action, limit, done in
                self.actions.append(action); self.limits.append(limit); self.reply = done
                precondition(limit > 0 && limit <= Op.totalBudget)
            }
            result.onFinish = { self.finishes += 1 }; result.onSlow = { self.slows += 1 }
            return result
        }()
        func answer(_ value: Op.Reply, after: Double = 0.1) {
            time += after; let callback = reply; reply = nil; callback?(value)
        }
    }
    func c(_ name: String, _ value: Bool) { check("browser.operation." + name, value, "") }
    let known = Fake(); known.op.start(); known.answer(.paused(1), after: 1)
    c("knownTabPausesBeforeDiscovery", known.op.counts == [101:1] && known.actions.count == 2 && known.finishes == 0)
    c("knownSuccessStillSearchesOtherTabs", known.actions.last == .discover(excluding: [101]))
    c("knownTabOneSecondSimulated", known.time == 1)
    c("knownCallBounded", known.limits == [1.2, 7])
    known.answer(.discovered(counts: [202:1,303:2], touched: [202,303], slow: false, refused: false))
    c("allThreeTabsHeld", known.op.finished && known.finishes == 1 && known.op.counts == [101:1,202:1,303:2]
        && known.op.hold.held == [101,202,303])
    let interruptedMany = Fake(); interruptedMany.op.start(); interruptedMany.answer(.paused(1))
    interruptedMany.op.stop(cancelled: true)
    interruptedMany.answer(.discovered(counts: [202:1], touched: [202,303], slow: true, refused: false, unanswered: [303]))
    c("cancelledDiscoveryKeepsEveryConfirmedPause", interruptedMany.op.finished && interruptedMany.actions.count == 2
        && interruptedMany.op.state == .cancelled && interruptedMany.op.hold == MediaHold(held: [101,202], unanswered: [303]))
    let budgetMany = Fake(); budgetMany.op.start(); budgetMany.answer(.paused(1))
    budgetMany.time = 8; budgetMany.op.tick()
    budgetMany.answer(.discovered(counts: [202:1], touched: [202,303], slow: true, refused: false, unanswered: [303]), after: 0)
    c("budgetDoesNotLoseEarlierSuccess", budgetMany.op.finished && budgetMany.op.counts == [101:1,202:1]
        && budgetMany.actions.count == 2 && budgetMany.op.hold.unanswered == [303])
    let incident = Fake(); incident.op.start(); incident.answer(.paused(0), after: 0.93)
    c("emptyKnownStartsOneDiscovery", incident.actions.last == .discover(excluding: [101]))
    // One runner skips the refusing front tab 414388973 and reaches the other playing tab.
    incident.answer(.discovered(counts: [77:1], touched: [414388973,77], slow: false, refused: true), after: 1.1)
    c("0623RecoveredInTwoCalls", incident.op.finished && incident.actions.count == 2 && incident.op.counts == [77:1])
    c("0623RefusalDoesNotHideSuccess", incident.op.outcome == .handled(tabs: [77], count: 1))
    // Changed on purpose (Nov 13 2026): tabs that answered with nothing playing are finished with. Only the
    // confirmed pause is held and looked at on release.
    c("0623ReconciliationOnlyTheConfirmedPause", incident.op.reconciliationTabs == [77] && incident.op.hold == MediaHold(held: [77], unanswered: []))
    c("0623TimingSimulated", abs(incident.time - 2.03) < 0.001)
    let fresh = Fake(); fresh.preferred = nil; fresh.op.start()
    fresh.answer(.discovered(counts: [44:2], touched: [1,44], slow: false, refused: false), after: 1)
    c("uncachedOneDiscoveryCall", fresh.actions == [.discover(excluding: [])] && fresh.op.counts == [44:2])
    c("uncachedOneSecondSimulated", fresh.time == 1)
    let slow = Fake(); slow.preferred = nil; slow.op.start(); slow.time = 4; slow.op.tick()
    c("slowOnce", slow.slows == 1 && slow.op.slow && !slow.op.finished)
    slow.time = 8; slow.op.tick()
    slow.answer(.discovered(counts: [:], touched: [7,8], slow: true, refused: false), after: 0)
    c("budgetStopsDiscovery", slow.op.finished && slow.finishes == 1 && slow.actions.count == 1)
    // Changed on purpose (Nov 13 2026). This used to assert that a slow result keeps its tabs as a hold, which
    // is what made every later press a takeover. A slow result with nothing confirmed now leaves no hold. Its
    // tabs are only loose ends for one look on release.
    c("slowResultLeavesNoHold", !slow.op.hold.holds && slow.op.hold.unanswered == [7,8] && slow.op.outcome == .failed("slow"))
    let partial = Fake(); partial.preferred = nil; partial.op.start(); partial.time = 8
    partial.answer(.discovered(counts: [5:1], touched: [5], slow: true, refused: false), after: 0)
    c("partialPauseAtBudgetRetained", partial.op.finished && partial.op.outcome == .handled(tabs: [5], count: 1))
    let late = Fake(); late.op.start(); late.time = 5.2; late.op.tick()
    var audio = MediaOpening(); audio.hold(at: Date(timeIntervalSince1970: 0))
    c("audioFallbackAtFive", audio.ready(at: Date(timeIntervalSince1970: 5)) && audio.keepsOriginal)
    late.answer(.paused(1)); audio.include(through: 999)
    c("lateSuccessCannotReviseAudio", late.op.counts == [101:1] && audio.through == 0 && !audio.acceptsCleanup)
    for cancelled in [false, true] {
        let f = Fake(); f.op.start(); f.op.stop(cancelled: cancelled); f.answer(.paused(1))
        c("stopNoFurtherPause.\(cancelled)", f.actions.count == 1 && f.finishes == 1 && f.op.counts == [101:1])
        if cancelled { c("cancelledStatePreserved", f.op.state == .cancelled) }
    }
    let transfer = Fake(); transfer.op.start(); transfer.op.transfer(to: 2); transfer.answer(.paused(1))
    c("newOwnerCannotBeOverridden", transfer.op.owner == 2 && transfer.op.state == .transferred && transfer.actions.count == 1)
    var ownership = MediaPauseOwnership(); ownership.hold(); let oldOwner = ownership.generation
    ownership.hold(); transfer.op.transfer(to: ownership.generation)
    c("oldCompletionCannotOwnNewRecording", !ownership.owns(oldOwner) && ownership.owns(transfer.op.owner))
    let retry = Fake(); retry.op.start()
    let first = retry.actions[0]; retry.answer(.timeout)
    if case .pause(let id, let document, _) = first {
        c("oneRetrySameKnownDocument", retry.actions.last == .pause(id, document: document, retry: true))
    } else { c("oneRetrySameKnownDocument", false) }
    retry.answer(.timeout)
    c("discoveryExcludesRetriedTab", retry.actions.last == .discover(excluding: [101]))
    retry.answer(.discovered(counts: [:], touched: [], slow: false, refused: false))
    c("retryNeverRepeats", retry.actions.count == 3 && retry.op.finished && retry.op.recovery)
    let nav = Fake(); nav.op.start(); nav.answer(.navigated); nav.op.stop()
    c("navigationNoRetry", nav.actions.count == 2 && nav.actions.last == .discover(excluding: [101]))
    let denied = Fake(); denied.op.start(); denied.answer(.notAllowed)
    c("deniedEndsWithoutDiscovery", denied.op.finished && denied.op.outcome == .notAllowed && denied.actions.count == 1)
    let queued = Fake(); _ = queued.op; queued.time = 9; queued.op.start()
    c("queueTimeCounts", queued.op.finished && queued.actions.isEmpty)
    let delayed = Op(token: "delayed", owner: 1, entered: 0, now: { 8.1 }) { _, _, _ in preconditionFailure("expired press dispatched") }
    delayed.start()
    c("takeoverWaitCountsAgainstPressBudget", delayed.finished && delayed.outcome == .failed("slow"))
    c("anotherAppPreventsResume", !MediaGate.shouldResume(paused: true, playingNow: true))
    var keys = TalkKeyState(); _ = keys.event(key: 63, down: true, at: 0); _ = keys.event(key: 63, down: false, at: 0.1)
    c("quickTapNoDispatch", !keys.canPauseMedia(at: 0.5))
    let codes: [Op.Reply] = [.ids([]), .candidate(""), .paused(0), .empty, .navigated, .timeout, .refused, .notAllowed, .failed]
    c("historicalReplyCodesUnchanged", codes.map(\.code) == Array(0...8))

    // Terminal reconciliation accounts for every requested tab, including a reply after permission is revoked.
    var resumeTime: Double = 0, resumeAllowed = true
    var resumeActions: [Int] = [], resumeReply: ((Int?) -> Void)?, resumeFinishes = 0
    let resume = BrowserResumeOperation(tabs: [1, 2, 3], now: { resumeTime }, allowed: { resumeAllowed }) { tab, limit, reply in
        resumeActions.append(tab); resumeReply = reply
        precondition(limit > 0 && limit <= BrowserResumeOperation.actionBudget)
    }
    resume.onFinish = { _ in resumeFinishes += 1 }
    resume.start(); resumeReply?(1)
    c("resumePartialRecordedBeforeNextTab", resume.result.resumed == [1] && resume.result.unresolved == [2, 3] && resumeActions == [1, 2])
    resumeAllowed = false; resume.cancel()
    c("resumeCancellationWaitsForDispatchedReply", !resume.finished && resumeFinishes == 0)
    resumeReply?(1)
    c("resumeCancelledTerminalIncludesLatePlay", resume.finished && resumeFinishes == 1 && resume.result.cancelled && resume.result.resumed == [1, 2] && resume.result.unresolved == [3])
    resume.cancel(); resume.start()
    c("resumeTerminalExactlyOnce", resumeFinishes == 1 && resumeActions == [1, 2])
    var noActions = 0, emptyFinishes = 0
    let emptyResume = BrowserResumeOperation(tabs: [], now: { 0 }, allowed: { true }) { _, _, _ in noActions += 1 }
    emptyResume.onFinish = { _ in emptyFinishes += 1 }; emptyResume.start()
    c("emptyTouchedNoSweep", noActions == 0 && emptyFinishes == 1 && emptyResume.result.requested.isEmpty)
    let revoked = BrowserResumeOperation(tabs: [1], now: { 0 }, allowed: { false }) { _, _, _ in noActions += 1 }
    revoked.start()
    c("revokedBeforeDispatchStillTerminal", revoked.finished && revoked.result.cancelled && revoked.result.unresolved == [1] && noActions == 0)
    resumeTime = 0; resumeActions = []
    let budget = BrowserResumeOperation(tabs: [1, 2], now: { resumeTime }, allowed: { true }) { tab, _, reply in
        resumeActions.append(tab); resumeReply = reply
    }
    budget.start(); resumeTime = 4; resumeReply?(nil)
    c("resumeBudgetLeavesKnownUnresolvedTabs", budget.finished && budget.result.unresolved == [1, 2] && resumeActions == [1])
    // A takeover handles all known old marks, then makes one pass for an unknown in-flight discovery.
    var secondPauses: [Int] = [], discoveries = 0
    let inherited = Op(token: "new", owner: 2, candidates: [1,2,3], inheritedTokens: ["old"],
                       inheritedTabs: [4], now: { 0 }) { action, _, reply in
        switch action {
        case .pause(let id, _, _): secondPauses.append(id); reply(.paused(1))
        case .discover: discoveries += 1; reply(.discovered(counts: [4:1], touched: [4], slow: false, refused: false))
        }
    }
    inherited.start()
    c("takeoverRepausesAndAdoptsAll", inherited.finished && secondPauses == [1,2,3] && inherited.counts == [1:1,2:1,3:1,4:1])
    c("takeoverOneDiscovery", discoveries == 1 && inherited.reconciliationTabs == [1,2,3,4])
    let priority = Op(token: "priority", owner: 1, now: { 0 }) { _, _, reply in
        reply(.discovered(counts: [99:1], touched: Array(1...20) + [99], slow: false, refused: false))
    }
    priority.start()
    var firstResume: Int?
    let prioritized = BrowserResumeOperation(tabs: priority.reconciliationTabs, now: { 0 }, allowed: { true }) { tab, _, _ in firstResume = tab }
    prioritized.start()
    c("confirmedPauseResumesBeforeEmptyDiscoveryTabs", firstResume == 99)
    let quit = Fake(); quit.op.start(); quit.op.stop(cancelled: true)
    c("quitSealIncludesInFlightTab", !quit.op.finished && quit.op.reconciliationTabs == [101])
    quit.answer(.paused(1))
    c("quitLateReplyCannotDispatchAgain", quit.op.finished && quit.actions.count == 1)
    let discoverTransfer = Fake(); discoverTransfer.preferred = nil; discoverTransfer.op.start()
    discoverTransfer.op.transfer(to: 2)
    discoverTransfer.answer(.discovered(counts: [9:1], touched: [8,9], slow: false, refused: false))
    c("transferredDiscoveryKeepsLateMarks", discoverTransfer.op.state == .transferred && discoverTransfer.op.reconciliationTabs == [9] && discoverTransfer.op.hold.holds)

    // Nov 12 2026 replay. Timeouts with nothing confirmed leave no hold, and the next press is fresh.
    let nov12 = Fake(); nov12.op.start(); nov12.answer(.timeout, after: 1.2); nov12.answer(.timeout, after: 1.2)
    nov12.answer(.discovered(counts: [:], touched: [7,8,9], slow: true, refused: false, unanswered: [8]), after: 2)
    c("nov12TimeoutsLeaveNoHold", nov12.op.finished && !nov12.op.hold.holds && nov12.op.outcome == .failed("slow"))
    c("nov12OnlyUnansweredTabsGetALook", nov12.op.hold.unanswered == [8, 101] && nov12.op.reconciliationTabs == [8, 101])
    c("nov12NextPressIsFresh", !MediaHold.nextPressTakesOver(nov12.op.hold, askRunning: false))
    c("nov12CountsForOneLogLine", nov12.op.calls == 3 && nov12.op.timeouts == 3)
    c("runningAskCanStillBeTakenOver", MediaHold.nextPressTakesOver(.none, askRunning: true))
    c("confirmedPauseIsTakenOver", MediaHold.nextPressTakesOver(incident.op.hold, askRunning: false))
    let answeredEmpty = Fake(); answeredEmpty.op.start(); answeredEmpty.answer(.paused(0))
    answeredEmpty.answer(.discovered(counts: [:], touched: [3,4], slow: false, refused: false))
    c("allAnsweredEmptyLeavesNothing", answeredEmpty.op.finished && answeredEmpty.op.hold == .none && answeredEmpty.op.outcome == .nothingFound)
    // A takeover that cannot reach a tab of the hold it took over still holds it, so it gets its release.
    let stuck = Op(token: "new", owner: 2, candidates: [1], inheritedTokens: ["old"], inheritedTabs: [1], now: { 0 }) { action, _, reply in
        if case .pause = action { reply(.timeout) } else { reply(.discovered(counts: [:], touched: [], slow: false, refused: false)) }
    }
    stuck.start()
    c("takenOverTabStaysHeldUntilItAnswers", stuck.finished && stuck.hold == MediaHold(held: [1], unanswered: []))
    let cleared = Op(token: "new", owner: 2, candidates: [1], inheritedTokens: ["old"], inheritedTabs: [1], now: { 0 }) { action, _, reply in
        if case .pause = action { reply(.paused(0)) } else { reply(.discovered(counts: [:], touched: [], slow: false, refused: false)) }
    }
    cleared.start()
    c("takenOverTabThatAnswersClearIsLetGo", cleared.finished && cleared.hold == .none)
    // A call that was never sent (the ask was stopped while the call waited its turn) is no answer. The tab of
    // the hold it took over stays held, so its video is still played again. It used to come back as `.empty`,
    // which read as "answered clear" and let the tab go (lead review, Nov 13 2026).
    let unsent = Op(token: "new", owner: 2, candidates: [1], inheritedTokens: ["old"], inheritedTabs: [1], now: { 0 }) { action, _, reply in
        if case .pause = action { reply(.unsent) } else { reply(.discovered(counts: [:], touched: [], slow: false, refused: false)) }
    }
    unsent.start()
    c("unsentCallLeavesTakenOverTabHeld", unsent.finished && unsent.hold == MediaHold(held: [1], unanswered: []) && unsent.timeouts == 0)
    let unsentFresh = Op(token: "new", owner: 2, preferredTab: 5, now: { 0 }) { action, _, reply in
        if case .pause = action { reply(.unsent) } else { reply(.discovered(counts: [:], touched: [], slow: false, refused: false)) }
    }
    unsentFresh.start()
    c("unsentCallIsNeverAHold", unsentFresh.finished && !unsentFresh.hold.holds && unsentFresh.hold.unanswered == [5])

    // A quiet listen (D-1446 still asks Chrome): about 2.5 seconds in all and never a retry.
    let quiet = Fake(); quiet.budget = .quiet; quiet.op.start(); quiet.answer(.timeout, after: 1.2)
    c("quietListenNeverRetries", quiet.actions.count == 2 && quiet.actions.last == .discover(excluding: [101]))
    c("quietCallsBounded", quiet.limits.count == 2 && quiet.limits[0] == 1.2 && abs(quiet.limits[1] - 1.3) < 0.001)
    quiet.time = 2.5; quiet.op.tick()
    quiet.answer(.discovered(counts: [:], touched: [5], slow: true, refused: false, unanswered: [5]), after: 0)
    c("quietListenCappedAtTwoAndAHalf", quiet.op.finished && quiet.time == 2.5 && !quiet.op.hold.holds && quiet.actions.count == 2)
    let lateQuiet = Fake(); lateQuiet.op.start(); lateQuiet.time = 1
    var limited: MediaPauseBudget?
    lateQuiet.op.onLimit = { limited = $0 }
    lateQuiet.op.limit(to: .quiet)
    c("lateQuietListenShortensTheAsk", lateQuiet.op.budget == .quiet && limited == .quiet && abs(lateQuiet.op.remaining - 1.5) < 0.001)
    lateQuiet.op.limit(to: .heard)
    c("budgetNeverLengthens", lateQuiet.op.budget == .quiet)
    lateQuiet.time = 2.6; lateQuiet.op.tick(); lateQuiet.answer(.timeout, after: 0)
    c("lateQuietStopsAtTheCapWithoutRetry", lateQuiet.op.finished && lateQuiet.actions.count == 1 && !lateQuiet.op.hold.holds)
    c("budgetFollowsTheListen", MediaPauseBudget.after(heardSound: nil) == .heard && MediaPauseBudget.after(heardSound: true) == .heard
        && MediaPauseBudget.after(heardSound: false) == .quiet && MediaPauseBudget.heard.total == Op.totalBudget && MediaPauseBudget.heard.retries)
    c("heardSoundKeepsEightSecondsAndRetry", known.op.budget == .heard && retry.actions.count == 3)
    // Live words never wait on Chrome once the listen heard nothing.
    c("draftsNotHeldWhenQuiet", !MediaPauseBudget.openingWaitsForChrome(heardSound: false))
    c("draftsWaitWhileSoundMayBeInTheOpening", MediaPauseBudget.openingWaitsForChrome(heardSound: true) && MediaPauseBudget.openingWaitsForChrome(heardSound: nil))

    // Release: one pass. A closed tab answers empty and is cleared, a timeout is tried once and dropped.
    c("closedTabAnswersEmptyAndIsCleared", BrowserMedia.resumeCount(status: 0, output: "\n", timedOut: false) == 0)
    c("releaseAnswerRead", BrowserMedia.resumeCount(status: 0, output: "2\n", timedOut: false) == 2
        && BrowserMedia.resumeCount(status: 0, output: "1", timedOut: true) == nil && BrowserMedia.resumeCount(status: 1, output: "", timedOut: false) == nil)
    var releaseReply: ((Int?) -> Void)?, releaseTabs: [Int] = [], releaseDone: BrowserResumeOperation.Result?
    let held = MediaHold(held: [1, 2, 3], unanswered: [4, 1])
    c("holdListsEachTabOnce", held.releaseTabs == [1, 2, 3, 4] && held.holds && !MediaHold.none.holds)
    let release = BrowserResumeOperation(tabs: held.releaseTabs, now: { 0 }, allowed: { true }) { tab, _, reply in releaseTabs.append(tab); releaseReply = reply }
    release.onFinish = { releaseDone = $0 }
    release.start(); releaseReply?(1); releaseReply?(0)
    c("interruptedReleaseKeepsOnlyUnreachedHeldTabs", held.remaining(after: release.result) == MediaHold(held: [3], unanswered: []))
    releaseReply?(nil); releaseReply?(nil)
    c("releaseTriesEachTabOnce", releaseTabs == [1, 2, 3, 4] && release.finished)
    c("releaseTimeoutsAreDropped", releaseDone?.timedOut == [3, 4] && releaseDone?.resumed == [1] && releaseDone?.cleared == [2])
    c("holdNeverOutlivesOneReleasePass", releaseDone.map { held.remaining(after: $0) } == MediaHold.none)
    var pressAllowed = true, pressReply: ((Int?) -> Void)?
    let interrupted = BrowserResumeOperation(tabs: [1, 2], now: { 0 }, allowed: { pressAllowed }) { _, _, reply in pressReply = reply }
    interrupted.start(); pressAllowed = false; pressReply?(nil)
    c("noAnswerAfterANewPressIsNotATry", interrupted.finished && interrupted.result.cancelled && interrupted.result.timedOut.isEmpty && interrupted.result.waiting == [1, 2])
    var loose = MediaLooseEnds()
    loose.add(token: "a", tabs: [1, 2]); loose.add(token: "", tabs: [9]); loose.add(token: "b", tabs: [2, 3]); loose.add(token: "c", tabs: [])
    let taken = loose.take()
    c("looseEndsGetOneLookThenAreForgotten", taken?.token == "b" && taken?.inheriting == ["a"] && taken?.tabs == [1, 2, 3] && loose.isEmpty && loose.take() == nil)
    // A look a new press cut short is not a look: the tabs it never reached are kept, with every ask's token.
    if let taken {
        loose.add(token: "d", tabs: [7])
        loose.restore(taken, unreached: [2, 3, 9])
        let again = loose.take()
        c("cutShortLookKeepsUnreachedTabs", again.map { Set($0.tabs) } == [2, 3, 7] && again.map { Set($0.inheriting + [$0.token]) } == ["a", "b", "d"] && loose.isEmpty)
        loose.restore(taken, unreached: [])
        c("finishedLookRestoresNothing", loose.isEmpty && loose.take() == nil)
    }

    // Execute the actual generated JavaScript in an inert DOM with fake media and a fake wall clock.
    let scripts: [String: String] = [
        "direct": BrowserMedia.directPauseScript(token: "ours", document: "doc", expires: 8000, started: 1),
        "directNew": BrowserMedia.directPauseScript(token: "newer", document: "next", expires: 8000, started: 2, inheriting: ["ours"]),
        "seal": BrowserMedia.resumeScript(token: "ours", sealUnseen: true),
        "probe": BrowserMedia.probeScript(token: "ours", document: "doc", expires: 8000),
        "pause": BrowserMedia.pauseScript(token: "ours", document: "doc", expires: 8000),
        "resume": BrowserMedia.resumeScript(token: "ours"),
        "clear": BrowserMedia.resumeScript(token: "ours", play: false),
        "probeNew": BrowserMedia.probeScript(token: "newer", document: "next", expires: 8000, inheriting: ["ours"]),
        "pauseNew": BrowserMedia.pauseScript(token: "newer", document: "next", expires: 8000, inheriting: ["ours"]),
        "resumeNew": BrowserMedia.resumeScript(token: "newer", inheriting: ["ours"]),
        "probeOther": BrowserMedia.probeScript(token: "other", document: "foreign", expires: 8000),
        "pauseOther": BrowserMedia.pauseScript(token: "other", document: "foreign", expires: 8000),
        "resumeOther": BrowserMedia.resumeScript(token: "other")
    ]
    let js = #"""
    const fs=require('fs'),s=JSON.parse(fs.readFileSync(0,'utf8')); let time=0;
    global.Date={now:()=>time}; global.window={};
    function media(){return {paused:false,ended:false,muted:false,volume:1,isConnected:true,attrs:{},plays:0,pauses:0,
      hasAttribute(k){return k in this.attrs},getAttribute(k){return this.attrs[k]||null},setAttribute(k,v){this.attrs[k]=v},removeAttribute(k){delete this.attrs[k]},
      pause(){this.paused=true;this.pauses++},play(){this.paused=false;this.plays++;return Promise.resolve()}}}
    let items=[];global.document={querySelectorAll(q){if(q==='video,audio')return items;let token=q.match(/~=\"([^\"]+)/)[1];return items.filter(m=>(m.getAttribute('data-redpen-paused')||'').split(' ').includes(token))}};
    const run=k=>eval(s[k]),out={};
    let a=media(),b=media();b.attrs['data-redpen-paused']='other';b.__redpenOwners={other:'live'};items=[a,b];
    out.probed=run('probe')==='doc';out.first=run('pause')===2&&a.pauses===1;
    out.retry=run('pause')===2&&a.pauses===1&&a.attrs['data-redpen-paused']==='ours';
    out.otherMark=b.attrs['data-redpen-paused']==='ours'&&b.pauses===1;
    b.paused=true;out.resume=run('resume')===2&&a.plays===1&&b.plays===1;
    out.tombstone=run('pause')===-1&&a.pauses===1;
    a=media();items=[a];window={};run('probe');window={};out.navigation=run('pause')===-1&&!a.paused;
    window={};run('probe');time=8001;out.expiry=run('pause')===-1&&!a.paused;
    time=0;window={};run('probe');a.muted=true;out.recheck=run('pause')===0&&!a.paused;
    a.muted=false;run('pause');run('clear');out.pauseOnly=a.paused&&a.plays===0&&!a.hasAttribute('data-redpen-paused');
    a=media();b=media();items=[a];window={};run('probe');run('pause');items.push(b);run('resume');out.alreadyPlaying=a.paused&&a.plays===0;
    a=media();items=[a];window={};run('probe');a.pause=function(){this.pauses++};out.actualOnly=run('pause')===0&&!a.hasAttribute('data-redpen-paused');
    a=media();items=[a];window={};run('probe');run('pause');a.attrs['data-redpen-paused']+=' newer';run('resume');out.newerMark=a.paused&&a.plays===0&&a.attrs['data-redpen-paused']==='newer';
    // Failed resume A leaves its mark. Manual playback ends A, B pauses, and B can resume.
    a=media();items=[a];window={};run('probe');run('pause');a.paused=false;run('probeOther');run('pauseOther');
    out.failedAThenManualPlayThenB=run('resumeOther')===1&&a.plays===1&&!a.hasAttribute('data-redpen-paused');
    // Two live holds still protect each other. Older resume cannot play through a newer hold.
    a=media();items=[a];window={};run('probe');run('pause');run('probeOther');run('pauseOther');
    out.twoLiveMarksAdded=a.paused&&a.attrs['data-redpen-paused']==='ours other'&&a.pauses===1;
    out.twoLiveOwners=run('resume')===0&&a.paused&&a.attrs['data-redpen-paused']==='other';
    out.lastLiveOwnerReleases=run('resumeOther')===1&&!a.paused;
    // A sealed foreign owner no longer blocks our resume.
    a=media();items=[a];window={};run('probe');run('pause');a.__redpenOwners.dead='sealed';a.attrs['data-redpen-paused']+=' dead';
    out.sealedForeignDoesNotBlock=run('resume')===1&&!a.paused;
    a=media();items=[a];window={};run('probe');run('pause');run('probeNew');run('pauseNew');
    out.adoptPausedMedia=a.paused&&a.attrs['data-redpen-paused']==='newer'&&a.pauses===1;
    out.oldResumeCannotPlayNewHold=run('resume')===0&&a.paused;
    out.adoptedOwnerResumes=run('resumeNew')===1&&!a.paused;
    // Quit reconciliation runs before or after an already-dispatched pause, sealing either order.
    a=media();items=[a];window={};run('probe');run('resume');out.quitSealBeforeLatePause=run('pause')===-1&&!a.paused;
    a=media();items=[a];window={};run('probe');run('pause');out.quitSealAfterPause=run('resume')===1&&!a.paused;
    a=media();items=[a];window={};run('resume');out.unrelatedTabNoRegistry=!window.__redpenMedia;
    window={__redpenMedia:{foreign:{cancelled:false}}};run('resume');out.unrelatedRegistryNoTombstone=!window.__redpenMedia.ours;
    a=media();items=[a];window={};run('probe');run('pause');a.__redpenOwners.ours='sealed';out.manualPlaybackThenUserPauseStaysPaused=run('resume')===0&&a.paused;
    // Direct pause uses the same mark/resume rules, without a preceding probe.
    a=media();b=media();b.paused=true;items=[a,b];window={};time=0;
    out.directOneCall=run('direct')===1&&a.pauses===1&&b.pauses===0;
    out.directOnlyMarkedResumes=run('resume')===1&&a.plays===1&&b.plays===0;
    a=media();items=[a];window={};run('seal');out.directSealedBeforeArrival=run('direct')===-1&&!a.paused;
    a=media();items=[a];window={};run('directNew');out.olderDirectCannotReplaceNewer=run('direct')===-1&&a.attrs['data-redpen-paused']==='newer';
    out.olderResumeCannotPlayNewerDirect=run('resume')===0&&a.paused;
    a=media();items=[a];window={};run('direct');run('directNew');out.oldRetryCannotOverrideNewer=run('pause')===-1&&a.attrs['data-redpen-paused']==='newer';
    out.directTakeoverResumes=run('resumeNew')===1&&!a.paused;
    a=media();items=[a];window={};run('direct');window={};out.directRetryNavigation=run('pause')===-1;
    a=media();a.muted=true;b=media();b.volume=0;items=[a,b];window={};out.directIgnoresInaudible=run('direct')===0&&!a.paused&&!b.paused;
    a=media();items=[a];window={};time=8001;out.directExpired=run('direct')===-1&&!a.paused;
    // A pause that timed out can still land late, before its ask's time is up. The one look on release plays
    // back only the video that ask marked, and seals the ask so nothing lands after it.
    time=0;a=media();b=media();b.paused=true;items=[a,b];window={};run('direct');
    out.lateLandedPauseIsPlayedBackByTheLook=a.paused&&run('seal')===1&&!a.paused&&a.plays===1&&b.plays===0&&b.paused;
    out.nothingLandsAfterTheLook=run('direct')===-1&&!a.paused&&a.pauses===1;
    process.stdout.write(JSON.stringify(out));
    """#
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["node", "-e", js]
    let input = Pipe(), output = Pipe(); p.standardInput = input; p.standardOutput = output
    do {
        try p.run(); input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: scripts)); try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        let results = try JSONSerialization.jsonObject(with: data) as? [String: Bool] ?? [:]
        c("pageHarnessRan", p.terminationStatus == 0 && results.count == 38)
        for name in results.keys.sorted() { c("page." + name, results[name] == true) }
    } catch { check("browser.operation.pageHarnessRan", false, String(describing: error)) }
}
