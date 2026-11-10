import Foundation

/// The speech span excludes quiet pre-roll and release padding, but includes pauses between words.
/// Keeping pauses makes the short-talk limit conservative, rather than counting voiced frames alone.
public enum FastFinish {
    public static let limit = 20.0
    public static func usesFast(enabled: Bool, available: Bool, speechSeconds: Double) -> Bool {
        enabled && available && speechSeconds.isFinite && speechSeconds > 0 && speechSeconds <= limit
    }
    public static func speechSeconds(_ audio: [Float]) -> Double {
        guard !audio.isEmpty else { return 0 }
        let frame = 480
        var levels: [Float] = []
        for start in stride(from: 0, to: audio.count, by: frame) {
            let end = min(start + frame, audio.count)
            let sum = audio[start..<end].reduce(Float(0)) { $0 + $1 * $1 }
            levels.append((sum / Float(end - start)).squareRoot())
        }
        let quiet = Chunker.quietLevel(levels)
        guard let first = levels.firstIndex(where: { $0 > quiet }),
              let last = levels.lastIndex(where: { $0 > quiet }) else { return 0 }
        let firstRange = first * frame..<min((first + 1) * frame, audio.count)
        let lastRange = last * frame..<min((last + 1) * frame, audio.count)
        guard let start = firstRange.first(where: { abs(audio[$0]) > quiet }),
              let end = lastRange.last(where: { abs(audio[$0]) > quiet }) else { return 0 }
        return Double(end + 1 - start) / Double(Chunker.rate)
    }
}
