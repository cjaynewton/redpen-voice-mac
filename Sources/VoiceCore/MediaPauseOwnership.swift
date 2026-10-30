/// A pause belongs to Voice until it is resumed or the paused player starts playing on its own.
/// Tokens keep an old, asynchronous resume check from acting on a released or newer pause.
public struct MediaPauseOwnership {
    public private(set) var paused = false
    public private(set) var generation = 0

    public init() {}

    public mutating func hold() {
        generation += 1
        paused = true
    }

    public mutating func release() {
        generation += 1
        paused = false
    }

    public func owns(_ token: Int) -> Bool { paused && generation == token }

    /// Returns true only once per held pause. Silence or an unavailable listen never gives it up.
    public mutating func relinquishIfPlaying(peak: Float?) -> Bool {
        guard paused, MediaGate.isPlaying(peak: peak) else { return false }
        release()
        return true
    }
}
