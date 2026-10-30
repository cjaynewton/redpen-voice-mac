import Foundation

/// Event-timed talk gestures. Hardware state is used only to recover missing releases.
public struct TalkKeyState {
    public enum Action: Equatable { case begin, end, cancel, handsFree }
    public static let tapLength = DictationDelivery.tapLength
    public static let tapGap = 0.5
    public static let stopGuard = 0.5
    public var doubleTap = true
    public private(set) var owner: Int?
    public private(set) var held = false
    public private(set) var active = false
    public private(set) var handsFree = false
    public private(set) var lastTalkKeyDownAt: Double?
    public private(set) var lastTypingKeyDownAt: Double?
    private var pressedAt = 0.0
    private var lastTap: (key: Int, at: Double)?
    private var secondTap = false
    private var swallowed = false
    private var guardedUntil = 0.0

    public init() {}

    /// Voice's own events cannot begin, stop, cancel, or contribute to a double tap.
    public mutating func event(key: Int, down: Bool, ownEvent: Bool = false,
                               canBegin: Bool = true, at now: Double) -> Action? {
        guard !ownEvent else { return nil }
        if down { noteKeyDown(talkKey: true, at: now) }
        // Either configured talk key can stop hands-free. While held, only its owner controls the press.
        if let owner, key != owner, !(handsFree && down) { return nil }
        guard down != held else { return nil }
        held = down
        if down {
            owner = key; pressedAt = now
            if handsFree {
                handsFree = false; active = false; swallowed = true
                lastTap = nil; secondTap = false; guardedUntil = now + Self.stopGuard
                return .end
            }
            guard !active else { return nil }
            // Block before beginning audio, including a press whose release arrives after finishing ends.
            guard canBegin, now >= guardedUntil else {
                swallowed = true; lastTap = nil; secondTap = false
                return nil
            }
            secondTap = doubleTap && lastTap.map { $0.key == key && now - $0.at < Self.tapGap } == true
            lastTap = nil; active = true
            return .begin
        }
        return release(at: now)
    }

    private mutating func release(at now: Double, quick: Bool = false) -> Action? {
        guard let key = owner else { return nil }
        held = false
        defer { if !active && !handsFree { owner = nil } }
        if swallowed {
            swallowed = false
            guardedUntil = max(guardedUntil, now + Self.stopGuard)
            return nil
        }
        guard active else { return nil }
        let duration = quick ? 0 : now - pressedAt
        if doubleTap, duration < Self.tapLength {
            if secondTap {
                handsFree = true; secondTap = false; return .handsFree
            }
            active = false; secondTap = false
            lastTap = (key, now)
            return .cancel
        }
        active = false; lastTap = nil; secondTap = false; guardedUntil = now + Self.stopGuard
        return .end
    }

    /// Recover a missing release using the owner's current hardware state, through the normal release path.
    /// A latched hands-free dictation has no held key and must never be stopped by this check.
    public mutating func checkRelease(key: Int, hardwareDown: Bool, at now: Double) -> Action? {
        guard held, !handsFree, owner == key, !hardwareDown else { return nil }
        return event(key: key, down: false, at: now)
    }

    /// A delayed down arrived after the physical release. Give the queued up event first chance to supply
    /// its exact time. If it never arrives, finish this press as a quick tap, rather than recording forever.
    /// Only the same press can be recovered. The down's time keeps later queued taps in chronological order.
    public mutating func recoverReleasedDown(key: Int, eventAt: Double) -> Action? {
        guard held, owner == key, pressedAt == eventAt else { return nil }
        return release(at: eventAt, quick: true)
    }

    /// Repeats still advance the hardware counter, even though they do not change the talk gesture.
    public mutating func noteKeyDown(talkKey: Bool, at time: Double) {
        if talkKey { lastTalkKeyDownAt = max(lastTalkKeyDownAt ?? time, time) }
        else { lastTypingKeyDownAt = max(lastTypingKeyDownAt ?? time, time) }
    }

    public mutating func otherKey(at time: Double? = nil) -> Action? {
        if let time { noteKeyDown(talkKey: false, at: time) }
        guard held, active, !handsFree else { return nil }
        active = false; lastTap = nil; secondTap = false
        return .cancel
    }

    /// The application could not start recording. Its release must never latch hands-free.
    public mutating func rejectBegin() { active = false; lastTap = nil; secondTap = false }
}
