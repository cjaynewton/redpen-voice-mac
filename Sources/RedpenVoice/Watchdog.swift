import AppKit
import VoiceCore

/// Reopens Redpen Voice within a second or two if it crashes, so nobody ever has to restart it by hand. The app starts
/// a small copy of itself in watchdog mode (`--watchdog <pid>`), which waits for the app to end. A normal quit leaves a
/// note (clean-quit) and the watchdog just goes; any other ending reopens the app with `--restarted`, which says
/// "Restarted, ready" on the bar. Three crashes inside a minute and it stops trying, so a broken build can't loop.
enum Watchdog {
    /// The quit note for one running copy, by its process number, so a note from another copy never counts.
    static func cleanQuit(_ pid: pid_t) -> URL { Config.dir.appendingPathComponent("clean-quit-\(pid)") }
    static let restarts = Config.dir.appendingPathComponent("restarts.json")

    /// From the app at launch: forget the last quit note and start the watchdog. Only for the real app bundle.
    @MainActor static func start() {
        // Notes left by copies that are gone (a rebuild leaves one for the watchdog too).
        for f in (try? FileManager.default.contentsOfDirectory(atPath: Config.dir.path)) ?? [] where f.hasPrefix("clean-quit") {
            if let p = pid_t(f.replacingOccurrences(of: "clean-quit-", with: "")), kill(p, 0) == 0, p != getpid() { continue }
            try? FileManager.default.removeItem(at: Config.dir.appendingPathComponent(f))
        }
        guard Bundle.main.bundlePath.hasSuffix(".app"), let exe = Bundle.main.executableURL else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--watchdog", String(getpid())]
        do { try p.run() } catch { Log.note("watchdog: could not start, \(error.localizedDescription)") }
    }

    /// On a normal quit, so the watchdog doesn't reopen the app.
    static func markCleanQuit() { FileManager.default.createFile(atPath: cleanQuit(getpid()).path, contents: nil) }

    /// One copy at a time, decided by a lock the system releases when a copy ends (even by crashing): the copy that
    /// gets it runs, any other quits. Two copies starting at the same moment can't both see each other and both quit.
    private static var lockFile: Int32 = -1
    static func takeLock() -> Bool {
        try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
        let fd = open(Config.dir.appendingPathComponent("running.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return true }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 { close(fd); return false }
        lockFile = fd
        return true
    }

    /// Watchdog mode: wait for the app to end, then reopen it unless it quit normally. Never returns.
    static func run(parent: pid_t) -> Never {
        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        source.setEventHandler { ended(parent) }
        source.resume()
        if kill(parent, 0) != 0 { ended(parent) }  // already gone before the watch began
        dispatchMain()
    }

    private static func ended(_ parent: pid_t) {
        // Give a quitting app a moment to leave its note.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let note = cleanQuit(parent)
            if FileManager.default.fileExists(atPath: note.path) { try? FileManager.default.removeItem(at: note); exit(0) }
            let now = Date().timeIntervalSince1970
            var times = ((try? Data(contentsOf: restarts)).flatMap { try? JSONDecoder().decode([Double].self, from: $0) } ?? [])
                .filter { now - $0 < 60 }
            guard times.count < 3 else { Log.note("watchdog: three crashes in a minute, not reopening"); exit(0) }
            times.append(now)
            if let d = try? JSONEncoder().encode(times) { try? d.write(to: restarts) }
            Log.note("watchdog: the app ended without quitting, reopening")
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-n", Bundle.main.bundleURL.path, "--args", "--restarted"]
            try? open.run()
            open.waitUntilExit()
            exit(0)
        }
    }
}
