import Foundation
import VoiceCore

/// Execute the actual discovery loop with inert AppleScript adapters. Never sends a Chrome AppleEvent.
func browserDiscoveryChecks(_ check: (String, Bool, String) -> Void) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("redpen-discovery-" + UUID().uuidString)
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func run(_ executable: String, _ args: [String]) throws -> (Int32, String) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: executable); p.arguments = args
            let out = Pipe(); p.standardOutput = out; p.standardError = out
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let source = root.appendingPathComponent("discovery.applescript")
        try BrowserMedia.discoveryRunner.write(to: source, atomically: true, encoding: .utf8)
        let compiled = try run("/usr/bin/osacompile", ["-o", root.appendingPathComponent("compiled.scpt").path, source.path])
        check("browser.discovery.productionAppleScriptCompiles", compiled.0 == 0, compiled.1)
        let loop = String(BrowserMedia.discoveryRunner.components(separatedBy: "on orderedTabs()")[0])
        let adapters = """
        on orderedTabs()
            return {"1388778235", "414388973", "77", "88"}
        end orderedTabs
        on tabID(t)
            return t
        end tabID
        on pauseTab(t, js)
            if t is "414388973" then error "Apple Events turned off" number -10000
            if t is "77" then return 1
            return 0
        end pauseTab
        """
        let fixture = root.appendingPathComponent("fixture.applescript")
        try (loop + adapters).write(to: fixture, atomically: true, encoding: .utf8)
        let journal = root.appendingPathComponent("tabs"), permit = root.appendingPathComponent("permit")
        try "1".write(to: permit, atomically: true, encoding: .utf8)
        try "".write(to: journal, atomically: true, encoding: .utf8)
        let start = ProcessInfo.processInfo.systemUptime
        let result = try run("/usr/bin/osascript", [fixture.path, "unused", journal.path, permit.path, "0", "1388778235"])
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let touched = try String(contentsOf: journal, encoding: .utf8).split(separator: "\n").map(String.init)
        check("browser.discovery.0623OneProcessSkipsRefusalAndPausesOtherTab", result.0 == 0 && result.1 == "77:1", result.1)
        check("browser.discovery.excludesKnownAndStopsAtFirstSuccess", touched == ["414388973", "77"], "")
        print("Browser discovery inert AppleScript elapsed_ms=\(Int(elapsed * 1000)); no live Chrome calls")
        try FileManager.default.removeItem(at: permit)
        try "".write(to: journal, atomically: true, encoding: .utf8)
        let stopped = try run("/usr/bin/osascript", [fixture.path, "unused", journal.path, permit.path, "0"])
        let stoppedJournal = try String(contentsOf: journal, encoding: .utf8)
        check("browser.discovery.revokedPermitSendsNothing", stopped.0 == 0 && stoppedJournal.isEmpty, stopped.1)
        try "1".write(to: permit, atomically: true, encoding: .utf8)
        let noSuccess = adapters.replacingOccurrences(of: "if t is \"77\" then return 1", with: "if t is \"77\" then error \"timed out\" number -1712")
        try (loop + noSuccess).write(to: fixture, atomically: true, encoding: .utf8)
        let timed = try run("/usr/bin/osascript", [fixture.path, "unused", journal.path, permit.path, "0"])
        check("browser.discovery.timeoutKeepsUncertainty", timed.0 == 0 && timed.1 == "slow", timed.1)
        // Changed on purpose (Nov 13 2026): the tab that timed out is journalled again with "!" in front, so
        // only it gets a second look on release. Every attempt is still journalled before its ask.
        let timedLines = try String(contentsOf: journal, encoding: .utf8).split(separator: "\n").map(String.init)
        check("browser.discovery.timeoutStillJournalsEveryAttempt", timedLines == ["1388778235", "414388973", "77", "!77", "88"], timedLines.joined(separator: ","))
        let read = BrowserMedia.discoveryJournal(timedLines, runnerStopped: false)
        check("browser.discovery.journalNamesOnlyTheTimedOutTab", read.touched == [1388778235, 414388973, 77, 88] && read.unanswered == [77], "")
        let cut = BrowserMedia.discoveryJournal(["5", "!5", "6"], runnerStopped: true)
        check("browser.discovery.stoppedRunnerLeavesItsLastTabUnanswered", cut.touched == [5, 6] && cut.unanswered == [5, 6], "")
    } catch { check("browser.discovery.harness", false, String(describing: error)) }
}
