import Foundation

/// Hardware-confirmed talk gestures. Times are monotonic seconds, supplied by the caller.
public struct TalkKeyState {
    public enum Action: Equatable { case begin, end, cancel, handsFree }
    public static let tapLength = DictationDelivery.tapLength
    public static let tapGap = 0.5
    public static let stopGuard = 0.5
    public static let bounceGap = 0.03
    public var doubleTap = true
    public private(set) var owner: Int?
    public private(set) var held = false
    public private(set) var active = false
    public private(set) var handsFree = false
    private var pressedAt = 0.0
    private var lastTap: (key: Int, at: Double)?
    private var lastRelease: Double?
    private var secondTap = false
    private var swallowed = false
    private var guardedUntil = 0.0

    public init() {}

    /// Synthetic events cannot begin, stop, cancel, or contribute to a double tap.
    public mutating func event(key: Int, down: Bool, hardwareDown: Bool, ownEvent: Bool = false,
                               canBegin: Bool = true, at now: Double) -> Action? {
        guard !ownEvent, down == hardwareDown else { return nil }
        // Either configured talk key can stop hands-free. While held, only its owner controls the press.
        if let owner, key != owner, !(handsFree && down) { return nil }
        guard down != held else { return nil }
        held = down
        if down {
            owner = key
            if handsFree {
                handsFree = false; active = false; swallowed = true
                lastTap = nil; secondTap = false; guardedUntil = now + Self.stopGuard
                return .end
            }
            guard !active else { return nil }
            // Block before beginning audio, including a press whose release arrives after finishing ends.
            guard canBegin, now >= guardedUntil,
                  lastRelease.map({ now - $0 >= Self.bounceGap }) ?? true else {
                swallowed = true; lastTap = nil; secondTap = false
                return nil
            }
            secondTap = doubleTap && lastTap.map { $0.key == key && now - $0.at < Self.tapGap } == true
            lastTap = nil; pressedAt = now; active = true
            return .begin
        }
        lastRelease = now
        defer { if !active && !handsFree { owner = nil } }
        if swallowed {
            swallowed = false
            guardedUntil = max(guardedUntil, now + Self.stopGuard)
            return nil
        }
        guard active else { return nil }
        let duration = now - pressedAt
        if doubleTap, duration < Self.tapLength {
            // Chatter shorter than 30 ms cannot seed or complete a double tap.
            if duration >= Self.bounceGap, secondTap {
                handsFree = true; secondTap = false; return .handsFree
            }
            active = false; secondTap = false
            lastTap = duration >= Self.bounceGap ? (key, now) : nil
            return .cancel
        }
        active = false; lastTap = nil; secondTap = false; guardedUntil = now + Self.stopGuard
        return .end
    }

    public mutating func otherKey() -> Action? {
        guard held, active, !handsFree else { return nil }
        active = false; lastTap = nil; secondTap = false
        return .cancel
    }

    /// The application could not start recording. Its release must never latch hands-free.
    public mutating func rejectBegin() { active = false; lastTap = nil; secondTap = false }
}
