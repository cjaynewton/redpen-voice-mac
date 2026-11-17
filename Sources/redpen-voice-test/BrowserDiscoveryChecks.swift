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
        let loop = String(BrowserMedia.discoveryRunner.components(separatedBy: "on orderedTabs(")[0])
        let adapters = """
        on orderedTabs(journalPath)
            return {"1388778235", "414388973", "77", "88"}
        end orderedTabs
        on tabID(t)
            return t
        end tabID
        on pauseTab(t, js)
            if t is "414388973" then error "Apple Events turned off" number -10000
            if t is "77" then return 1
            if t is "88" then return 2
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
        check("browser.discovery.0623OneProcessSkipsRefusalAndPausesOtherTab", result.0 == 0 && result.1 == "77:1,88:2,refused", result.1)
        check("browser.discovery.excludesKnownAndKeepsBothSuccesses", touched == ["414388973", "?414388973:-10000", "77", "=77:1", "88", "=88:2"], touched.joined(separator: ","))
        let report = BrowserActionReport(action: .discover(excluding: []), status: result.0, output: result.1,
                                         error: "", timedOut: false, journal: touched)
        check("browser.discovery.productionReplyKeepsEveryPausedTab", report.reply == .discovered(counts: [77:1,88:2], touched: [77,88,414388973], slow: false, refused: true, unanswered: []), report.fields)
        // Completed successes survive process termination, even with no stdout.
        let killed = BrowserActionReport(action: .discover(excluding: []), status: 1, output: "", error: "",
                                         timedOut: true, journal: touched + ["99"])
        check("browser.discovery.killedRunnerPreservesEarlierPauses", killed.reply == .discovered(counts: [77:1,88:2], touched: [77,88,99,414388973], slow: true, refused: false, unanswered: [99], failed: true), killed.fields)
        print("Browser discovery inert AppleScript elapsed_ms=\(Int(elapsed * 1000)); no live Chrome calls")
        let nine = """
        on orderedTabs(journalPath)
            return {"1", "2", "3", "4", "5", "6", "7", "8", "9"}
        end orderedTabs
        on tabID(t)
            return t
        end tabID
        on pauseTab(t, js)
            return 1
        end pauseTab
        """
        try (loop + nine).write(to: fixture, atomically: true, encoding: .utf8)
        try "".write(to: journal, atomically: true, encoding: .utf8)
        let nineResult = try run("/usr/bin/osascript", [fixture.path, "unused", journal.path, permit.path, "0"])
        let nineLines = try String(contentsOf: journal, encoding: .utf8).split(separator: "\n").map(String.init)
        let nineReport = BrowserActionReport(action: .discover(excluding: []), status: nineResult.0,
            output: nineResult.1, error: "", timedOut: false, journal: nineLines)
        if case .discovered(let counts, _, _, _, _, _, _) = nineReport.reply {
            check("browser.discovery.nineSimulatedTabsPaused", counts == Dictionary(uniqueKeysWithValues: (1...9).map { ($0,1) }), nineReport.fields)
        } else { check("browser.discovery.nineSimulatedTabsPaused", false, nineReport.fields) }
        try FileManager.default.removeItem(at: permit)
        try "".write(to: journal, atomically: true, encoding: .utf8)
        let stopped = try run("/usr/bin/osascript", [fixture.path, "unused", journal.path, permit.path, "0"])
        let stoppedJournal = try String(contentsOf: journal, encoding: .utf8)
        check("browser.discovery.revokedPermitSendsNothing", stopped.0 == 0 && stoppedJournal.isEmpty, stopped.1)
        try "1".write(to: permit, atomically: true, encoding: .utf8)
        let noSuccess = adapters.replacingOccurrences(of: "if t is \"77\" then return 1", with: "if t is \"77\" then error \"timed out\" number -1712")
        let noSuccessOr88 = noSuccess.replacingOccurrences(of: "if t is \"88\" then return 2", with: "if t is \"88\" then return 0")
        try (loop + noSuccessOr88).write(to: fixture, atomically: true, encoding: .utf8)
        let timed = try run("/usr/bin/osascript", [fixture.path, "unused", journal.path, permit.path, "0"])
        check("browser.discovery.timeoutKeepsUncertainty", timed.0 == 0 && timed.1 == "slow,refused", timed.1)
        // Changed on purpose (Nov 13 2026): the tab that timed out is journalled again with "!" in front, so
        // only it gets a second look on release. Every attempt is still journalled before its ask.
        let timedLines = try String(contentsOf: journal, encoding: .utf8).split(separator: "\n").map(String.init)
        check("browser.discovery.timeoutStillJournalsEveryAttempt", timedLines == ["1388778235", "=1388778235:0", "414388973", "?414388973:-10000", "77", "?77:-1712", "!77", "88", "=88:0"], timedLines.joined(separator: ","))
        let read = BrowserMedia.discoveryJournal(timedLines, runnerStopped: false)
        check("browser.discovery.journalNamesOnlyTheTimedOutTab", read.touched == [1388778235, 414388973, 77, 88] && read.unanswered == [77], "")
        let cut = BrowserMedia.discoveryJournal(["5", "!5", "6"], runnerStopped: true)
        check("browser.discovery.stoppedRunnerLeavesItsLastTabUnanswered", cut.touched == [5, 6] && cut.unanswered == [5, 6], "")
    } catch { check("browser.discovery.harness", false, String(describing: error)) }
}
