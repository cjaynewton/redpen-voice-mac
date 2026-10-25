import Foundation

/// Finds where to cut a recording while it is still going, so each finished piece can be written while you talk and
/// only the last few seconds are left when you let go. It cuts only in a pause, never inside a word; with no pause at
/// all it cuts at the quietest moment before Whisper's 30-second limit.
public struct Chunker: Sendable {
    public static let rate = 16_000
    /// 30 ms frames: short enough to find the gap between two words.
    static let frame = 480

    /// At least this much new audio before a cut: Whisper does worse on a few words alone.
    public var minSeconds: Double
    /// Whisper hears 30 s at a time, so a piece never runs longer than this.
    public var maxSeconds: Double
    /// A quiet stretch this long counts as a pause. Learned from how you talk (TalkProfile), 0.5 s until then.
    public var pauseSeconds: Double

    public init(minSeconds: Double = 4, maxSeconds: Double = 25, pauseSeconds: Double = 0.5) {
        self.minSeconds = minSeconds; self.maxSeconds = maxSeconds; self.pauseSeconds = pauseSeconds
    }

    /// The sample to cut at, or nil to keep listening. `from` is the last cut.
    public func cut(_ samples: [Float], from: Int) -> Int? {
        let minLen = Int(minSeconds * Double(Self.rate)), maxLen = Int(maxSeconds * Double(Self.rate))
        guard samples.count - from > minLen else { return nil }
        let levels = Self.levels(samples, from: from)
        guard !levels.isEmpty else { return nil }
        let quiet = Self.quietLevel(levels)
        let pauseFrames = max(1, Int(pauseSeconds * Double(Self.rate) / Double(Self.frame)))
        let firstAllowed = minLen / Self.frame
        // The first pause long enough, after the minimum: cut in its middle.
        var run = 0
        for i in 0..<levels.count {
            if levels[i] <= quiet { run += 1 } else { run = 0 }
            if run >= pauseFrames, i - run / 2 >= firstAllowed {
                return from + (i - run / 2) * Self.frame
            }
        }
        // No pause: cut before Whisper's limit, at the quietest frame in the allowed window.
        guard samples.count - from >= maxLen else { return nil }
        let window = firstAllowed..<min(levels.count, maxLen / Self.frame)
        guard let q = window.min(by: { levels[$0] < levels[$1] }) else { return from + maxLen }
        return from + q * Self.frame
    }

    /// Loudness of each 30 ms frame after `from`.
    static func levels(_ samples: [Float], from: Int) -> [Float] {
        var out: [Float] = []
        out.reserveCapacity((samples.count - from) / frame)
        var i = from
        while i + frame <= samples.count {
            var sum: Float = 0
            for j in i..<(i + frame) { sum += samples[j] * samples[j] }
            out.append((sum / Float(frame)).squareRoot())
            i += frame
        }
        return out
    }

    /// Quiet means well below this speaker's speech level here: a tenth of the loud frames' level, and never below
    /// a floor so a silent room isn't all "speech".
    static func quietLevel(_ levels: [Float]) -> Float {
        let sorted = levels.sorted()
        let loud = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
        return max(0.003, loud * 0.1)
    }
}
