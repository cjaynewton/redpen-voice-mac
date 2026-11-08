import Foundation
import Accelerate

/// Removes a measured, delayed copy of app audio, never transcript words. Overlapping user speech is retained.
/// This is deliberately bounded to a simple acoustic path. Uncertain matches keep the original for Paste last.
public enum MediaAudio {
    public struct Result {
        public let samples: [Float]
        public let certain: Bool
        public let match: Float
    }

    private static func reduced(_ a: [Float]) -> [Float] {
        stride(from: 0, to: a.count - a.count % 8, by: 8).map { i in a[i..<i + 8].reduce(0, +) / 8 }
    }

    private static func locate(_ mic: [Float], _ reference: [Float], minimum: Int = 1000, maximum: Int = 1500) -> (lag: Int, score: Float)? {
        let width = min(reference.count, maximum) // up to 750 ms at 2 kHz
        guard width >= minimum, mic.count >= width else { return nil }
        let mean = reference.prefix(width).reduce(0, +) / Float(width)
        let template = reference.prefix(width).map { $0 - mean }
        let energy = template.reduce(0) { $0 + $1 * $1 }
        guard energy > 0.000001 else { return nil }
        var dots = [Float](repeating: 0, count: mic.count - width + 1)
        vDSP_conv(mic, 1, template, 1, &dots, 1, vDSP_Length(dots.count), vDSP_Length(width))
        var sum = mic.prefix(width).reduce(0, +)
        var square = mic.prefix(width).reduce(0) { $0 + $1 * $1 }
        var best: Float = 0, lag = 0
        for i in dots.indices {
            let variance = max(0, square - sum * sum / Float(width))
            if variance > 0.000001 {
                let score = abs(dots[i]) / (energy * variance).squareRoot()
                if score > best { best = score; lag = i }
            }
            if i + width < mic.count {
                let old = mic[i], next = mic[i + width]
                sum += next - old; square += next * next - old * old
            }
        }
        return (lag, min(1, best))
    }

    public static func removing(mic: [Float], played: [Float], preRoll: Int = 0) -> Result {
        let reference = Array(played.prefix(16_000 * 4))
        let opening = Array(mic.prefix(16_000 * 5))
        let ref = reduced(reference)
        guard let match = locate(reduced(opening), ref) else {
            return Result(samples: mic, certain: false, match: 0)
        }
        // A long window separates an actual quiet copy from the largest accidental short-frame match.
        // The middle band abstains. It must not be treated as proof of headphones.
        if match.score < 0.10 { return Result(samples: mic, certain: true, match: match.score) }
        guard match.score >= 0.14 else { return Result(samples: mic, certain: false, match: match.score) }

        // Refine the sub-frame delay at the original sample rate, then fit the speaker's gain. Fitting the
        // waveform, rather than deleting matching words, also keeps a user's identical spoken phrase.
        let coarse = match.lag * 8
        var bestLag = coarse, bestDot: Float = 0, bestEnergy: Float = 0
        let width = min(12_000, reference.count, opening.count)
        let low = max(0, coarse - 8), high = min(opening.count - width, coarse + 8)
        guard low <= high else { return Result(samples: mic, certain: false, match: match.score) }
        reference.withUnsafeBufferPointer { r in
            opening.withUnsafeBufferPointer { m in
                for lag in low...high {
                    var dot: Float = 0, energy: Float = 0
                    vDSP_dotpr(r.baseAddress!, 1, m.baseAddress! + lag, 1, &dot, vDSP_Length(width))
                    vDSP_svesq(r.baseAddress!, 1, &energy, vDSP_Length(width))
                    if abs(dot) > abs(bestDot) { bestDot = dot; bestEnergy = energy; bestLag = lag }
                }
            }
        }
        guard bestEnergy > 0 else { return Result(samples: mic, certain: false, match: match.score) }
        let gain = bestDot / bestEnergy
        var cleaned = mic
        for i in 0..<min(reference.count, cleaned.count - bestLag) { cleaned[i + bestLag] -= gain * reference[i] }

        // Only a confirmed speaker copy trims pre-key audio, when the user was not dictating. Keep its last
        // 150 ms, as before, and never trim anything at or after key-down. Headphones and the middle band
        // returned above with their entire input untouched.
        let keyDown = min(max(0, preRoll), opening.count)
        for i in 0..<max(0, keyDown - 2400) { cleaned[i] = 0 }
        // The app reference may start a little after key-down. Speech in that acoustic gap is still uncertain;
        // sound before key-down is expected video, not a reason to block every speaker dictation.
        let referenceStart = preRoll > 0 ? max(keyDown, bestLag) : keyDown
        let unreferenced = Array(opening[keyDown..<referenceStart])
        let earlierLevel = unreferenced.isEmpty ? 0 : (unreferenced.reduce(Float(0)) { $0 + $1 * $1 } / Float(unreferenced.count)).squareRoot()
        let earlierSpeech = earlierLevel > 0.003
        // A second strong delayed copy means room reflections or processing exceeded this simple model.
        // Keep the untouched recording instead of risking a partial clean-up in an automatically sent message.
        let residual = locate(reduced(Array(cleaned.prefix(opening.count))), ref)?.score ?? 1
        var residualCertain = residual < 0.14
        // Check the whole reference, including its final words. A volume change or later reflection can be
        // absent from the first 750 ms. Short windows search only around the measured acoustic delay.
        let covered = min(reference.count, cleaned.count - bestLag)
        if covered >= 3840 {
            for proposed in stride(from: 0, to: covered, by: 3840) {
                let start = min(proposed, covered - 3840)
                let low = max(0, bestLag + start - 2400)
                let high = min(cleaned.count, bestLag + start + 3840 + 2400)
                let local = locate(reduced(Array(cleaned[low..<high])), reduced(Array(reference[start..<start + 3840])), minimum: 400, maximum: 480)
                if (local?.score ?? 0) >= 0.20 { residualCertain = false; break }
            }
        } else { residualCertain = false }
        let certain = !earlierSpeech && residualCertain
        return Result(samples: certain ? cleaned : mic, certain: certain, match: match.score)
    }
}
