import Foundation

/// One dictation's input evidence, shared by the passive input thread and the main thread.
/// Stores times only, never key codes, text, or audio. Real typing remains sticky after later talk taps.
/// Each time also carries a kind, modifier or other key, so the log can say which kind stopped live words
/// without ever saying which key (Nov 13 2026). The kind changes nothing about what is blocked.
public final class DraftInput: @unchecked Sendable {
    /// A modifier is Shift, Control, Option, Command, Fn or Caps Lock pressed with no other key.
    public enum Kind: String, Sendable { case modifier, otherKey = "other key" }
    public let since: Double
    private let lock = NSLock()
    private var talkTimes: Set<Double> = []
    private var typingTimes: Set<Double> = []
    private var modifierTimes: Set<Double> = []
    /// A key-down within half a millisecond of a talk-key event is part of that key (the Fn release also posts a key-down,
    /// Oct 30: blocked endings matched the release to 0.05 ms and still counted as typing).
    public static let sameKeyGap = 0.0005

    /// macOS posts key 179 with the Fn/globe key. It is a talk companion only when Fn is configured.
    public static func isTalkKey(_ code: Int, configured: [Int]) -> Bool {
        configured.contains(code) || (code == 179 && configured.contains(63))
    }

    public init(since: Double) { self.since = since }

    public func record(talkKey: Bool, modifier: Bool = false, at time: Double) {
        guard time >= since else { return }
        lock.lock(); defer { lock.unlock() }
        if talkKey { talkTimes.insert(time) } else {
            typingTimes.insert(time)
            if modifier { modifierTimes.insert(time) }
        }
    }

    /// `kind` is nil with no typing. Another key outweighs a modifier, since it alone can change the box.
    public func snapshot() -> (talkTimes: [Double], typingAt: Double?, kind: Kind?) {
        lock.lock(); defer { lock.unlock() }
        let typing = typingTimes.filter { t in !talkTimes.contains { abs($0 - t) <= Self.sameKeyGap } }
        let kind: Kind? = typing.isEmpty ? nil : typing.allSatisfy(modifierTimes.contains) ? .modifier : .otherKey
        return (Array(talkTimes), typing.max(), kind)
    }
}
