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
                                       talkKeyDownTimes: [Double], typingKeyDownAt: Double?) -> Failure? {
        let elapsed = max(0, now - start)
        if let typingKeyDownAt, typingKeyDownAt >= start { return .hardwareKey }
        if keyDownAgo < elapsed {
            let keyAt = now - keyDownAgo
            guard talkKeyDownTimes.contains(where: { abs(keyAt - $0) <= talkKeyTolerance }) else { return .hardwareKey }
        }
        if leftClickAgo < elapsed || rightClickAgo < elapsed { return .hardwareClick }
        return nil
    }

    public struct HardwareSample {
        public var now: Double, keyDownAgo: Double, leftClickAgo: Double, rightClickAgo: Double
        public var talkKeyDownTimes: [Double]
        public var typingKeyDownAt: Double?
        public init(now: Double, keyDownAgo: Double, leftClickAgo: Double, rightClickAgo: Double,
                    talkKeyDownTimes: [Double], typingKeyDownAt: Double?) {
            self.now = now; self.keyDownAgo = keyDownAgo
            self.leftClickAgo = leftClickAgo; self.rightClickAgo = rightClickAgo
            self.talkKeyDownTimes = talkKeyDownTimes; self.typingKeyDownAt = typingKeyDownAt
        }
        public var keyAt: Double { now - keyDownAgo }
        public var nearestTalkAt: Double? { talkKeyDownTimes.min { abs($0 - keyAt) < abs($1 - keyAt) } }
        public func failure(since start: Double) -> Failure? {
            hardwareFailure(since: start, at: now, keyDownAgo: keyDownAgo,
                leftClickAgo: leftClickAgo, rightClickAgo: rightClickAgo,
                talkKeyDownTimes: talkKeyDownTimes, typingKeyDownAt: typingKeyDownAt)
        }
    }

    /// The read-only input listener runs independently of the typing/main thread. Wait without pumping
    /// the main run loop or reentering dictation callbacks. An unmatched key never gets a blanket exemption.
    public static func resolveHardware(since start: Double, sample: () -> HardwareSample,
                                       wait: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }) -> HardwareSample {
        var current = sample()
        let deadline = current.now + eventWait
        while current.failure(since: start) == .hardwareKey,
              current.typingKeyDownAt.map({ $0 >= start }) != true,
              current.leftClickAgo >= max(0, current.now - start),
              current.rightClickAgo >= max(0, current.now - start), current.now < deadline {
            wait(min(0.005, deadline - current.now))
            current = sample()
        }
        return current
    }

    public static let stoppedMessage = "Stopped typing here. The rest goes on the clipboard."
}
