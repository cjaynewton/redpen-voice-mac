import Foundation

/// A short, cancelled press must not take insertion or the bar away from the dictation before it.
/// Recording ownership stays separate: a real new hold still owns its microphone immediately.
public struct DictationDelivery {
    public static let tapLength = 0.4
    public private(set) var current = 0
    private var next = 0
    private var pending: (previous: Int, began: Date)?
    private var tapUntil: Date?

    public init() {}

    public mutating func begin(at now: Date = Date()) {
        pending = (current, now)
        tapUntil = nil
        advance()
    }

    /// A release that finishes a dictation, or the second tap that starts hands-free, is a real dictation.
    public mutating func confirm() { pending = nil; tapUntil = nil }

    /// A released first tap is still disposable throughout the second-tap window, not just tapLength.
    public mutating func deferTap(until deadline: Date) {
        if pending != nil { tapUntil = deadline }
    }

    /// Called only when no words were typed. Returns true when this was a disposable short tap.
    @discardableResult
    public mutating func cancel(at now: Date = Date()) -> Bool {
        defer { pending = nil; tapUntil = nil }
        guard let p = pending, now.timeIntervalSince(p.began) < Self.tapLength else { return false }
        current = p.previous
        return true
    }

    /// The key state already classified the gesture using event timestamps. Handler delays cannot change it.
    @discardableResult
    public mutating func cancel(disposableTap: Bool) -> Bool {
        defer { pending = nil; tapUntil = nil }
        guard disposableTap, let p = pending else { return false }
        current = p.previous
        return true
    }

    /// Paste last also takes insertion ownership, and must never be undone by a later cancelled tap.
    public mutating func supersede() { pending = nil; tapUntil = nil; advance() }

    private mutating func advance() { next += 1; current = next }

    /// A finishing dictation waits until a newer press is either cancelled or old enough to be a real hold.
    public func waitForTap(after generation: Int, at now: Date = Date()) -> TimeInterval {
        guard current != generation, let p = pending else { return 0 }
        // If expiry work is queued behind the ending, give it a turn before deciding that ownership changed.
        if let until = tapUntil { return max(0.025, until.timeIntervalSince(now)) }
        return max(0, Self.tapLength - now.timeIntervalSince(p.began))
    }
}
