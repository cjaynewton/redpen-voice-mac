import Foundation

/// One dictation's input evidence, shared by the passive input thread and the main thread.
/// Stores times only, never key codes, text, or audio. Real typing remains sticky after later talk taps.
public final class DraftInput: @unchecked Sendable {
    public let since: Double
    private let lock = NSLock()
    private var talkTimes: Set<Double> = []
    private var typingTimes: Set<Double> = []
    /// A key-down within half a millisecond of a talk-key event is part of that key (the Fn release also posts a key-down,
    /// Oct 30: blocked endings matched the release to 0.05 ms and still counted as typing).
    public static let sameKeyGap = 0.0005

    public init(since: Double) { self.since = since }

    public func record(talkKey: Bool, at time: Double) {
        guard time >= since else { return }
        lock.lock(); defer { lock.unlock() }
        if talkKey { talkTimes.insert(time) } else { typingTimes.insert(time) }
    }

    public func snapshot() -> (talkTimes: [Double], typingAt: Double?) {
        lock.lock(); defer { lock.unlock() }
        let typing = typingTimes.filter { t in !talkTimes.contains { abs($0 - t) <= Self.sameKeyGap } }
        return (Array(talkTimes), typing.max())
    }
}
