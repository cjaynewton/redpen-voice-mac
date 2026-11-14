import Foundation

/// Bounded reconciliation with a terminal account even when a new press revokes permission mid-action.
/// The caller serializes callbacks. A dispatched action reports before cancellation completes.
/// Each tab is tried once. A hold never outlives this one pass (Nov 13 2026).
public final class BrowserResumeOperation {
    public static let totalBudget: TimeInterval = 4
    // Chrome takes about 0.4 to 0.6 s to answer one tab (Nov 11 log). 0.2 s cut every play off before it landed.
    public static let actionBudget: TimeInterval = 1.2
    public struct Result: Equatable {
        public let requested: Set<Int>
        public let resumed: Set<Int>
        public let cleared: Set<Int>
        /// Tabs that were asked and did not answer in time. Tried once, then dropped.
        public let timedOut: Set<Int>
        public let cancelled: Bool
        public var unresolved: Set<Int> { requested.subtracting(resumed).subtracting(cleared) }
        /// Tabs the pass has not asked yet.
        public var waiting: Set<Int> { unresolved.subtracting(timedOut) }
        public init(requested: Set<Int>, resumed: Set<Int>, cleared: Set<Int>, timedOut: Set<Int> = [], cancelled: Bool) {
            self.requested = requested; self.resumed = resumed; self.cleared = cleared
            self.timedOut = timedOut.subtracting(resumed).subtracting(cleared); self.cancelled = cancelled
        }
    }
    public let tabs: [Int]
    public private(set) var finished = false
    public private(set) var inFlight: Int?
    public private(set) var cancelled = false
    public var onProgress: ((Result) -> Void)?
    public var onFinish: ((Result) -> Void)?
    private var resumed: Set<Int> = [], cleared: Set<Int> = [], timedOut: Set<Int> = []
    private var index = 0
    private let end: TimeInterval
    private let now: () -> TimeInterval
    private let allowed: () -> Bool
    private let perform: (Int, TimeInterval, @escaping (Int?) -> Void) -> Void

    public init(tabs: [Int], now: @escaping () -> TimeInterval, allowed: @escaping () -> Bool,
                perform: @escaping (Int, TimeInterval, @escaping (Int?) -> Void) -> Void) {
        var seen: Set<Int> = []
        self.tabs = tabs.filter { seen.insert($0).inserted }; self.now = now; self.allowed = allowed; self.perform = perform
        end = now() + Self.totalBudget
    }
    public var result: Result { Result(requested: Set(tabs), resumed: resumed, cleared: cleared, timedOut: timedOut, cancelled: cancelled) }
    public func start() { advance() }
    public func cancel() { cancelled = true; if inFlight == nil { finish() } }
    private func advance() {
        guard !finished, inFlight == nil else { return }
        guard !cancelled, allowed() else { cancelled = true; finish(); return }
        guard index < tabs.count, now() < end else { finish(); return }
        let tab = tabs[index]; index += 1; inFlight = tab
        perform(tab, min(Self.actionBudget, end - now())) { [self] count in
            guard inFlight == tab, !finished else { return }
            inFlight = nil
            if let count { if count > 0 { resumed.insert(tab) } else { cleared.insert(tab) } }
            // No answer after a new press revoked the pass is not a try: that press may take the tab over.
            else if !cancelled, allowed() { timedOut.insert(tab) }
            onProgress?(result)
            advance()
        }
    }
    private func finish() {
        guard !finished else { return }
        finished = true
        let completion = onFinish; onFinish = nil; completion?(result)
    }
}
