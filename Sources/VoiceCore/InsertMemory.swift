import Foundation

/// Remembers the apps where the Accessibility insert says yes and does nothing (Nov 13 2026). In T3 Code every
/// live piece tried it, read the box back twice with a 50 ms wait, then typed anyway: 265 times in one day's log.
/// After two misses in a row in one process, live pieces there are typed directly for the rest of that process's
/// life. A new process with the same number starts clean.
public struct InsertMemory: Equatable, Sendable {
    /// One running app: its process number and when it launched, so a reused number is never mistaken for it.
    public struct App: Hashable, Sendable {
        public let pid: Int
        public let launched: Double
        public init(pid: Int, launched: Double) { self.pid = pid; self.launched = launched }
    }
    public static let missesBeforeSkip = 2
    private var missesInARow: [Int: (launched: Double, count: Int)] = [:]
    private var skipped: [Int: Double] = [:]

    public init() {}

    /// True when live pieces in this app skip the Accessibility attempt and are typed as keys.
    public func skips(_ app: App) -> Bool { skipped[app.pid] == app.launched }

    /// The app accepted the insert and nothing arrived. Returns true exactly once per process: when this miss
    /// starts the skip, for the one log line.
    public mutating func missed(_ app: App) -> Bool {
        guard !skips(app) else { return false }
        let before = missesInARow[app.pid].flatMap { $0.launched == app.launched ? $0.count : nil } ?? 0
        guard before + 1 >= Self.missesBeforeSkip else { missesInARow[app.pid] = (app.launched, before + 1); return false }
        missesInARow[app.pid] = nil
        skipped[app.pid] = app.launched
        return true
    }

    /// The insert arrived, so the misses are not in a row any more. An app already being skipped stays skipped.
    public mutating func landed(_ app: App) { missesInARow[app.pid] = nil }

    public static func == (a: InsertMemory, b: InsertMemory) -> Bool {
        a.skipped == b.skipped && a.missesInARow.mapValues { [$0.launched, Double($0.count)] } == b.missesInARow.mapValues { [$0.launched, Double($0.count)] }
    }
}
