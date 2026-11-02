import AppKit
import CoreAudio
import VoiceCore

/// Pauses whatever is playing while you talk, and only then. The check asks CoreAudio which apps are sending sound
/// out right now, one app at a time, and ignores sound routers like Boom 3D that keep the speakers on all day and
/// system sounds like alerts. A Mac with nothing playing never gets a play/pause press, so a paused video never
/// starts by surprise.
enum Media {
    /// An app sending sound out right now, with the CoreAudio object that lets its sound alone be listened to.
    struct Player { let name: String; let object: AudioObjectID; let pid: pid_t }

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
    static func pause(_ players: [Player], stillPaused: @escaping () -> Bool,
                      done: @escaping (Paused?, BrowserMedia.Outcome?) -> Void) {
        // Chrome said no a moment ago: the key at once, so the wait for Chrome never lengthens the cut at the start
        // of the dictation (it added about 0.6 s to every cut on Nov 2 2026).
        guard players.contains(where: { BrowserMedia.isChrome(path: path($0.pid)) }), Date() >= keyUntil else {
            pressPlayPause(); done(.key, nil); return
        }
        let token = BrowserMedia.token()
        let js = BrowserMedia.pauseScript(token: token)
        chrome.async {
            let started = Date()
            let result = run(BrowserMedia.pauseRunner, [js, "first"], limit: 4)
            Log.note("media: Chrome answered in \(Log.ms(Date().timeIntervalSince(started)))ms")
            DispatchQueue.main.async {
                if result == .scriptsOff || result == .notAllowed { keyUntil = Date().addingTimeInterval(600) }
                guard stillPaused() else {
                    if case .handled(let tabs, _) = result { resume(.chrome(token: token, tabs: tabs)) }
                    Log.note("media: pause let go of while Chrome answered, \(result)")
                    done(nil, result); return
                }
                switch result {
                case .handled(let tabs, _): done(.chrome(token: token, tabs: tabs), result)
                // Too slow to know what paused: press nothing, and the resume looks in every tab for this pause's marks.
                case .failed("timed out"), .failed("slow"): done(.chrome(token: token, tabs: []), result)
                default: pressPlayPause(); done(.key, result)
                }
            }
        }
    }

    /// Plays back what `pause` paused. Chrome tabs get their own videos back and nothing else. A Chrome pause that was
    /// too slow to say which tabs looks in every tab for its marks, so a pause that landed late still comes back; one
    /// that never got an answer at all (no token yet) presses nothing.
    static func resume(_ paused: Paused, wait: Bool = false) {
        guard case .chrome(let token, let tabs) = paused else { pressPlayPause(); return }
        guard !token.isEmpty else { return }
        let js = BrowserMedia.resumeScript(token: token)
        let work = {
            let r = tabs.isEmpty ? run(BrowserMedia.pauseRunner, [js, "every"], limit: 4)
                                 : run(BrowserMedia.resumeRunner, [js] + tabs.map(String.init))
            Log.note("media: Chrome resume\(tabs.isEmpty ? " (every tab)" : ""), \(r)")
        }
        // Quitting: finish before the app goes, but never hold the quit longer than the run's own time limit.
        if wait { chrome.sync(execute: work) } else { chrome.async(execute: work) }
    }

    /// Until when to skip asking Chrome, after it said no: ten minutes, so turning the switch on is picked up soon.
    nonisolated(unsafe) private static var keyUntil = Date.distantPast

    /// One Chrome run at a time, off the main thread: Chrome can take a moment to answer.
    private static let chrome = DispatchQueue(label: "redpen.media.chrome")

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

    private static func path(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
    }
}
