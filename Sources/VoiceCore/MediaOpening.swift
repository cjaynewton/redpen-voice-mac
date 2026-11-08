import Foundation

/// Holds the first draft briefly for media cleanup. D-1400: a missing or unsure decision releases the original
/// microphone audio for normal typing, and a late cleanup must not rewrite it afterwards.
public struct MediaOpening: Sendable {
    public static let timeout: TimeInterval = 5
    private var began: Date?
    public private(set) var timedOut = false
    public private(set) var keepsOriginal = false
    public var acceptsCleanup: Bool { !keepsOriginal }
    public private(set) var through = 0

    public init() {}

    public mutating func hold(at now: Date = Date()) { began = now }

    public mutating func settle(through sample: Int = 0) {
        include(through: sample)
        began = nil
    }

    public mutating func include(through sample: Int) {
        if acceptsCleanup { through = max(through, sample) }
    }

    public mutating func useOriginal() {
        keepsOriginal = true
        through = 0
        began = nil
    }

    /// A timeout releases normal typing with every original sample intact.
    public mutating func ready(at now: Date = Date()) -> Bool {
        guard let began else { return true }
        guard now.timeIntervalSince(began) >= Self.timeout else { return false }
        timedOut = true
        useOriginal()
        return true
    }

    /// The first draft includes the entire media opening, even if a short pause occurred inside it.
    public func cut(_ proposed: Int, from: Int, available: Int) -> Int? {
        guard from == 0 else { return proposed }
        guard available >= through else { return nil }
        return max(proposed, through)
    }
}
