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

    // Execute the actual generated JavaScript in an inert DOM with fake media and a fake wall clock.
    let scripts: [String: String] = [
        "probe": BrowserMedia.probeScript(token: "ours", document: "doc", expires: 8000),
        "pause": BrowserMedia.pauseScript(token: "ours", document: "doc", expires: 8000),
        "resume": BrowserMedia.resumeScript(token: "ours"),
        "clear": BrowserMedia.resumeScript(token: "ours", play: false)
    ]
    let js = #"""
    const fs=require('fs'),s=JSON.parse(fs.readFileSync(0,'utf8')); let time=0;
    global.Date={now:()=>time}; global.window={};
    function media(){return {paused:false,ended:false,muted:false,volume:1,isConnected:true,attrs:{},plays:0,pauses:0,
      hasAttribute(k){return k in this.attrs},getAttribute(k){return this.attrs[k]||null},setAttribute(k,v){this.attrs[k]=v},removeAttribute(k){delete this.attrs[k]},
      pause(){this.paused=true;this.pauses++},play(){this.paused=false;this.plays++;return Promise.resolve()}}}
    let items=[];global.document={querySelectorAll(q){if(q==='video,audio')return items;return items.filter(m=>(m.getAttribute('data-redpen-paused')||'').split(' ').includes('ours'))}};
    const run=k=>eval(s[k]),out={};
    let a=media(),b=media();b.attrs['data-redpen-paused']='other';items=[a,b];
    out.probed=run('probe')==='doc';out.first=run('pause')===2&&a.pauses===1;
    out.retry=run('pause')===2&&a.pauses===1&&a.attrs['data-redpen-paused']==='ours';
    out.otherMark=b.attrs['data-redpen-paused']==='other ours'&&b.pauses===1;
    b.paused=true;out.resume=run('resume')===1&&a.plays===1&&b.paused&&b.attrs['data-redpen-paused']==='other';
    out.tombstone=run('pause')===-1&&a.pauses===1;
    a=media();items=[a];window={};run('probe');window={};out.navigation=run('pause')===-1&&!a.paused;
    window={};run('probe');time=8001;out.expiry=run('pause')===-1&&!a.paused;
    time=0;window={};run('probe');a.muted=true;out.recheck=run('pause')===0&&!a.paused;
    a.muted=false;run('pause');run('clear');out.pauseOnly=a.paused&&a.plays===0&&!a.hasAttribute('data-redpen-paused');
    a=media();b=media();items=[a];window={};run('probe');run('pause');items.push(b);run('resume');out.alreadyPlaying=a.paused&&a.plays===0;
    a=media();items=[a];window={};run('probe');a.pause=function(){this.pauses++};out.actualOnly=run('pause')===0&&!a.hasAttribute('data-redpen-paused');
    a=media();items=[a];window={};run('probe');run('pause');a.attrs['data-redpen-paused']+=' newer';run('resume');out.newerMark=a.paused&&a.plays===0&&a.attrs['data-redpen-paused']==='newer';
    process.stdout.write(JSON.stringify(out));
    """#
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["node", "-e", js]
    let input = Pipe(), output = Pipe(); p.standardInput = input; p.standardOutput = output
    do {
        try p.run(); input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: scripts)); try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        let results = try JSONSerialization.jsonObject(with: data) as? [String: Bool] ?? [:]
        c("pageHarnessRan", p.terminationStatus == 0 && results.count == 13)
        for name in results.keys.sorted() { c("page." + name, results[name] == true) }
    } catch { check("browser.operation.pageHarnessRan", false, String(describing: error)) }
}
