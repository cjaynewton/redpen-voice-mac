import Foundation

/// One browser control transaction. Callbacks and ownership changes are serialized by the caller.
/// Audio cleanup has its own, shorter deadline and never consults this transaction's state.
public final class BrowserPauseOperation {
    public static let totalBudget: TimeInterval = 8
    public static let slowAfter: TimeInterval = 4
    public static let actionBudget: TimeInterval = 1.2
    public enum State: Equatable { case pending, confirmed, uncertain, cancelled, transferred }
    public enum Action: Equatable {
        case pause(Int, document: String, retry: Bool)
        case discover(excluding: [Int])
    }
    public enum Reply: Equatable {
        case ids([Int]), candidate(String), paused(Int)
        case empty, navigated, timeout, refused, notAllowed, failed
        /// The call was never sent to Chrome: the ask was stopped or handed on while the call waited its turn.
        /// The page said nothing, so a tab of a hold this ask took over stays held.
        case unsent
        /// `unanswered` lists the tabs that timed out, when the runner could say. nil means unknown: on a slow
        /// result every tab it touched then counts as unanswered.
        case discovered(counts: [Int: Int], touched: [Int], slow: Bool, refused: Bool, unanswered: [Int]? = nil, failed: Bool = false, notAllowed: Bool = false)
    }
    public let token: String
    public let entered: TimeInterval
    public private(set) var owner: Int
    public private(set) var state: State = .pending
    public private(set) var slow = false
    public private(set) var finished = false
    public private(set) var inFlight: Action?
    public private(set) var counts: [Int: Int] = [:]
    public private(set) var touched: Set<Int> = []
    /// Tabs whose page answered, so no pause script of this ask can still be waiting there.
    public private(set) var answered: Set<Int> = []
    /// How long this ask may run and whether a timed-out known tab is asked again. Only ever shortened.
    public private(set) var budget: MediaPauseBudget
    /// Browser calls made and how many timed out, for the one summary log line.
    public private(set) var calls = 0, timeouts = 0
    public private(set) var candidates: Set<Int> = []
    public let inheritedTokens: [String]
    public let inheritedTabs: Set<Int>
    public private(set) var uncertain = false
    public private(set) var recovery = false
    public private(set) var refusal: Reply?
    public var onStop: (() -> Void)?
    public var onFinish: (() -> Void)?
    public var onSettled: (() -> Void)?
    public var onSlow: (() -> Void)?
    public var onLimit: ((MediaPauseBudget) -> Void)?
    public var onProgress: ((String, Int?, TimeInterval, Int) -> Void)?
    private let now: () -> TimeInterval
    private let perform: (Action, TimeInterval, @escaping (Reply) -> Void) -> Void
    private var queue: [Action] = []
    private var stopped = false

