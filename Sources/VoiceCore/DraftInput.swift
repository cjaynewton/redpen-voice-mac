import Foundation

/// One dictation's input evidence, shared by the passive input thread and the main thread.
/// Stores times only, never key codes, text, or audio. Real typing remains sticky after later talk taps.
public final class DraftInput: @unchecked Sendable {
    public let since: Double
    private let lock = NSLock()
    private var talkTimes: Set<Double> = []
    private var typingAt: Double?

    public init(since: Double) { self.since = since }

    public func record(talkKey: Bool, at time: Double) {
        guard time >= since else { return }
        lock.lock(); defer { lock.unlock() }
        if talkKey { talkTimes.insert(time) }
        else { typingAt = max(typingAt ?? time, time) }
    }

    public func snapshot() -> (talkTimes: [Double], typingAt: Double?) {
        lock.lock(); defer { lock.unlock() }
        return (Array(talkTimes), typingAt)
    }
}
