import Foundation

/// Audio before a gesture is confirmed. Bounded, memory only, and never transcribed on a stray tap.
/// Replaying and attaching the sink share a lock, so a new mic buffer cannot overtake the first tap.
public final class TalkCapture<Buffer>: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [Buffer] = []
    private var frames = 0
    private let limit: Int
    private var sink: ((Buffer) -> Void)?
    private var discarded = false
    private var didOverflow = false
    public var overflowed: Bool { lock.withLock { didOverflow } }
    public init(maxFrames: Int) { limit = max(0, maxFrames) }
    public var bufferedFrames: Int { lock.withLock { frames } }
    public func append(_ buffer: Buffer, frames count: Int) {
        lock.withLock {
            guard !discarded else { return }
            if let sink { sink(buffer); return }
            guard count >= 0, count <= limit - frames else {
                buffers.removeAll(); frames = 0; didOverflow = true; discarded = true; return
            }
            buffers.append(buffer); frames += count
        }
    }
    @discardableResult
    public func activate(_ receive: @escaping (Buffer) -> Void) -> Bool {
        lock.withLock {
            guard !discarded, sink == nil else { return false }
            for buffer in buffers { receive(buffer) }
            buffers.removeAll(); frames = 0; sink = receive
            return true
        }
    }
    public func discard() {
        lock.withLock { discarded = true; sink = nil; buffers.removeAll(); frames = 0 }
    }
}
