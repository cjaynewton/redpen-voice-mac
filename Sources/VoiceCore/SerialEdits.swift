import Foundation

/// Edit jobs keep their original order while waits yield to key and UI handlers.
/// Only edits join this queue. Stopping capture and classifying keys never wait on it.
@MainActor public final class SerialEdits {
    private var tail: Task<Void, Never>?
    public init() {}
    @discardableResult public func enqueue(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tail
        let task = Task { await previous?.value; await work() }
        tail = task
        return task
    }
}
