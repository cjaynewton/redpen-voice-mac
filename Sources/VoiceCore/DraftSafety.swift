import Foundation

/// Hardware times and NSEvent timestamps share the system-uptime clock. No input is posted here.
public enum DraftSafety {
    public enum Failure: String, Hashable {
        case hardwareKey = "hardware key", hardwareClick = "hardware click"
        case userActed = "userActedAt", appChanged = "app changed", elementChanged = "element changed"
        case boxCheck = "box check", deliveryUncertain = "delivery uncertain"
        case echoFailed = "echo failed", emptyText = "empty checked text", noRuns = "no draft runs"
        case editUnconfirmed = "edit unconfirmed"
    }

    // HID counters and event timestamps need not agree to within the old 2 ms budget.
    public static let talkKeyTolerance = 0.025
    public static let eventWait = 0.250

    /// Allow only the counter entry matching a known talk-key down, not a later key or an arbitrary old key.
    /// Observed real typing is sticky even if a subsequent talk tap becomes the hardware's newest key-down.
    public static func hardwareFailure(since start: Double, at now: Double, keyDownAgo: Double,
                                       leftClickAgo: Double, rightClickAgo: Double,
                                       talkKeyDownTimes: [Double], typingKeyDownAt: Double?,
                                       ownLeftClickTimes: [Double] = [], ownRightClickTimes: [Double] = [],
                                       userClickAt: Double? = nil) -> Failure? {
        let elapsed = max(0, now - start)
        if let typingKeyDownAt, typingKeyDownAt >= start { return .hardwareKey }
        if keyDownAgo < elapsed {
            let keyAt = now - keyDownAgo
            guard talkKeyDownTimes.contains(where: { abs(keyAt - $0) <= talkKeyTolerance }) else { return .hardwareKey }
        }
        if let userClickAt, userClickAt >= start { return .hardwareClick }
        if leftClickAgo < elapsed && !OwnWindowClicks.matches(now - leftClickAgo, times: ownLeftClickTimes) { return .hardwareClick }
        if rightClickAgo < elapsed && !OwnWindowClicks.matches(now - rightClickAgo, times: ownRightClickTimes) { return .hardwareClick }
        return nil
    }

    public struct HardwareSample {
        public var now: Double, keyDownAgo: Double, leftClickAgo: Double, rightClickAgo: Double
        public var talkKeyDownTimes: [Double]
        public var typingKeyDownAt: Double?
        public var ownLeftClickTimes: [Double], ownRightClickTimes: [Double]
        public var userClickAt: Double?
        public init(now: Double, keyDownAgo: Double, leftClickAgo: Double, rightClickAgo: Double,
                    talkKeyDownTimes: [Double], typingKeyDownAt: Double?,
                    ownLeftClickTimes: [Double] = [], ownRightClickTimes: [Double] = [], userClickAt: Double? = nil) {
            self.now = now; self.keyDownAgo = keyDownAgo
            self.leftClickAgo = leftClickAgo; self.rightClickAgo = rightClickAgo
            self.talkKeyDownTimes = talkKeyDownTimes; self.typingKeyDownAt = typingKeyDownAt
            self.ownLeftClickTimes = ownLeftClickTimes; self.ownRightClickTimes = ownRightClickTimes; self.userClickAt = userClickAt
        }
        /// Yield for the local window monitor as well as the passive key listener. Known real input never waits.
        public func needsListener(since start: Double) -> Bool {
            switch failure(since: start) {
            case .hardwareKey:
                let elapsed = max(0, now - start)
                return typingKeyDownAt.map { $0 >= start } != true
                    && (leftClickAgo >= elapsed || OwnWindowClicks.matches(now - leftClickAgo, times: ownLeftClickTimes))
                    && (rightClickAgo >= elapsed || OwnWindowClicks.matches(now - rightClickAgo, times: ownRightClickTimes))
            case .hardwareClick: return userClickAt.map { $0 >= start } != true
            default: return false
            }
        }
        public var keyAt: Double { now - keyDownAgo }
        public var nearestTalkAt: Double? { talkKeyDownTimes.min { abs($0 - keyAt) < abs($1 - keyAt) } }
        public func failure(since start: Double) -> Failure? {
            hardwareFailure(since: start, at: now, keyDownAgo: keyDownAgo,
                leftClickAgo: leftClickAgo, rightClickAgo: rightClickAgo,
                talkKeyDownTimes: talkKeyDownTimes, typingKeyDownAt: typingKeyDownAt,
                ownLeftClickTimes: ownLeftClickTimes, ownRightClickTimes: ownRightClickTimes, userClickAt: userClickAt)
        }
    }

    /// The read-only input listener runs independently. Workers may wait without pumping the run loop.
    /// UI callers can refuse unresolved input immediately. An unmatched key never gets a blanket exemption.
    public static func resolveHardware(since start: Double, sample: () -> HardwareSample,
                                       waitForListener: Bool = true,
                                       wait: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> HardwareSample {
        var current = sample()
        let deadline = current.now + eventWait
        // UI/key handlers refuse unresolved input immediately. Worker callers can still wait for the listener.
        guard waitForListener else { return current }
        while current.needsListener(since: start), current.now < deadline {
            wait(min(0.005, deadline - current.now))
            current = sample()
        }
        return current
    }

    /// Give the passive key listener two tiny turns without blocking key/UI handling.
    @MainActor public static func resolveHardwareAsync(since start: Double, sample: () -> HardwareSample) async -> HardwareSample {
        var current = sample()
        for _ in 0..<2 {
            guard current.needsListener(since: start) else { break }
            try? await Task.sleep(for: .milliseconds(5))
            current = sample()
        }
        return current
    }
}
