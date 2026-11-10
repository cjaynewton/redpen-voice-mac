import Foundation

/// One browser control transaction. Callbacks and ownership changes are serialized by the caller.
/// Audio cleanup has its own, shorter deadline and never consults this transaction's state.
public final class BrowserPauseOperation {
    public static let totalBudget: TimeInterval = 8
    public static let slowAfter: TimeInterval = 4
    public static let actionBudget: TimeInterval = 1.2
    public enum State: Equatable { case pending, confirmed, uncertain, cancelled, transferred }
    public enum Action: Equatable {
        case windows
        case front(Int)
        case tabs(Int)
        case probe(Int)
        case pause(Int, document: String, retry: Bool)
    }
    public enum Reply: Equatable {
        case ids([Int])
        case candidate(String)
        case paused(Int)
        case empty, navigated, timeout, refused, notAllowed, failed
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
    public var onFinish: (() -> Void)?
    public var onSettled: (() -> Void)?
    public var onSlow: (() -> Void)?
    public var onProgress: ((String, Int?, TimeInterval, Int) -> Void)?
    private let now: () -> TimeInterval
    private let perform: (Action, TimeInterval, @escaping (Reply) -> Void) -> Void
    private var queue: [Action] = [.windows]
    private var stopped = false
    private var visitedTabs: Set<Int> = []
    private var discoveryRetries: Set<String> = []
    private var needsTakeoverDiscovery: Bool

    public init(token: String, owner: Int, preferredTab: Int? = nil, candidates: [Int] = [],
                inheritedTokens: [String] = [], inheritedTabs: Set<Int> = [], now: @escaping () -> TimeInterval,
                perform: @escaping (Action, TimeInterval, @escaping (Reply) -> Void) -> Void) {
        self.token = token; self.owner = owner; self.now = now; self.perform = perform
        self.inheritedTokens = inheritedTokens; self.inheritedTabs = inheritedTabs
        needsTakeoverDiscovery = !inheritedTokens.isEmpty
        self.candidates = Set(candidates)
        entered = now()
        queue.insert(contentsOf: candidates.map(Action.probe), at: 0)
        if let preferredTab { queue.insert(.probe(preferredTab), at: 0) }
    }
    public var reconciliationTabs: [Int] { touched.union(inheritedTabs).sorted() }
    public var reconciliationTokens: [String] { inheritedTokens + [token] }
    public var remaining: TimeInterval { max(0, Self.totalBudget - (now() - entered)) }
    public var canDispatch: Bool { !stopped && !finished && remaining > 0 }
    public func start() { advance() }
    public func tick() {
        if !slow && now() - entered >= Self.slowAfter {
            slow = true; recovery = true; onSlow?()
        }
        if remaining == 0 { uncertain = true; stopped = true; queue.removeAll(); settleIfIdle() }
    }
    /// Stop sends no further pauses. An already-sent action still has to report so its token can be reconciled.
    public func stop(cancelled: Bool = false) {
        stopped = true; queue.removeAll()
        state = cancelled ? .cancelled : (counts.isEmpty ? .uncertain : .confirmed)
        settleIfIdle()
    }
    /// Retain all discovered candidates for the new owner's fresh, confirmed pause pass.
    public func transfer(to owner: Int) {
        self.owner = owner; stopped = true; queue.removeAll(); state = .transferred
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
        let action = queue.removeFirst()
        if case .probe(let id) = action, !visitedTabs.insert(id).inserted { advance(); return }
        if case .pause(let id, _, _) = action { touched.insert(id) }
        inFlight = action
        let tab: Int?
        switch action { case .probe(let id), .pause(let id, _, _): tab = id; default: tab = nil }
        onProgress?("\(action.phase)-dispatch", tab, now() - entered, 0)
        perform(action, min(Self.actionBudget, remaining)) { [self] reply in receive(reply, for: action) }
    }
    private func receive(_ reply: Reply, for action: Action) {
        guard inFlight == action else { return }
        tick()
        inFlight = nil
        let tab: Int?
        switch action { case .probe(let id), .pause(let id, _, _): tab = id; default: tab = nil }
        onProgress?("\(action.phase)-result-\(reply.code)", tab, now() - entered, reply.count)
        // Even a cancelled or transferred request can have paused. Keep its partial evidence for reconciliation.
        if case .pause(let id, _, _) = action, case .paused(let count) = reply, count > 0 { counts[id] = count }
        if reply == .timeout { uncertain = true; recovery = true }
        if reply == .refused || reply == .notAllowed || reply == .failed { refusal = reply }
        guard canDispatch else { settleIfIdle(); return }
        switch (action, reply) {
        case (.windows, .ids(let ids)):
            needsTakeoverDiscovery = false
            queue = ids.map(Action.front) + ids.map(Action.tabs)
        case (.front, .ids(let ids)), (.tabs, .ids(let ids)):
            candidates.formUnion(ids)
            queue.insert(contentsOf: ids.map(Action.probe), at: 0)
        case (.probe(let id), .candidate(let document)):
            queue.insert(.pause(id, document: document, retry: false), at: 0)
        case (.pause(let id, let document, false), .timeout):
            queue.insert(.pause(id, document: document, retry: true), at: 0)
        case (.windows, .timeout), (.front, .timeout), (.tabs, .timeout):
            let key = String(describing: action)
            if discoveryRetries.insert(key).inserted { queue.append(action) }
        default: break
        }
        // Keep the current group's remaining candidates, as before. Publish each success through progress now;
        // later timeouts cannot erase it. Once a group succeeds, do not discover unrelated background groups.
        if !counts.isEmpty { queue.removeAll { action in
            switch action {
            case .windows: return !needsTakeoverDiscovery
            case .tabs: return true
            default: return false
            }
        } }
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
        switch self { case .ids(let ids): return ids.count; case .paused(let count): return count; default: return 0 }
    }
    /// Only fixed labels and numbers may reach progress logs.
    public var code: Int {
        switch self {
        case .ids: return 0; case .candidate: return 1; case .paused: return 2; case .empty: return 3
        case .navigated: return 4; case .timeout: return 5; case .refused: return 6; case .notAllowed: return 7; case .failed: return 8
        }
    }
}

extension BrowserPauseOperation.Action {
    public var phase: String {
        switch self {
        case .windows: return "discovery-windows"; case .front: return "discovery-front"; case .tabs: return "discovery-tabs"
        case .probe: return "candidate"; case .pause(_, _, let retry): return retry ? "retry" : "pause"
        }
    }
}
