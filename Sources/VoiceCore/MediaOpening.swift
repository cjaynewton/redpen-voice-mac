import Foundation

/// Holds the opening draft until the media decision is known. A slow or missing answer must never release
/// unchecked video words into a text box. The microphone keeps recording throughout.
public struct MediaOpening: Sendable {
    public static let timeout: TimeInterval = 5
    private var began: Date?
    public private(set) var failed = false
    public private(set) var through = 0

    public init() {}

    public mutating func hold(at now: Date = Date()) { began = now }

    public mutating func settle(through sample: Int = 0) {
        include(through: sample)
        began = nil
    }

    public mutating func include(through sample: Int) { through = max(through, sample) }

    /// A timeout lets finishing continue, but keeps all automatic typing closed for this dictation.
    public mutating func ready(at now: Date = Date()) -> Bool {
        guard let began else { return true }
        guard now.timeIntervalSince(began) >= Self.timeout else { return false }
        failed = true
        self.began = nil
        return true
    }

    /// The first draft includes the entire media opening, even if a short pause occurred inside it.
    public func cut(_ proposed: Int, from: Int, available: Int) -> Int? {
        guard from == 0 else { return proposed }
        guard available >= through else { return nil }
        return max(proposed, through)
    }
}
