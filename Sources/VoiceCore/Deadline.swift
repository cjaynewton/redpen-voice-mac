import Foundation

/// Waits for async work, but never past a deadline. A speech engine that stops answering must not leave the app
/// on "Writing" for good: while a dictation is still being written, the talk key starts nothing new.
public enum Deadline {
    public enum Outcome<Value: Sendable>: Sendable {
        case value(Value)
        case failure(any Error)
        case timedOut
    }

    /// How long the ending of a dictation may take: a generous base, plus half a second per second recorded
    /// (a Whisper ending covers at most the audio since the last piece, usually a few seconds).
    public static func finishSeconds(recorded seconds: Double) -> Double {
        30 + 0.5 * max(0, seconds.isFinite ? seconds : 0)
    }

    /// Runs `work` and returns its result, or `.timedOut` once `seconds` pass first. Work that times out keeps
    /// running in the background; its late result is dropped.
    public static func run<Value: Sendable>(seconds: Double, _ work: @escaping @Sendable () async throws -> Value) async -> Outcome<Value> {
        let once = Claim()
        return await withCheckedContinuation { (c: CheckedContinuation<Outcome<Value>, Never>) in
            Task {
                let outcome: Outcome<Value>
                do { outcome = .value(try await work()) } catch { outcome = .failure(error) }
                if once.take() { c.resume(returning: outcome) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                if once.take() { c.resume(returning: .timedOut) }
            }
        }
    }

    /// Lets exactly one of the two racing answers resume the caller.
    private final class Claim: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func take() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if taken { return false }
            taken = true
            return true
        }
    }
}
