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
        case discovered(tab: Int?, count: Int, touched: [Int], slow: Bool, refused: Bool)
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
    public var onProgress: ((String, Int?, TimeInterval, Int) -> Void)?
    private let now: () -> TimeInterval
    private let perform: (Action, TimeInterval, @escaping (Reply) -> Void) -> Void
    private var queue: [Action] = []
    private var stopped = false
    private let needsTakeoverDiscovery: Bool

    public init(token: String, owner: Int, preferredTab: Int? = nil, candidates: [Int] = [],
                inheritedTokens: [String] = [], inheritedTabs: Set<Int> = [], entered: TimeInterval? = nil, now: @escaping () -> TimeInterval,
                perform: @escaping (Action, TimeInterval, @escaping (Reply) -> Void) -> Void) {
        self.token = token; self.owner = owner; self.now = now; self.perform = perform
        self.inheritedTokens = inheritedTokens; self.inheritedTabs = inheritedTabs
        needsTakeoverDiscovery = !inheritedTokens.isEmpty
        self.candidates = Set(candidates)
        self.entered = entered ?? now()
        var known = candidates
        if let preferredTab { known.insert(preferredTab, at: 0) }
        var seen: Set<Int> = []
        queue = known.filter { seen.insert($0).inserted }.map { .pause($0, document: BrowserMedia.token(), retry: false) }
        queue.append(.discover(excluding: []))
    }
    public var reconciliationTabs: [Int] {
        // A batch may visit many empty tabs. Reconcile confirmed pauses before spending time on uncertain ones.
        counts.keys.sorted() + touched.union(inheritedTabs).subtracting(counts.keys).sorted()
    }
    public var reconciliationTokens: [String] { inheritedTokens + [token] }
    public var remaining: TimeInterval { max(0, Self.totalBudget - (now() - entered)) }
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
        inFlight = action
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
        if case .discovered(let tab, let count, let tried, let slow, let refused) = reply {
            touched.formUnion(tried); candidates.formUnion(tried)
            if let tab, count > 0 { counts[tab] = count; touched.insert(tab); candidates.insert(tab) }
            if slow { uncertain = true; recovery = true }
            if refused { refusal = .refused }
        }
        if reply == .timeout { uncertain = true; recovery = true }
        if reply == .refused || reply == .notAllowed || reply == .failed { refusal = reply }
        guard canDispatch else { settleIfIdle(); return }
        if case .pause(let id, let document, false) = action, reply == .timeout {
            queue.insert(.pause(id, document: document, retry: true), at: 0)
        }
        // A normal pass stops at the first success. A takeover must also reclaim all known old marks.
        if !counts.isEmpty && !needsTakeoverDiscovery { queue.removeAll() }
        if reply == .notAllowed { queue.removeAll() }
        advance()
    }
    private func settleIfIdle() {
        guard !finished, inFlight == nil, stopped || queue.isEmpty else { return }
        finished = true
        if state != .cancelled && state != .transferred { state = uncertain ? .uncertain : (counts.isEmpty ? .pending : .confirmed) }
        let finish = onFinish; onFinish = nil
        finish?()
        let settled = onSettled; onSettled = nil
        settled?()
    }
}

extension BrowserPauseOperation.Reply {
    public var count: Int {
        switch self { case .ids(let ids): return ids.count; case .paused(let count): return count; case .discovered(_, let count, _, _, _): return count; default: return 0 }
    }
    /// Only fixed labels and numbers may reach progress logs.
    public var code: Int {
        switch self {
        case .ids: return 0; case .candidate: return 1; case .paused: return 2; case .empty: return 3
        case .navigated: return 4; case .timeout: return 5; case .refused: return 6; case .notAllowed: return 7; case .failed: return 8; case .discovered: return 9
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
