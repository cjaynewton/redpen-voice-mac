import Foundation

/// Identity of staged tail PCM, never a visible draft or a checked result. Inference waits until stop.
/// A session owns its key across other presses. Escape, changed audio or boundaries invalidate it.
/// Quiet capture buffers may extend coverage; any new sound invalidates it.
public struct CheckedTail: Equatable, Sendable {
    public let generation: Int
    public let start: Int
    public let end: Int
    public let checkedUpTo: Int
    public let pieces: Int
    public init(generation: Int, start: Int, end: Int, checkedUpTo: Int, pieces: Int) {
        self.generation = generation; self.start = start; self.end = end
        self.checkedUpTo = checkedUpTo; self.pieces = pieces
    }
    public func matches(generation: Int, start: Int, checkedUpTo: Int, pieces: Int,
                        available: Int, newerSpeech: Bool, revoked: Bool) -> Bool {
        !revoked && !newerSpeech && self.generation == generation && self.start == start
            && self.checkedUpTo == checkedUpTo && self.pieces == pieces && start >= 0 && start < end && end <= available
    }
    /// Check every appended sample, including a partial 30 ms frame. Conservative peak evidence
    /// prevents a last syllable hidden in a short capture buffer from being silently skipped.
    public static func newerSpeech(_ audio: [Float], after end: Int, quiet: Float) -> Bool {
        guard end <= audio.count else { return true }
        return audio[end...].contains { !$0.isFinite || abs($0) > quiet }
    }
}
