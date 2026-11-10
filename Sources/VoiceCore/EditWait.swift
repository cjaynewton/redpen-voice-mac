import Foundation

/// Confirmation sleeps and slow editor reads must not occupy the key/UI executor.
public enum EditWait {
    @MainActor public static func confirm(attempts: Int, while still: () async -> Bool,
                                          read: () async -> Bool?) async -> Bool {
        for _ in 0..<attempts {
            guard await still() else { return false }
            guard let matched = await read() else { return false }
            guard await still() else { return false }
            if matched { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}