    public init(token: String, owner: Int, preferredTab: Int? = nil, candidates: [Int] = [],
                inheritedTokens: [String] = [], inheritedTabs: Set<Int> = [], entered: TimeInterval? = nil,
                budget: MediaPauseBudget = .heard, now: @escaping () -> TimeInterval,
                perform: @escaping (Action, TimeInterval, @escaping (Reply) -> Void) -> Void) {
        self.token = token; self.owner = owner; self.now = now; self.perform = perform; self.budget = budget
        self.inheritedTokens = inheritedTokens; self.inheritedTabs = inheritedTabs
        self.candidates = Set(candidates)
        self.entered = entered ?? now()
        var known = candidates
        if let preferredTab { known.insert(preferredTab, at: 0) }
        var seen: Set<Int> = []
        queue = known.filter { seen.insert($0).inserted }.map { .pause($0, document: BrowserMedia.token(), retry: false) }
        queue.append(.discover(excluding: []))
    }
    /// What this ask leaves behind. A confirmed pause, or a tab of the hold it took over that has not answered
    /// clear, is held. A tab that was sent a pause and never answered is only a loose end (Nov 13 2026).
    public var hold: MediaHold {
        let held = counts.keys.sorted() + inheritedTabs.subtracting(answered).subtracting(counts.keys).sorted()
        return MediaHold(held: held, unanswered: touched.subtracting(answered).subtracting(held).sorted())
    }
    /// The tabs one release pass looks at: held first, then those that never answered. A tab that answered
    /// with nothing playing is finished with and is not asked again.
    public var reconciliationTabs: [Int] { hold.releaseTabs }
    public var reconciliationTokens: [String] { inheritedTokens + [token] }
    public var remaining: TimeInterval { max(0, budget.total - (now() - entered)) }
    /// The listen came back quiet after this ask began: shorten it. Never lengthens.
    public func limit(to tighter: MediaPauseBudget) {
        guard !finished else { return }
        budget = MediaPauseBudget(total: min(budget.total, tighter.total), retries: budget.retries && tighter.retries)
        if !budget.retries { queue.removeAll { if case .pause(_, _, true) = $0 { return true }; return false } }
        onLimit?(budget)
        tick()
    }
    public var canDispatch: Bool { !stopped && !finished && remaining > 0 }
    public func start() { advance() }
    public func tick() {
        if !slow && now() - entered >= Self.slowAfter {
            slow = true; recovery = true; onSlow?()
        }
        if remaining == 0 { uncertain = true; stopped = true; onStop?(); queue.removeAll(); settleIfIdle() }
    }
    /// Stop sends no further pauses. An already-sent action still has to report so its token can be reconciled.
    public func stop(cancelled: Bool = false) {
        stopped = true; onStop?(); queue.removeAll()
        state = cancelled ? .cancelled : (counts.isEmpty ? .uncertain : .confirmed)
        settleIfIdle()
    }
    /// Retain all discovered candidates for the new owner's fresh, confirmed pause pass.
    public func transfer(to owner: Int) {
        self.owner = owner; stopped = true; onStop?(); queue.removeAll(); state = .transferred
        settleIfIdle()
    }
    public var outcome: BrowserMedia.Outcome {
        if !counts.isEmpty { return .handled(tabs: counts.keys.sorted(), count: counts.values.reduce(0, +)) }
        if uncertain || slow { return .failed("slow") }
        if refusal == .notAllowed { return .notAllowed }
        if refusal == .refused { return .scriptsOff }
        if refusal == .failed { return .failed("browser action failed") }
        return .nothingFound
    }
    private func advance() {
        tick()
        guard canDispatch, inFlight == nil, !queue.isEmpty else { settleIfIdle(); return }
        var action = queue.removeFirst()
        if case .discover = action { action = .discover(excluding: touched.sorted()) }
        if case .pause(let id, _, _) = action { touched.insert(id); candidates.insert(id) }
        inFlight = action; calls += 1
        let tab: Int?
        switch action { case .pause(let id, _, _): tab = id; default: tab = nil }
        onProgress?("\(action.phase)-dispatch", tab, now() - entered, 0)
        let limit: TimeInterval
        if case .discover = action { limit = remaining } else { limit = min(Self.actionBudget, remaining) }
        perform(action, limit) { [self] reply in receive(reply, for: action) }
    }
    private func receive(_ reply: Reply, for action: Action) {
        guard inFlight == action else { return }
        tick()
        inFlight = nil
        let tab: Int?
        switch action { case .pause(let id, _, _): tab = id; default: tab = nil }
        onProgress?("\(action.phase)-result-\(reply.code)", tab, now() - entered, reply.count)
        // Even a cancelled or transferred request can have paused. Keep its partial evidence for reconciliation.
        if case .pause(let id, _, _) = action, case .paused(let count) = reply, count > 0 { counts[id] = count }
        // Any answer but a timeout means the page ran the script or never will: nothing waits in that tab.
        // A call that was never sent is no answer at all.
        if case .pause(let id, _, _) = action, reply != .timeout, reply != .unsent { answered.insert(id) }
        if case .discovered(let discovered, let tried, let slow, let refused, let unanswered, let failed, let notAllowed) = reply {
            touched.formUnion(tried); candidates.formUnion(tried)
            for (tab, count) in discovered where count > 0 {
                counts[tab] = count; touched.insert(tab); candidates.insert(tab); answered.insert(tab)
            }
            if let unanswered { answered.formUnion(Set(tried).subtracting(unanswered)); timeouts += unanswered.count }
            else if !slow { answered.formUnion(tried) }
            else { timeouts += 1 }
            if slow { uncertain = true; recovery = true }
            if refused { refusal = .refused }
            if failed { refusal = .failed }
            if notAllowed { refusal = .notAllowed; queue.removeAll() }
        }
        if reply == .timeout { uncertain = true; recovery = true; timeouts += 1 }
        if reply == .refused || reply == .notAllowed || reply == .failed { refusal = reply }
        guard canDispatch else { settleIfIdle(); return }
        if budget.retries, case .pause(let id, let document, false) = action, reply == .timeout {
            queue.insert(.pause(id, document: document, retry: true), at: 0)
        }
        // A known tab can pause first, but discovery must still check the other playing tabs.
        // The same deadline/cancellation rules bound both normal and takeover passes.
        if reply == .notAllowed { queue.removeAll() }
        advance()
    }
    private func settleIfIdle() {
        guard !finished, inFlight == nil, stopped || queue.isEmpty else { return }
        finished = true
        if state != .cancelled && state != .transferred { state = uncertain || refusal != nil ? .uncertain : (counts.isEmpty ? .pending : .confirmed) }
        let finish = onFinish; onFinish = nil
        finish?()
        let settled = onSettled; onSettled = nil
        settled?()
    }
}

extension BrowserPauseOperation.Reply {
    public var count: Int {
        switch self { case .ids(let ids): return ids.count; case .paused(let count): return count; case .discovered(let counts, _, _, _, _, _, _): return counts.values.reduce(0, +); default: return 0 }
    }
    /// Only fixed labels and numbers may reach progress logs.
    public var code: Int {
        switch self {
        case .ids: return 0; case .candidate: return 1; case .paused: return 2; case .empty: return 3
        case .navigated: return 4; case .timeout: return 5; case .refused: return 6; case .notAllowed: return 7; case .failed: return 8; case .discovered: return 9; case .unsent: return 10
        }
    }
}

extension BrowserPauseOperation.Action {
    public var phase: String {
        switch self {
        case .discover: return "discovery-pause"
        case .pause(_, _, let retry): return retry ? "retry" : "pause"
        }
    }
}
