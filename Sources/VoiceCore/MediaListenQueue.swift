import Foundation

/// One audio listen at a time. A busy tap queues the request instead of answering as though it heard silence.
/// The caller starts only the request returned by submit/finish, and finishes after tearing its tap down.
public final class MediaListenQueue<Request: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var waiting: [Request] = []

    public init() {}

    /// Returns this request when it can start now, or keeps it until the current listen finishes.
    public func submit(_ request: Request) -> Request? {
        lock.lock(); defer { lock.unlock() }
        if running { waiting.append(request); return nil }
        running = true
        return request
    }

    /// Optional diagnostics skip a busy tap instead of delaying a pause, quiet check or resume.
    public func submitIfIdle(_ request: Request) -> Request? {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return nil }
        running = true
        return request
    }

    /// Returns the next request, keeping the tap reserved for it, or makes the tap available again.
    public func finish() -> Request? {
        lock.lock(); defer { lock.unlock() }
        guard !waiting.isEmpty else { running = false; return nil }
        return waiting.removeFirst()
    }
}
