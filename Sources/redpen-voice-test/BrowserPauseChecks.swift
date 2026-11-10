import Foundation
import VoiceCore

/// Passive fakes drive the same transaction used by Media. No AppleEvents, hardware or ASR.
func browserPauseChecks(_ check: (String, Bool, String) -> Void) {
    typealias Op = BrowserPauseOperation
    final class Fake {
        var time: Double = 0
        var actions: [Op.Action] = []
        var reply: ((Op.Reply) -> Void)?
        var finishes = 0, slows = 0
        lazy var op: Op = {
            let result = Op(token: "fake", owner: 1, now: { self.time }) { action, limit, done in
                self.actions.append(action); self.reply = done
                precondition(limit > 0 && limit <= Op.actionBudget)
            }
            result.onFinish = { self.finishes += 1 }; result.onSlow = { self.slows += 1 }
            return result
        }()
        func answer(_ value: Op.Reply, after: Double = 0.1) {
            time += after; let callback = reply; reply = nil; callback?(value)
        }
        func candidate() {
            op.start(); answer(.ids([10])); answer(.ids([101])); answer(.candidate("doc"))
        }
    }
    func c(_ name: String, _ value: Bool) { check("browser.operation." + name, value, "") }
    let slow = Fake(); slow.op.start()
    slow.answer(.ids([1,2,3,4,5]), after: 0.1)
    for _ in 0..<5 { slow.answer(.timeout, after: 1) }
    c("discoveryOverFourContinues", slow.op.slow && slow.slows == 1 && !slow.op.finished && slow.actions.count == 7)
    slow.time = 8; slow.op.tick(); slow.answer(.timeout, after: 0)
    c("budgetStopsDiscovery", slow.op.finished && slow.finishes == 1 && slow.op.uncertain && slow.actions.count == 7)

    let failures = Fake(); failures.op.start(); failures.answer(.ids([10])); failures.answer(.ids([1,2,3,4]))
    for _ in 0..<3 { failures.answer(.timeout, after: 1) }
    failures.answer(.candidate("doc")); failures.answer(.paused(1))
    c("severalTabFailuresThenSuccess", failures.op.counts == [4:1] && failures.finishes == 1)
    c("partialSuccessNotHiddenByLaterTab", failures.actions.last == .pause(4, document: "doc", retry: false))

    let partial = Fake(); partial.op.start(); partial.answer(.ids([10])); partial.answer(.ids([1,2]))
    partial.answer(.candidate("first")); partial.answer(.paused(1))
    c("partialVisibleBeforeLaterAnswer", partial.op.counts == [1:1] && !partial.op.finished && partial.actions.last == .probe(2))
    partial.time = 8; partial.answer(.timeout, after: 0)
    c("partialPauseThenTimeout", partial.op.finished && partial.op.outcome == .handled(tabs: [1], count: 1))
    let multi = Fake(); multi.op.start(); multi.answer(.ids([10,20])); multi.answer(.ids([1]))
    multi.answer(.candidate("first")); multi.answer(.paused(1)); multi.answer(.ids([2]))
    multi.answer(.candidate("second")); multi.answer(.paused(1))
    c("sameGroupPausesMultipleWindows", multi.op.finished && multi.op.counts == [1:1,2:1])

    let late = Fake(); late.candidate(); late.time = 5.2; late.op.tick()
    var audio = MediaOpening(); audio.hold(at: Date(timeIntervalSince1970: 0))
    c("audioFallbackAtFive", audio.ready(at: Date(timeIntervalSince1970: 5)) && audio.keepsOriginal)
    late.answer(.paused(1), after: 0.1)
    audio.include(through: 999)
    c("lateSuccessIndependentOfAudio", late.op.state == .confirmed && late.op.slow && late.op.counts == [101:1] && audio.through == 0 && !audio.acceptsCleanup)

    for cancelled in [false, true] {
        let f = Fake(); f.candidate(); let sent = f.actions.count
        f.op.stop(cancelled: cancelled); f.answer(.paused(1))
        c("stopOrCancelNoNewPause.\(cancelled)", f.actions.count == sent && f.finishes == 1 && f.op.counts == [101:1])
        if cancelled { c("cancelledStatePreserved", f.op.state == .cancelled) }
    }
    let transfer = Fake(); transfer.candidate(); let sent = transfer.actions.count
    transfer.op.transfer(to: 2); transfer.answer(.paused(1))
    c("newOwnerKeepsTokenOnly", transfer.op.owner == 2 && transfer.op.state == .transferred && transfer.op.token == "fake" && transfer.actions.count == sent)

    let retry = Fake(); retry.candidate(); retry.answer(.timeout)
    c("sameCandidateOneRetry", retry.actions.last == .pause(101, document: "doc", retry: true))
    retry.answer(.timeout)
    c("retryNeverRepeats", retry.actions.filter { if case .pause = $0 { return true }; return false }.count == 2)
    retry.op.stop(); c("retryRecoveryNoKey", retry.op.recovery && retry.op.outcome == .failed("slow"))
    let nav = Fake(); nav.candidate(); nav.answer(.navigated); nav.op.stop()
    c("navigationNoRetry", nav.actions.filter { if case .pause = $0 { return true }; return false }.count == 1)
    let refused = Fake(); refused.op.start(); refused.answer(.refused)
    c("refusalReported", refused.op.outcome == .scriptsOff && !refused.op.recovery)
    let afterTimeout = Fake(); afterTimeout.candidate(); afterTimeout.answer(.timeout); afterTimeout.answer(.refused); afterTimeout.op.stop()
    c("recoveryRefusalNeverKey", afterTimeout.op.recovery && afterTimeout.op.outcome == .failed("slow"))
    let boundary = Fake(); boundary.candidate(); boundary.time = 8; boundary.answer(.paused(1), after: 0)
    c("partialPauseAtTimeoutRetained", boundary.op.finished && boundary.op.counts == [101:1] && boundary.finishes == 1)
    let queued = Fake(); _ = queued.op
    queued.time = 9; queued.op.start()
    c("queueTimeCounts", queued.op.finished && queued.actions.isEmpty)
    let cached = Op(token: "cached", owner: 1, preferredTab: 51, now: { 0 }) { action, _, reply in
        if action == .probe(51) { reply(.empty) } else { reply(.ids([])) }
    }
    cached.start()
    c("cachedTabCheckedBeforeDiscovery", cached.finished && cached.counts.isEmpty && cached.touched.isEmpty)
    let duplicate = Fake(); duplicate.candidate(); duplicate.answer(.timeout); duplicate.answer(.timeout)
    duplicate.answer(.ids([101]))
    c("sameTabNotRetriedByBackgroundScan", duplicate.op.finished && duplicate.actions.filter { if case .pause = $0 { return true }; return false }.count == 2)
    var ownership = MediaPauseOwnership(); ownership.hold(); let oldOwner = ownership.generation
    ownership.hold(); transfer.op.transfer(to: ownership.generation)
    c("oldCompletionCannotOwnNewRecording", !ownership.owns(oldOwner) && ownership.owns(transfer.op.owner))
    c("anotherAppPreventsResume", !MediaGate.shouldResume(paused: true, playingNow: true))
    var keys = TalkKeyState(); var pauses = 0
    _ = keys.event(key: 63, down: true, at: 0)
    _ = keys.event(key: 63, down: false, at: 0.1)
    if keys.canPauseMedia(at: 0.5) { pauses += 1 }
    c("quickTapNoDispatch", pauses == 0)

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
    // A new owner rechecks all requested tabs, even ones the previous resume already played.
    let inherited = Op(token: "new", owner: 2, candidates: resume.tabs, inheritedTokens: ["old"],
                       inheritedTabs: resume.result.unresolved, now: { 0 }) { action, _, reply in
        switch action {
        case .probe(let id): reply(.candidate("doc" + String(id)))
        case .pause: reply(.paused(1))
        default: reply(.ids([]))
        }
    }
    inherited.start()
    c("takeoverRepausesResumedAndAdoptsRemaining", inherited.finished && inherited.counts == [1: 1, 2: 1, 3: 1] && inherited.reconciliationTabs == [1, 2, 3])
    let mid = Fake(); mid.op.start(); mid.answer(.ids([10])); mid.answer(.ids([1,2])); mid.answer(.candidate("first"))
    mid.op.transfer(to: 2); mid.answer(.paused(1))
    c("transferRetainsRemainingCandidates", mid.op.candidates == [1,2] && mid.op.counts == [1:1])
    var secondPauses: [Int] = []
    let second = Op(token: "second", owner: 2, candidates: mid.op.candidates.sorted(), inheritedTokens: [mid.op.token],
                    inheritedTabs: Set(mid.op.reconciliationTabs), now: { 0 }) { action, _, reply in
        switch action {
        case .probe: reply(.candidate("doc"))
        case .pause(let id, _, _): secondPauses.append(id); reply(.paused(1))
        default: reply(.ids([]))
        }
    }
    second.start()
    c("transferredPassPausesRemainingCandidates", secondPauses == [1,2] && second.counts == [1:1,2:1])
    let undiscovered = Op(token: "next", owner: 2, candidates: [1], inheritedTokens: ["old"], now: { 0 }) { action, _, reply in
        switch action {
        case .windows: reply(.ids([10,20]))
        case .front(let id): reply(.ids([id == 10 ? 1 : 2]))
        case .probe: reply(.candidate("doc"))
        case .pause: reply(.paused(1))
        default: reply(.ids([]))
        }
    }
    undiscovered.start()
    c("takeoverStillDiscoversUnvisitedFrontWindows", undiscovered.finished && undiscovered.counts == [1:1,2:1])
    let quit = Fake(); quit.candidate(); quit.op.stop(cancelled: true)
    c("quitSealIncludesInFlightTab", !quit.op.finished && quit.op.reconciliationTabs == [101] && !quit.op.canDispatch)
    quit.answer(.paused(1))
    c("quitLateReplyCannotDispatchAgain", quit.op.finished && quit.op.reconciliationTabs == [101] && quit.actions.count == 4)

    // Execute the actual generated JavaScript in an inert DOM with fake media and a fake wall clock.
    let scripts: [String: String] = [
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
    process.stdout.write(JSON.stringify(out));
    """#
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["node", "-e", js]
    let input = Pipe(), output = Pipe(); p.standardInput = input; p.standardOutput = output
    do {
        try p.run(); input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: scripts)); try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        let results = try JSONSerialization.jsonObject(with: data) as? [String: Bool] ?? [:]
        c("pageHarnessRan", p.terminationStatus == 0 && results.count == 26)
        for name in results.keys.sorted() { c("page." + name, results[name] == true) }
    } catch { check("browser.operation.pageHarnessRan", false, String(describing: error)) }
}
