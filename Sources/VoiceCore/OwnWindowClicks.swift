import Foundation

/// NSEvent and the HID mouse counters use system uptime. Keep buttons separate and never excuse a nearby key.
public final class OwnWindowClicks: @unchecked Sendable {
    public enum Button: Hashable { case left, right, other }
    public static let shared = OwnWindowClicks()
    public static let tolerance = 0.050
    private let lock = NSLock()
    private var times: [Button: [Double]] = [:]
    private var userClickAt: Double?
    public init() {}

    public struct Snapshot {
        public let left: [Double], right: [Double]
        public let userClickAt: Double?
    }
    public func record(_ button: Button, at time: Double) {
        lock.lock(); defer { lock.unlock() }
        var recent = times[button, default: []]
        recent.append(time)
        times[button] = Array(recent.suffix(64))
    }
    public static func matches(_ time: Double, times: [Double]) -> Bool {
        time.isFinite && times.contains { $0.isFinite && abs(time - $0) <= tolerance }
    }
    public func contains(_ button: Button, at time: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return Self.matches(time, times: times[button, default: []])
    }
    /// Remember real clicks even if a later bar click replaces the HID counter's newest entry.
    @discardableResult public func recordExternal(_ button: Button, at time: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !Self.matches(time, times: times[button, default: []]) else { return false }
        userClickAt = max(userClickAt ?? time, time)
        return true
    }
    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(left: times[.left, default: []], right: times[.right, default: []], userClickAt: userClickAt)
    }
}
