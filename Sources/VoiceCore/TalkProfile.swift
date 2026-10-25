import Foundation

/// How you talk, learned from your own dictations the way a driving app learns how you drive: how fast you speak
/// and how long you pause. Only numbers are kept, never your words or your voice. It decides where a dictation is cut
/// while you talk, so a slow, thoughtful talker isn't cut mid-thought and a fast one doesn't wait.
public struct TalkProfile: Codable, Sendable, Equatable {
    public var dictations = 0
    public var words = 0
    /// Seconds of actual speech, pauses left out.
    public var speaking = 0.0
    /// How many gaps between stretches of speech fell in each 50 ms bin, from 0.15 s up to 3 s.
    public var gaps = [Int](repeating: 0, count: 58)

    public init() {}

    /// Until this many dictations, the defaults hold.
    public static let learnAfter = 20
    static let binStart = 0.15, binWidth = 0.05

    /// Adds one dictation: its audio (16 kHz) and how many words came out.
    public mutating func add(_ samples: [Float], words n: Int) {
        guard n > 0, samples.count > Chunker.rate else { return }
        let m = Self.measure(samples)
        guard m.speaking > 0.5 else { return }
        dictations += 1; words += n; speaking += m.speaking
        for g in m.gaps {
            let i = Int((g - Self.binStart) / Self.binWidth)
            if i >= 0 { gaps[min(i, gaps.count - 1)] += 1 }
        }
    }

    /// Words a minute while actually talking, once there is enough to say.
    public var wordsPerMinute: Int? {
        dictations >= Self.learnAfter && speaking > 60 ? Int(Double(words) / speaking * 60) : nil
    }

    /// The pause that counts as the end of a thought for you: longer than nine in ten of your pauses, kept between
    /// 0.4 and 1 second. 0.5 s until there is enough to go on.
    public var pauseSeconds: Double {
        let total = gaps.reduce(0, +)
        guard dictations >= Self.learnAfter, total >= 50 else { return 0.5 }
        var seen = 0
        for (i, n) in gaps.enumerated() {
            seen += n
            if Double(seen) >= Double(total) * 0.9 {
                return min(1.0, max(0.4, Self.binStart + Double(i + 1) * Self.binWidth))
            }
        }
        return 0.5
    }

    /// One plain line for Settings, or nil while it is still learning.
    public var summary: String? {
        guard let wpm = wordsPerMinute else { return nil }
        return "You talk at about \(wpm) words a minute and pause about \(String(format: "%.1f", pauseSeconds)) s between thoughts."
    }

    /// Seconds of speech and the gaps between stretches of speech, from the same 30 ms loudness the cuts use.
    static func measure(_ samples: [Float]) -> (speaking: Double, gaps: [Double]) {
        let levels = Chunker.levels(samples, from: 0)
        guard !levels.isEmpty else { return (0, []) }
        let quiet = Chunker.quietLevel(levels)
        let frame = Double(Chunker.frame) / Double(Chunker.rate)
        var speaking = 0.0, gaps: [Double] = [], run = 0, spoke = false
        for l in levels {
            if l > quiet {
                if spoke, run > 0 { let g = Double(run) * frame; if g >= binStart { gaps.append(g) } }
                run = 0; spoke = true; speaking += frame
            } else if spoke { run += 1 }
        }
        return (speaking, gaps)  // the silence after the last word is not a pause between thoughts
    }

    // MARK: Saved on this Mac

    public static func load(_ url: URL) -> TalkProfile {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(TalkProfile.self, from: $0) } ?? TalkProfile()
    }

    public func save(_ url: URL) {
        guard let d = try? JSONEncoder().encode(self) else { return }
        try? d.write(to: url, options: .atomic)
    }
}
