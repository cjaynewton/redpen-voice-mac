import Foundation

/// A short, cancelled press must not take insertion or the bar away from the dictation before it.
/// Recording ownership stays separate: a real new hold still owns its microphone immediately.
public struct DictationDelivery {
    public static let tapLength = 0.4
    public private(set) var current = 0
    private var next = 0
    private var pending: (previous: Int, began: Date)?

    public init() {}

    public mutating func begin(at now: Date = Date()) {
        pending = (current, now)
        advance()
    }

    /// A release that finishes a dictation, or the second tap that starts hands-free, is a real dictation.
    public mutating func confirm() { pending = nil }

    /// Called only when no words were typed. Returns true when this was a disposable short tap.
    @discardableResult
    public mutating func cancel(at now: Date = Date()) -> Bool {
        defer { pending = nil }
        guard let p = pending, now.timeIntervalSince(p.began) < Self.tapLength else { return false }
        current = p.previous
        return true
    }

    /// Paste last also takes insertion ownership, and must never be undone by a later cancelled tap.
    public mutating func supersede() { pending = nil; advance() }

    private mutating func advance() { next += 1; current = next }

    /// A finishing dictation waits until a newer press is either cancelled or old enough to be a real hold.
    public func waitForTap(after generation: Int, at now: Date = Date()) -> TimeInterval {
        guard current != generation, let p = pending else { return 0 }
        return max(0, Self.tapLength - now.timeIntervalSince(p.began))
    }
}
