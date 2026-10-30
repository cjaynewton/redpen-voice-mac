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

    /// Allow only the counter entry matching a known talk-key down, not a later key or an arbitrary old key.
    /// Observed real typing is sticky even if a subsequent talk tap becomes the hardware's newest key-down.
    public static func hardwareFailure(since start: Double, at now: Double, keyDownAgo: Double,
                                       leftClickAgo: Double, rightClickAgo: Double,
                                       talkKeyDownAt: Double?, typingKeyDownAt: Double?) -> Failure? {
        let elapsed = max(0, now - start)
        if let typingKeyDownAt, typingKeyDownAt >= start { return .hardwareKey }
        if keyDownAgo < elapsed {
            let keyAt = now - keyDownAgo
            guard let talkKeyDownAt, abs(keyAt - talkKeyDownAt) <= 0.002 else { return .hardwareKey }
        }
        if leftClickAgo < elapsed || rightClickAgo < elapsed { return .hardwareClick }
        return nil
    }

    public static let stoppedMessage = "Stopped typing here. The rest goes on the clipboard."
}
