import Foundation

/// Where the live draft cuts while you talk (Nov 13 2026). Separate from Chunker, whose defaults Whisper and
/// meetings keep unchanged.
///
/// The old draft rule counted its 0.8 seconds from the last cut, so the silence before you spoke (the 0.6 s
/// kept from before the press, plus the double tap) counted as audio, and the first piece was often silence
/// alone. With no clean pause nothing was cut for six seconds. Median 2.3 s from starting to talk to the first
/// typed words, 5.9 s at worst (Nov 12 and 13 log).
///
/// Here the minimum is counted from the first sound of speech. A stretch with no speech is never sent to the
/// engine. Until the first words are out, about 0.9 s of speech is enough: the cut goes at the quietest point
/// instead of waiting for a pause. Later pieces with no pause are cut at the quietest point after about 3 s.
public struct DraftChunker: Sendable {
    /// At least this much speech, counted from its first sound, before any cut.
    public var minSpeech: Double
    /// Until the first words are out: once this much speech exists, cut without waiting for a pause.
    public var firstCeiling: Double
    /// Later pieces with no pause are cut once this much speech exists.
    public var laterCeiling: Double
    /// A quiet stretch this long counts as a pause.
    public var pauseSeconds: Double
    /// Quiet this long with no speech at all is stepped over, so a long silence never piles up in one piece.
    public var silenceSkip: Double

    public init(minSpeech: Double = 0.8, firstCeiling: Double = 0.9, laterCeiling: Double = 3.0,
                pauseSeconds: Double = 0.2, silenceSkip: Double = 2.0) {
        self.minSpeech = minSpeech; self.firstCeiling = firstCeiling; self.laterCeiling = laterCeiling
        self.pauseSeconds = pauseSeconds; self.silenceSkip = silenceSkip
    }

    public struct Cut: Equatable, Sendable {
        /// The sample to cut at.
        public let end: Int
        /// True when the cut sits in a real pause. Only such a cut may bound a Whisper check: a cut forced inside
        /// running speech can land inside a word, which is fine for a draft and wrong for the final text.
        public let atPause: Bool
        /// False for a stretch with no speech in it. It is stepped over and never sent to the engine.
        public let speech: Bool
        public init(end: Int, atPause: Bool, speech: Bool) { self.end = end; self.atPause = atPause; self.speech = speech }
    }

    static let frame = Chunker.frame
    /// Kept before the newest audio when silence is stepped over, so the start of the next word is never cut off.
    static let leadIn = 10

    /// The next cut after `from`, or nil to keep listening. `first` is true until a draft with words is out.
    public func cut(_ samples: [Float], from: Int, first: Bool) -> Cut? {
        let levels = Chunker.levels(samples, from: from)
        guard levels.count >= 3 else { return nil }
        let quiet = Chunker.quietLevel(levels)
        guard let onset = Self.speechOnset(levels, quiet: quiet) else {
            // Nothing said yet. Step over a long silence, keeping a lead-in for the word about to start.
            guard Double(levels.count * Self.frame) >= silenceSkip * Double(Chunker.rate), levels.count > Self.leadIn else { return nil }
            return Cut(end: from + (levels.count - Self.leadIn) * Self.frame, atPause: true, speech: false)
        }
        let minFrames = frames(minSpeech)
        let spoken = levels.count - onset
        guard spoken > minFrames else { return nil }
        // The first pause long enough, after the minimum of speech: cut in its middle.
        let pauseFrames = max(1, frames(pauseSeconds))
        let firstAllowed = onset + minFrames
        var run = 0
        for i in onset..<levels.count {
            if levels[i] <= quiet { run += 1 } else { run = 0 }
            if run >= pauseFrames, i - run / 2 >= firstAllowed {
                return Cut(end: from + (i - run / 2) * Self.frame, atPause: true, speech: true)
            }
        }
        // No pause. Once enough speech exists, cut at the quietest point of the later part.
        let ceiling = frames(first ? firstCeiling : laterCeiling)
        guard spoken >= ceiling else { return nil }
        let windowStart = onset + (first ? ceiling * 2 / 3 : ceiling / 2)
        guard windowStart < levels.count else { return nil }
        // Quietest over three frames (90 ms), which favours the gap between two words over a dip inside one.
        func around(_ i: Int) -> Float {
            let lo = max(windowStart, i - 1), hi = min(levels.count - 1, i + 1)
            return levels[lo...hi].reduce(0, +) / Float(hi - lo + 1)
        }
        let q = (windowStart..<levels.count).min { around($0) < around($1) } ?? windowStart
        // The quietest point can still be a real pause that began before the minimum. Say so only when it is.
        var lo = q, hi = q
        while lo > onset, levels[lo - 1] <= quiet { lo -= 1 }
        while hi + 1 < levels.count, levels[hi + 1] <= quiet { hi += 1 }
        let inPause = levels[q] <= quiet && hi - lo + 1 >= pauseFrames
        return Cut(end: from + q * Self.frame, atPause: inPause, speech: true)
    }

    /// The frame where speech starts: a loud frame with at least three loud frames in the 150 ms it opens. One
    /// or two loud frames alone are a click (the talk key, a tap on the desk), not a word.
    public static func speechOnset(_ levels: [Float], quiet: Float) -> Int? {
        for i in levels.indices where levels[i] > quiet {
            let window = levels[i..<min(levels.count, i + 5)]
            if window.reduce(0, { $0 + ($1 > quiet ? 1 : 0) }) >= 3 { return i }
        }
        return nil
    }

    /// True when the samples in `from..<to` hold speech, by the same rule as the cut.
    public static func hasSpeech(_ samples: [Float], from: Int, to: Int) -> Bool {
        let end = min(to, samples.count)
        guard from < end else { return false }
        let levels = Chunker.levels(Array(samples[from..<end]), from: 0)
        guard !levels.isEmpty else { return false }
        return speechOnset(levels, quiet: Chunker.quietLevel(levels)) != nil
    }

    /// Where Whisper's check of the drafts ends: the first draft that ended in a real pause at least 4 s after
    /// the last check. The final text is made of these checks plus a last hearing of everything after them, so
    /// its seams must sit in pauses: a draft cut inside running speech never ends a check. Past Whisper's 25 s
    /// the newest pause before the limit is used, and only with none at all the draft before the limit, as
    /// before. `ends` are the drafts' end samples and whether each sits in a pause. Returns the end sample and
    /// the count of drafts the check covers.
    public static func checkCut(_ ends: [(end: Int, atPause: Bool)], checkedUpTo: Int, from: Int) -> (end: Int, upTo: Int)? {
        guard checkedUpTo < ends.count else { return nil }
        var lastPause: Int?
        for i in checkedUpTo..<ends.count {
            let length = ends[i].end - from
            if length > 25 * Chunker.rate {
                if let j = lastPause { return (ends[j].end, j + 1) }
                return i > checkedUpTo ? (ends[i - 1].end, i) : (ends[i].end, i + 1)
            }
            guard ends[i].atPause else { continue }
            if length >= 4 * Chunker.rate { return (ends[i].end, i + 1) }
            if length > 0 { lastPause = i }
        }
        return nil
    }

    private func frames(_ seconds: Double) -> Int { Int(seconds * Double(Chunker.rate) / Double(Self.frame)) }
}
