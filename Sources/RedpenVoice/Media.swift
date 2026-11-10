import AppKit
import CoreAudio
import VoiceCore

/// Pauses whatever is playing while you talk, and only then. The check asks CoreAudio which apps are sending sound
/// out right now, one app at a time, and ignores sound routers like Boom 3D that keep the speakers on all day and
/// system sounds like alerts. A Mac with nothing playing never gets a play/pause press, so a paused video never
/// starts by surprise.
enum Media {
    /// An app sending sound out right now, with the CoreAudio object that lets its sound alone be listened to.
    struct Player: Sendable { let name: String; let object: AudioObjectID; let pid: pid_t }

    /// The apps sending sound out right now that could be playing a video or a song. Sound routers, system alert
    /// sounds, Siri's listener and this app are left out, so a notification never decides a pause.
    static func playingApps() -> [Player] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var players: [Player] = []
        for id in ids {
            var out = UInt32(0), pid = pid_t(0)
            var sz = UInt32(MemoryLayout<UInt32>.size)
            addr.mSelector = kAudioProcessPropertyIsRunningOutput
            guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &out) == noErr, out != 0 else { continue }
            sz = UInt32(MemoryLayout<pid_t>.size)
            addr.mSelector = kAudioProcessPropertyPID
            guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &pid) == noErr, pid != me else { continue }
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? processName(pid)
            if MediaGate.isMedia(name) { players.append(Player(name: name, object: id, pid: pid)) }
        }
        return players
    }

    private static func processName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 1024)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? (String(cString: buf) as NSString).lastPathComponent : "pid \(pid)"
    }

    /// The same key press as the play/pause key on the keyboard.
    /// Isolated from session modifier state. Hardware checks in HoldKey reject any synthetic flag changes.
    static func pressPlayPause() {
        guard let pair = VoiceEvents.playPausePair() else { return }
        pair.down.post(tap: .cghidEventTap); pair.up.post(tap: .cghidEventTap)
    }

    /// How a pause was made, so the video comes back the same way: the key again, or the same Chrome tabs.
    enum Paused { case key, chrome(token: String, tabs: [Int]) }

    /// Pauses what is playing. Sound from Chrome is paused in its tabs (the tab showing in each window first, then
    /// every tab), so the key can't land on a paused tab and start it. Anything else, or Chrome saying no, gets the
    /// key as before. Chrome taking too long presses nothing, since some of its tabs may already be paused.
    /// `stillPaused` is asked once Chrome answers: a pause let go of meanwhile (a quit) presses nothing, puts back
    /// what Chrome paused, and hands back nil.
    /// `chromeOnly` is the pause asked for when the quick listen heard silence: Chrome is asked whether a video is
    /// playing out loud and pauses only that. Nothing found, or Chrome unable to say, presses nothing and hands back
    /// nil, since the key on a quiet Mac would start music or a paused video.
    @discardableResult
    static func pause(_ players: [Player], chromeOnly: Bool = false, owner: Int,
                      stillPaused: @escaping () -> Bool, needsPause: @escaping () -> Bool,
                      done: @escaping (Paused?, BrowserMedia.Outcome?) -> Void) -> BrowserPauseOperation? {
        guard stillPaused(), needsPause() else { return nil }
        // Keep the existing non-timeout, loud-Chrome fallback. Recovery never enters this branch again.
        guard players.contains(where: { BrowserMedia.isChrome(path: path($0.pid)) }), Date() >= keyUntil else {
            if chromeOnly { done(nil, nil); return nil }
            pressPlayPause(); done(.key, nil); return nil
        }
        return pauseBrowser(owner: owner, stillPaused: stillPaused, needsPause: needsPause,
                            chromeOnly: chromeOnly, done: done)
    }

    /// A takeover starts a fresh pass after the gesture is confirmed. Include every known candidate, not just
    /// confirmed pauses, and adopt still-paused elements before sealing their old owners.
    static func pauseBrowser(owner: Int, candidates: [Int] = [], inheritedTokens: [String] = [],
                             inheritedTabs: Set<Int> = [], stillPaused: @escaping () -> Bool,
                             needsPause: @escaping () -> Bool, chromeOnly: Bool = true,
                             done: @escaping (Paused?, BrowserMedia.Outcome?) -> Void) -> BrowserPauseOperation {
        let token = BrowserMedia.token()
        let entered = ProcessInfo.processInfo.systemUptime
        let epochEnd = Date().addingTimeInterval(BrowserPauseOperation.totalBudget).timeIntervalSince1970 * 1000
        let operation = BrowserPauseOperation(token: token, owner: owner, preferredTab: recentTab, candidates: candidates, inheritedTokens: inheritedTokens, inheritedTabs: inheritedTabs, now: { ProcessInfo.processInfo.systemUptime }) { action, limit, reply in
            chrome.async {
                // Queue time is inside the transaction budget. Recheck on the owning queue immediately before launch.
                let allowed = DispatchQueue.main.sync { stillPaused() && needsPause() }
                guard allowed else { DispatchQueue.main.async { reply(.empty) }; return }
                let args: [String]
                switch action {
                case .windows: args = ["windows"]
                case .front(let id): args = ["front", String(id)]
                case .tabs(let id): args = ["tabs", String(id)]
                case .probe(let id): args = ["page", String(id), BrowserMedia.probeScript(token: token, document: BrowserMedia.token(), expires: epochEnd, inheriting: inheritedTokens)]
                case .pause(let id, let document, _):
                    args = ["page", String(id), BrowserMedia.pauseScript(token: token, document: document, expires: epochEnd, inheriting: inheritedTokens)]
                }
                let remaining = BrowserPauseOperation.totalBudget - (ProcessInfo.processInfo.systemUptime - entered)
                guard remaining > 0 else { DispatchQueue.main.async { reply(.timeout) }; return }
                Log.note("media browser: token=\(token) phase=\(action.phase) process_start elapsed_ms=\(Log.ms(BrowserPauseOperation.totalBudget - remaining))")
                let r = runAction(args, limit: min(limit, remaining))
                DispatchQueue.main.async { reply(actionReply(action, r)) }
            }
        }
        operation.onProgress = { phase, tab, elapsed, count in
            Log.note("media browser: token=\(token) phase=\(phase) tab=\(tab.map(String.init) ?? "0") count=\(count) elapsed_ms=\(Log.ms(elapsed))")
        }
        operation.onSlow = { Log.note("media browser: token=\(token) slow=1 elapsed_ms=4000") }
        operation.onFinish = { [weak operation] in
            guard let operation else { return }
            let result = operation.outcome
            if let tab = operation.counts.keys.sorted().first { recentTab = tab }
            Log.note("media browser: token=\(token) finished state=\(operation.state) count=\(operation.counts.values.reduce(0, +)) elapsed_ms=\(Log.ms(ProcessInfo.processInfo.systemUptime - operation.entered))")
            guard stillPaused(), needsPause() else { done(nil, result); return }
            if result == .scriptsOff || result == .notAllowed { keyUntil = Date().addingTimeInterval(600) }
            switch result {
            case .handled, .failed("slow"):
                // Every dispatched candidate is reconciled, including any unacknowledged first pause.
                done(.chrome(token: token, tabs: operation.reconciliationTabs), result)
            default:
                if !operation.recovery && BrowserMedia.keyAfterQuietCheck(result, chromeOnly: chromeOnly) {
                    pressPlayPause(); done(.key, result)
                } else { done(nil, result) }
            }
        }
        Log.note("media browser: token=\(token) queue_enter elapsed_ms=0")
        DispatchQueue.main.async { operation.start() }
        DispatchQueue.main.asyncAfter(deadline: .now() + BrowserPauseOperation.slowAfter) { [weak operation] in
            guard let operation, !operation.finished else { return }; operation.tick()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + BrowserPauseOperation.totalBudget) { [weak operation] in
            guard let operation, !operation.finished else { return }; operation.tick()
        }
        return operation
    }

    struct ActionOutput { let status: Int32; let output: String; let error: String; let timedOut: Bool }
    /// The runner returns only IDs, a generated identity or a count. Errors are classified, never logged verbatim.
    private static func runAction(_ args: [String], limit: Double) -> ActionOutput {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", BrowserMedia.actionRunner] + args
        let out = Pipe(), err = Pipe(); p.standardOutput = out; p.standardError = err
        let finished = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in finished.signal() }
        do { try p.run() } catch { return ActionOutput(status: 1, output: "", error: "", timedOut: false) }
        if finished.wait(timeout: .now() + limit) == .timedOut {
            p.terminate()
            // Do not wait on an unresponsive interpreter or treat termination as AppleEvent cancellation.
            return ActionOutput(status: 1, output: "", error: "", timedOut: true)
        }
        return ActionOutput(status: p.terminationStatus,
                            output: String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                            error: String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "", timedOut: false)
    }
    static func actionReply(_ action: BrowserPauseOperation.Action, _ r: ActionOutput) -> BrowserPauseOperation.Reply {
        if r.timedOut || r.error.contains("-1712") { return .timeout }
        if r.status != 0 {
            if r.error.contains("-1743") || r.error.lowercased().contains("not authorized") { return .notAllowed }
            if r.error.contains("Apple Events") || r.error.contains("turned off") { return .refused }
            return .failed
        }
        let output = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case .windows, .front, .tabs: return .ids(output.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
        case .probe: return output.isEmpty ? .empty : .candidate(BrowserMedia.cleanIdentity(output))
        case .pause:
            guard let count = Int(output) else { return .empty }
            return count < 0 ? .navigated : .paused(count)
        }
    }

    /// Reconcile only dispatched tabs. Resume work has its own queue and a short per-action bound, so it never
    /// occupies the pause queue. A revoked action still reports what actually resumed before finishing.
    @discardableResult
    static func resume(_ paused: Paused, wait: Bool = false, play: Bool = true, inheriting: [String] = [],
                       allowed: @escaping () -> Bool = { true },
                       progress: @escaping (BrowserResumeOperation.Result) -> Void = { _ in },
                       done: @escaping (BrowserResumeOperation.Result) -> Void = { _ in }) -> BrowserResumeOperation? {
        guard case .chrome(let token, let tabs) = paused else {
            if allowed(), play { pressPlayPause() }
            done(.init(requested: [], resumed: [], cleared: [], cancelled: !allowed())); return nil
        }
        guard !token.isEmpty, !tabs.isEmpty else {
            done(.init(requested: [], resumed: [], cleared: [], cancelled: false)); return nil
        }
        let js = BrowserMedia.resumeScript(token: token, play: play, inheriting: inheriting)
        if wait {
            // Quit seals in the page instead of joining a worker waiting on the main queue. The pause operation
            // is stopped first by the caller. Its already-delivered pause sees the seal in either execution order.
            let end = ProcessInfo.processInfo.systemUptime + BrowserResumeOperation.totalBudget
            var resumed: Set<Int> = [], cleared: Set<Int> = []
            for tab in Set(tabs).sorted() {
                let left = end - ProcessInfo.processInfo.systemUptime
                guard allowed(), left > 0 else { break }
                let output = runAction(["page", String(tab), js], limit: min(left, BrowserPauseOperation.actionBudget))
                if output.status == 0, !output.timedOut, let count = Int(output.output.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    if count > 0 { resumed.insert(tab) } else { cleared.insert(tab) }
                }
            }
            done(.init(requested: Set(tabs), resumed: resumed, cleared: cleared, cancelled: !allowed())); return nil
        }
        let end = ProcessInfo.processInfo.systemUptime + BrowserResumeOperation.totalBudget
        let operation = BrowserResumeOperation(tabs: tabs, now: { ProcessInfo.processInfo.systemUptime }, allowed: allowed) { tab, limit, reply in
            reconciliation.async {
                guard DispatchQueue.main.sync(execute: allowed) else { DispatchQueue.main.async { reply(nil) }; return }
                let left = end - ProcessInfo.processInfo.systemUptime
                guard left > 0 else { DispatchQueue.main.async { reply(nil) }; return }
                let output = runAction(["page", String(tab), js], limit: min(limit, left))
                let count = output.status == 0 && !output.timedOut ? Int(output.output.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
                DispatchQueue.main.async { reply(count) }
            }
        }
        operation.onProgress = progress
        operation.onFinish = done
        DispatchQueue.main.async { operation.start() }
        return operation
    }

    /// Until when to skip asking Chrome, after it said no: ten minutes, so turning the switch on is picked up soon.
    nonisolated(unsafe) private static var recentTab: Int?
    nonisolated(unsafe) private static var keyUntil = Date.distantPast

    /// One Chrome run at a time, off the main thread: Chrome can take a moment to answer.
    private static let chrome = DispatchQueue(label: "redpen.media.chrome", qos: .userInitiated)
    private static let reconciliation = DispatchQueue(label: "redpen.media.reconcile", qos: .utility)

    /// Runs an AppleScript through osascript with the page script as an argument, never inside the script text.
    /// The Mac asks once whether Redpen Voice may control Chrome.
    private static func run(_ script: String, _ args: [String], limit: Double = 2.5) -> BrowserMedia.Outcome {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script] + args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        let finished = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in finished.signal() }
        do { try p.run() } catch { return .failed(error.localizedDescription) }
        if finished.wait(timeout: .now() + limit) == .timedOut {
            p.terminate()
            Log.note("media: Chrome took over \(limit)s, stopped asking")
            return .failed("timed out")
        }
        let o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return BrowserMedia.outcome(status: p.terminationStatus, output: o, error: e)
    }

    /// True when this sound comes from Chrome, so its tabs can be asked what is playing.
    static func isChrome(_ player: Player) -> Bool { BrowserMedia.isChrome(path: path(player.pid)) }

    private static func path(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
    }
}
