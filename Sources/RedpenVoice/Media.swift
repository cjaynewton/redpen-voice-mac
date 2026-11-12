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
    static func pauseBrowser(owner: Int, requestedAt: TimeInterval? = nil, candidates: [Int] = [], inheritedTokens: [String] = [],
                             inheritedTabs: Set<Int> = [], stillPaused: @escaping () -> Bool,
                             needsPause: @escaping () -> Bool,
                             done: @escaping (Paused?, BrowserMedia.Outcome?) -> Void) -> BrowserPauseOperation {
        let token = BrowserMedia.token()
        let permit = FileManager.default.temporaryDirectory.appendingPathComponent("redpen-pause-permit-" + token)
        let permitCreated = FileManager.default.createFile(atPath: permit.path, contents: Data("1".utf8), attributes: [.posixPermissions: 0o600])
        let entered = requestedAt ?? ProcessInfo.processInfo.systemUptime
        let epochStart = Date().timeIntervalSince1970 * 1000
        let leftAtStart = max(0, BrowserPauseOperation.totalBudget - (ProcessInfo.processInfo.systemUptime - entered))
        let epochEnd = epochStart + leftAtStart * 1000
        let operation = BrowserPauseOperation(token: token, owner: owner, preferredTab: recentTab, candidates: candidates, inheritedTokens: inheritedTokens, inheritedTabs: inheritedTabs, entered: entered, now: { ProcessInfo.processInfo.systemUptime }) { action, limit, reply in
            chrome.async {
                // Queue time is inside the transaction budget. Recheck on the owning queue immediately before launch.
                let allowed = DispatchQueue.main.sync { stillPaused() && needsPause() }
                guard allowed, permitCreated, FileManager.default.fileExists(atPath: permit.path) else { DispatchQueue.main.async { reply(.empty) }; return }
                let args: [String]
                let journal: URL?
                let script: String
                switch action {
                case .discover(let excluded):
                    let file = FileManager.default.temporaryDirectory.appendingPathComponent("redpen-pause-" + token)
                    guard FileManager.default.createFile(atPath: file.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
                        DispatchQueue.main.async { reply(.failed) }; return
                    }
                    journal = file; script = BrowserMedia.discoveryRunner
                    args = [BrowserMedia.directPauseScript(token: token, document: BrowserMedia.token(), expires: epochEnd,
                                                          started: epochStart, inheriting: inheritedTokens), file.path, permit.path, "0"] + excluded.map(String.init)
                case .pause(let id, let document, let retry):
                    journal = nil; script = BrowserMedia.actionRunner
                    let js = retry ? BrowserMedia.pauseScript(token: token, document: document, expires: epochEnd, inheriting: inheritedTokens)
                        : BrowserMedia.directPauseScript(token: token, document: document, expires: epochEnd, started: epochStart, inheriting: inheritedTokens)
                    args = ["page", String(id), js]
                }
                defer { if let journal { try? FileManager.default.removeItem(at: journal) } }
                let remaining = BrowserPauseOperation.totalBudget - (ProcessInfo.processInfo.systemUptime - entered)
                guard remaining > 0 else { DispatchQueue.main.async { reply(.timeout) }; return }
                Log.note("media browser: token=\(token) phase=\(action.phase) process_start elapsed_ms=\(Log.ms(BrowserPauseOperation.totalBudget - remaining))")
                let r = runAction(args, limit: min(limit, remaining), script: script)
                let touched = journal.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.split(separator: "\n").compactMap { Int($0) } ?? []
                let result = actionReply(action, r, touched: touched)
                DispatchQueue.main.async { reply(result) }
            }
        }
        operation.onStop = { try? FileManager.default.removeItem(at: permit) }
        operation.onProgress = { phase, tab, elapsed, count in
            Log.note("media browser: token=\(token) phase=\(phase) tab=\(tab.map(String.init) ?? "0") count=\(count) elapsed_ms=\(Log.ms(elapsed))")
        }
        operation.onSlow = { Log.note("media browser: token=\(token) slow=1 elapsed_ms=4000") }
        operation.onFinish = { [weak operation] in
            try? FileManager.default.removeItem(at: permit)
            guard let operation else { return }
            let result = operation.outcome
            if let tab = operation.counts.keys.sorted().first { recentTab = tab }
            Log.note("media browser: token=\(token) finished state=\(operation.state) count=\(operation.counts.values.reduce(0, +)) elapsed_ms=\(Log.ms(ProcessInfo.processInfo.systemUptime - operation.entered))")
            guard stillPaused(), needsPause() else { done(nil, result); return }
            switch result {
            case .handled, .failed("slow"):
                // Every dispatched candidate is reconciled, including any unacknowledged first pause.
                done(.chrome(token: token, tabs: operation.reconciliationTabs), result)
            default:
                done(nil, result)
            }
        }
        Log.note("media browser: token=\(token) queue_enter elapsed_ms=0")
        DispatchQueue.main.async { operation.start() }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, BrowserPauseOperation.slowAfter - (ProcessInfo.processInfo.systemUptime - entered))) { [weak operation] in
            guard let operation, !operation.finished else { return }; operation.tick()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + leftAtStart) { [weak operation] in
            guard let operation, !operation.finished else { return }; operation.tick()
        }
        return operation
    }

    struct ActionOutput { let status: Int32; let output: String; let error: String; let timedOut: Bool }
    /// The runner returns only IDs, a generated identity or a count. Errors are classified, never logged verbatim.
    private static func runAction(_ args: [String], limit: Double, script: String = BrowserMedia.actionRunner) -> ActionOutput {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script] + args
        let out = Pipe(), err = Pipe(); p.standardOutput = out; p.standardError = err
        let finished = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in finished.signal() }
        do { try p.run() } catch { return ActionOutput(status: 1, output: "", error: "", timedOut: false) }
        if finished.wait(timeout: .now() + limit) == .timedOut {
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
    static func actionReply(_ action: BrowserPauseOperation.Action, _ r: ActionOutput, touched: [Int] = []) -> BrowserPauseOperation.Reply {
        if case .discover = action {
            let output = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let bits = output.split(separator: ":")
            let tab = bits.count == 2 ? Int(bits[0]) : nil
            let count = bits.count == 2 ? Int(bits[1]) ?? 0 : 0
            return .discovered(tab: tab, count: count, touched: touched,
                slow: r.timedOut || r.status != 0 || output == "slow",
                refused: output == "refused" || r.error.contains("-1743"))
        }
        if r.timedOut || r.error.contains("-1712") { return .timeout }
        if r.status != 0 {
            if r.error.contains("-1743") || r.error.lowercased().contains("not authorized") { return .notAllowed }
            if r.error.contains("Apple Events") || r.error.contains("turned off") { return .refused }
            return .failed
        }
        let output = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case .discover: return .empty
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
                let started = ProcessInfo.processInfo.systemUptime
                let output = runAction(["page", String(tab), js], limit: min(limit, left))
                let count = output.status == 0 && !output.timedOut ? Int(output.output.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
                if count == nil {
                    let ms = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                    Log.note("media browser: resume tab=\(tab) no answer timed_out=\(output.timedOut) status=\(output.status) elapsed_ms=\(ms)")
                }
                DispatchQueue.main.async { reply(count) }
            }
        }
        operation.onProgress = progress
        operation.onFinish = done
        DispatchQueue.main.async { operation.start() }
        return operation
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
