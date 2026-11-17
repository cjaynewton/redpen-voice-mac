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
    /// For Chrome the hold says which tabs are really paused and which only never answered (Nov 13 2026).
    enum Paused { case key, chrome(token: String, hold: MediaHold) }

    /// The uptime after which no pause call of one ask may keep running. Shortened, never lengthened, when the
    /// sound listen comes back quiet while a call is already out.
    final class Deadline: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TimeInterval
        init(_ value: TimeInterval) { self.value = value }
        var uptime: TimeInterval { lock.withLock { value } }
        func shorten(to earlier: TimeInterval) { lock.withLock { value = min(value, earlier) } }
    }

    /// Chrome is always paused by a page script, never by a media key. The sound-confirmed non-Chrome
    /// path retains its existing media-key behavior. A quiet check never presses a key.
    @discardableResult
    static func pause(_ players: [Player], chromeOnly: Bool = false, owner: Int,
                      stillPaused: @escaping () -> Bool, needsPause: @escaping () -> Bool,
                      done: @escaping (Paused?, BrowserMedia.Outcome?) -> Void) -> BrowserPauseOperation? {
        guard stillPaused(), needsPause() else { return nil }
        // A key is permitted only for sound-confirmed players outside Chrome.
        guard players.contains(where: { BrowserMedia.isChrome(path: path($0.pid)) }) else {
            if chromeOnly { done(nil, nil); return nil }
            pressPlayPause(); done(.key, nil); return nil
        }
        return pauseBrowser(owner: owner, stillPaused: stillPaused, needsPause: needsPause,
                            done: done)
    }

    /// A takeover starts a fresh pass after the gesture is confirmed. Include every known candidate, not just
    /// confirmed pauses, and adopt still-paused elements before sealing their old owners.
    /// `done` gets a hold only when a pause was confirmed or taken over. An ask that paused nothing hands back
    /// nil: no hold, so the next press starts fresh. One summary line is logged per ask, with measured times.
    static func pauseBrowser(owner: Int, requestedAt: TimeInterval? = nil, candidates: [Int] = [], inheritedTokens: [String] = [],
                             inheritedTabs: Set<Int> = [], budget: MediaPauseBudget = .heard,
                             stillPaused: @escaping () -> Bool,
                             needsPause: @escaping () -> Bool,
                             done: @escaping (Paused?, BrowserMedia.Outcome?) -> Void) -> BrowserPauseOperation {
        let token = BrowserMedia.token()
        let permit = FileManager.default.temporaryDirectory.appendingPathComponent("redpen-pause-permit-" + token)
        let permitCreated = FileManager.default.createFile(atPath: permit.path, contents: Data("1".utf8), attributes: [.posixPermissions: 0o600])
        let began = ProcessInfo.processInfo.systemUptime
        let entered = requestedAt ?? began
        let epochStart = Date().timeIntervalSince1970 * 1000
        // The press, on the page's clock. A page script refuses to act once its ask's time is up.
        let epochEntered = epochStart - (began - entered) * 1000
        let deadline = Deadline(entered + budget.total)
        let operation = BrowserPauseOperation(token: token, owner: owner, preferredTab: recentTab, candidates: candidates, inheritedTokens: inheritedTokens, inheritedTabs: inheritedTabs, entered: entered, budget: budget, now: { ProcessInfo.processInfo.systemUptime }) { action, limit, reply in
            chrome.async {
                // Queue time is inside the transaction budget. Recheck on the owning queue immediately before launch.
                let allowed = DispatchQueue.main.sync { stillPaused() && needsPause() }
                // Not sent, so not an answer: `.empty` here once read as "the tab answered clear" and let go of a
                // held tab that was never asked.
                guard allowed, permitCreated, FileManager.default.fileExists(atPath: permit.path) else {
                    Log.note("media browser action: owner=\(owner) reason=not_dispatched allowed=\(allowed ? 1 : 0) permit_created=\(permitCreated ? 1 : 0)")
                    DispatchQueue.main.async { reply(.unsent) }; return
                }
                let args: [String]
                let journal: URL?
                let script: String
                let remaining = deadline.uptime - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else {
                    Log.note("media browser action: owner=\(owner) reason=deadline_before_dispatch")
                    DispatchQueue.main.async { reply(.timeout) }; return
                }
                let expires = epochEntered + (deadline.uptime - entered) * 1000
                switch action {
                case .discover(let excluded):
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("redpen-pause-" + token)
                    guard FileManager.default.createFile(atPath: file.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
                        DispatchQueue.main.async { reply(.failed) }; return
                    }
                    journal = file; script = BrowserMedia.discoveryRunner
                    args = [BrowserMedia.directPauseScript(token: token, document: BrowserMedia.token(), expires: expires,
                                                          started: epochStart, inheriting: inheritedTokens), file.path, permit.path, "0"] + excluded.map(String.init)
                case .pause(let id, let document, let retry):
                    journal = nil; script = BrowserMedia.actionRunner
                    let js = retry ? BrowserMedia.pauseScript(token: token, document: document, expires: expires, inheriting: inheritedTokens)
                        : BrowserMedia.directPauseScript(token: token, document: document, expires: expires, started: epochStart, inheriting: inheritedTokens)
                    args = ["page", String(id), js]
                }
                defer { if let journal { try? FileManager.default.removeItem(at: journal) } }
                let r = runAction(args, limit: min(limit, remaining), script: script, until: deadline)
                let lines = journal.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.split(separator: "\n").map(String.init) ?? []
                let report = BrowserActionReport(action: action, status: r.status, output: r.output,
                                                 error: r.error, timedOut: r.timedOut, journal: lines)
                Log.note("media browser action: owner=\(owner) \(report.fields)")
                DispatchQueue.main.async { reply(report.reply) }
            }
        }
        operation.onStop = { try? FileManager.default.removeItem(at: permit) }
        operation.onLimit = { [weak operation] tighter in
            // A call already out is cut at the shorter time, and the ask is told when that time comes.
            deadline.shorten(to: entered + tighter.total)
            let left = max(0, deadline.uptime - ProcessInfo.processInfo.systemUptime)
            DispatchQueue.main.asyncAfter(deadline: .now() + left) { [weak operation] in
                guard let operation, !operation.finished else { return }; operation.tick()
            }
        }
        operation.onFinish = { [weak operation] in
            try? FileManager.default.removeItem(at: permit)
            guard let operation else { return }
            let result = operation.outcome
            if let tab = operation.counts.keys.sorted().first { recentTab = tab }
            let hold = operation.hold
            // One line per ask (Nov 13 2026): counts and measured times only. dispatch_ms is press to ask.
            Log.note("media browser: pause state=\(operation.state) outcome=\(outcomeWord(result)) confirmed=\(operation.counts.count) held=\(hold.held.count) unanswered=\(hold.unanswered.count) calls=\(operation.calls) timeouts=\(operation.timeouts) takeover=\(inheritedTokens.isEmpty ? 0 : 1) budget_ms=\(Log.ms(operation.budget.total)) dispatch_ms=\(Log.ms(began - entered)) elapsed_ms=\(Log.ms(ProcessInfo.processInfo.systemUptime - entered)) owner=\(owner)")
            guard stillPaused(), needsPause() else { done(nil, result); return }
            // Only a confirmed or taken-over pause is a hold. Timeouts with nothing confirmed leave none, so
            // the next press is a fresh start and never a takeover.
            done(hold.holds ? .chrome(token: token, hold: hold) : nil, result)
        }
        DispatchQueue.main.async { operation.start() }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, BrowserPauseOperation.slowAfter - (ProcessInfo.processInfo.systemUptime - entered))) { [weak operation] in
            guard let operation, !operation.finished else { return }; operation.tick()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline.uptime - ProcessInfo.processInfo.systemUptime)) { [weak operation] in
            guard let operation, !operation.finished else { return }; operation.tick()
        }
        return operation
    }

    /// A fixed word for the log, never Chrome's own error text.
    private static func outcomeWord(_ outcome: BrowserMedia.Outcome) -> String {
        switch outcome {
        case .handled: return "paused"
        case .nothingFound: return "nothing"
        case .scriptsOff: return "scriptsOff"
        case .notAllowed: return "notAllowed"
        case .failed(let why): return why == "slow" ? "slow" : "failed"
        }
    }

    struct ActionOutput { let status: Int32; let output: String; let error: String; let timedOut: Bool }
    /// The runner returns only IDs, a generated identity or a count. Errors are classified, never logged verbatim.
    private static func runAction(_ args: [String], limit: Double, script: String = BrowserMedia.actionRunner,
                                  until deadline: Deadline? = nil) -> ActionOutput {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script] + args
        let out = Pipe(), err = Pipe(); p.standardOutput = out; p.standardError = err
        let finished = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in finished.signal() }
        do { try p.run() } catch { return ActionOutput(status: 1, output: "", error: "", timedOut: false) }
        // With a deadline the wait is taken in short steps, so a shortened ask stops its call on time.
        let end = ProcessInfo.processInfo.systemUptime + limit
        var exited = false
        while !exited {
            let left = min(end, deadline?.uptime ?? end) - ProcessInfo.processInfo.systemUptime
            guard left > 0 else { break }
            exited = finished.wait(timeout: .now() + (deadline == nil ? left : min(left, 0.05))) == .success
        }
        if !exited {
            p.terminate()
            // Reap only the interpreter, never wait for Chrome. A journalled AppleEvent may still arrive.
            if finished.wait(timeout: .now() + 0.05) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.05)
            }
            return ActionOutput(status: 1, output: "", error: "", timedOut: true)
        }
        return ActionOutput(status: p.terminationStatus,
                            output: String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                            error: String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "", timedOut: false)
    }

    /// Reconcile only dispatched tabs. Resume work has its own queue and a short per-action bound, so it never
    /// occupies the pause queue. A revoked action still reports what actually resumed before finishing.
    @discardableResult
    static func resume(_ paused: Paused, wait: Bool = false, play: Bool = true, inheriting: [String] = [],
                       allowed: @escaping () -> Bool = { true },
                       progress: @escaping (BrowserResumeOperation.Result) -> Void = { _ in },
                       done: @escaping (BrowserResumeOperation.Result) -> Void = { _ in }) -> BrowserResumeOperation? {
        guard case .chrome(let token, let hold) = paused else {
            if allowed(), play { pressPlayPause() }
            done(.init(requested: [], resumed: [], cleared: [], cancelled: !allowed())); return nil
        }
        let tabs = hold.releaseTabs
        guard !token.isEmpty, !tabs.isEmpty else {
            done(.init(requested: [], resumed: [], cleared: [], cancelled: false)); return nil
        }
        let js = BrowserMedia.resumeScript(token: token, play: play, inheriting: inheriting, sealUnseen: true)
        if wait {
            // Quit seals in the page instead of joining a worker waiting on the main queue. The pause operation
            // is stopped first by the caller. Its already-delivered pause sees the seal in either execution order.
            let end = ProcessInfo.processInfo.systemUptime + BrowserResumeOperation.totalBudget
            var resumed: Set<Int> = [], cleared: Set<Int> = []
            var seen: Set<Int> = []
            for tab in tabs where seen.insert(tab).inserted {
                let left = end - ProcessInfo.processInfo.systemUptime
                guard allowed(), left > 0 else { break }
                let output = runAction(["page", String(tab), js], limit: min(left, BrowserPauseOperation.actionBudget))
                if let count = resumeCount(output) {
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
                let count = resumeCount(output)
                DispatchQueue.main.async { reply(count) }
            }
        }
        operation.onProgress = progress
        operation.onFinish = done
        DispatchQueue.main.async { operation.start() }
        return operation
    }

    static func resumeCount(_ output: ActionOutput) -> Int? {
        BrowserMedia.resumeCount(status: output.status, output: output.output, timedOut: output.timedOut)
    }

    /// The last confirmed tab is tried in one call before discovery.
    nonisolated(unsafe) private static var recentTab: Int?

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
