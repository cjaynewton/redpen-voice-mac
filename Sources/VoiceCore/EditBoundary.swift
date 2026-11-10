import Foundation

/// Return may bypass editor confirmation, but never a Delete/retype transaction.
/// The tap's backstop uses this same lock, so it cannot post through an active edit.
public final class EditBoundary: @unchecked Sendable {
    public static let shared = EditBoundary()
    private let lock = NSLock()
    private var active = false
    private var pending: [() -> Void] = []
    private var hurry = false
    /// Each Return gets its own token, so an older Return's 300 ms timer can't hurry a later edit.
    private var token = 0
    public init() {}

    public func begin() -> Bool {
        lock.withLock {
            guard !active, pending.isEmpty else { return false }
            active = true
            return true
        }
    }
    public var expedited: Bool { lock.withLock { hurry } }
    public func end() {
        // Execute while the boundary remains closed. A backstop and a new edit cannot overtake the send.
        while true {
            let work: [() -> Void]? = lock.withLock {
                guard !pending.isEmpty else { active = false; hurry = false; return nil }
                let work = pending; pending.removeAll(); return work
            }
            guard let work else { return }
            for send in work { send() }
        }
    }
    public func sendWhenSafe(_ send: @escaping () -> Void) {
        let (immediate, mine): (Bool, Int) = lock.withLock {
            pending.append(send)
            token += 1
            if active { return (false, token) }
            active = true
            return (true, token)
        }
        if immediate { end() }
        else {
            // At 300 ms, drop only artificial pacing. Focus/input guards still run for every post.
            // Never force Return into a half replacement if an external AX call is stalled.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [self] in
                lock.withLock { if !pending.isEmpty, token == mine { hurry = true } }
            }
        }
    }
}
