import AppKit

/// Reopens Redpen Voice within a second or two if it crashes, so nobody ever has to restart it by hand. The app starts
/// a small copy of itself in watchdog mode (`--watchdog <pid>`), which waits for the app to end. A normal quit leaves a
/// note (clean-quit) and the watchdog just goes; any other ending reopens the app with `--restarted`, which says
/// "Restarted, ready" on the bar. Three crashes inside a minute and it stops trying, so a broken build can't loop.
enum Watchdog {
    static let cleanQuit = Config.dir.appendingPathComponent("clean-quit")
    static let restarts = Config.dir.appendingPathComponent("restarts.json")

    /// From the app at launch: forget the last quit note and start the watchdog. Only for the real app bundle.
    @MainActor static func start() {
        try? FileManager.default.removeItem(at: cleanQuit)
        guard Bundle.main.bundlePath.hasSuffix(".app"), let exe = Bundle.main.executableURL else { return }
        let p = Process()
        p.executableURL = exe
        p.arguments = ["--watchdog", String(getpid())]
        do { try p.run() } catch { Log.note("watchdog: could not start, \(error.localizedDescription)") }
    }

    /// On a normal quit, so the watchdog doesn't reopen the app.
    static func markCleanQuit() { FileManager.default.createFile(atPath: cleanQuit.path, contents: nil) }

    /// Watchdog mode: wait for the app to end, then reopen it unless it quit normally. Never returns.
    static func run(parent: pid_t) -> Never {
        let source = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        source.setEventHandler { ended() }
        source.resume()
        if kill(parent, 0) != 0 { ended() }  // already gone before the watch began
        dispatchMain()
    }

    private static func ended() {
        // Give a quitting app a moment to leave its note.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if FileManager.default.fileExists(atPath: cleanQuit.path) { exit(0) }
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
