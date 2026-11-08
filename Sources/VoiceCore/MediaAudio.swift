import Foundation
import Accelerate

/// Local, bounded echo removal. A measured startup gap has no app reference and is blanked explicitly;
/// its post-key length is reported. Neither matching transcript words nor entire opening seconds are deleted.
public enum MediaAudio {
    public struct Diagnostics {
        public var reason = "none"
        public var preRollRMS: Float?
        public var gapSamples: Int?
        public var gapRMS: Float?
        public var firstResidual: Float?
        public var finalResidual: Float?
        public var windowScore: Float?
        public var windowOffset: Int?
        public var gain: Float?
        public var lagMinusPreRoll: Int?
        public var taps = 0
        public var windowFits = 0
        public var cuts: [Range<Int>] = []
        public var lostUserSamples = 0

        public var logLine: String {
            func value(_ n: Float?) -> String { n.map { String(format: "%.4f", $0) } ?? "unmeasured" }
            func ms(_ n: Int?) -> String { n.map { String(format: "%.1f", Double($0) / 16) } ?? "unmeasured" }
            return "reason=\(reason), preRoll RMS \(value(preRollRMS)), earlierSpeech gap \(ms(gapSamples))ms RMS \(value(gapRMS)), first residual \(value(firstResidual)), final residual \(value(finalResidual)), window reflection \(value(windowScore)) at reference +\(ms(windowOffset))ms, gain \(value(gain)), bestLag-preRoll \(ms(lagMinusPreRoll))ms, taps \(taps), window fits \(windowFits), user audio blanked \(ms(lostUserSamples))ms"
        }
    }

    public struct Result {
        public let samples: [Float]
        public let certain: Bool
        public let match: Float
        public let diagnostics: Diagnostics
    }

    private static func reduced(_ a: [Float]) -> [Float] {
        stride(from: 0, to: a.count - a.count % 8, by: 8).map { i in a[i..<i + 8].reduce(0, +) / 8 }
    }

    private static func locate(_ mic: [Float], _ reference: [Float], minimum: Int = 1000, maximum: Int = 1500) -> (lag: Int, score: Float)? {
        let width = min(reference.count, maximum)
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

    private struct Fit { let lag: Int; let gain: Float }

    private static func rms(_ audio: [Float]) -> Float {
        guard !audio.isEmpty else { return 0 }
        return (audio.reduce(Float(0)) { $0 + $1 * $1 } / Float(audio.count)).squareRoot()
    }

    /// Refine the eight-sample alignment at 16 kHz and fit volume without matching transcript tokens.
    private static func fit(_ mic: [Float], _ reference: [Float], coarse: Int) -> Fit? {
        let width = min(12_000, reference.count, mic.count)
        let low = max(0, coarse - 8), high = min(mic.count - width, coarse + 8)
        guard width > 0, low <= high else { return nil }
        var bestLag = coarse, bestDot: Float = 0, bestEnergy: Float = 0
        reference.withUnsafeBufferPointer { r in
            mic.withUnsafeBufferPointer { m in
                for lag in low...high {
                    var dot: Float = 0, energy: Float = 0
                    vDSP_dotpr(r.baseAddress!, 1, m.baseAddress! + lag, 1, &dot, vDSP_Length(width))
                    vDSP_svesq(r.baseAddress!, 1, &energy, vDSP_Length(width))
                    if abs(dot) > abs(bestDot) { bestDot = dot; bestEnergy = energy; bestLag = lag }
                }
            }
        }
        guard bestEnergy > 0 else { return nil }
        return Fit(lag: bestLag, gain: bestDot / bestEnergy)
    }

    private static func subtract(_ reference: [Float], fit: Fit, from mic: inout [Float]) {
        for i in 0..<min(reference.count, mic.count - fit.lag) { mic[i + fit.lag] -= fit.gain * reference[i] }
    }

    /// A gain change inside a window must not plant an inverted copy in its previously clean half.
    private static func subtractWindow(_ reference: [Float], lag: Int, from mic: inout [Float]) {
        let count = min(reference.count, mic.count - lag)
        for start in stride(from: 0, to: count, by: 640) {
            let end = min(count, start + 640)
            let part = Array(reference[start..<end])
            let heard = Array(mic[lag + start..<lag + end])
            var dot: Float = 0, energy: Float = 0
            vDSP_dotpr(part, 1, heard, 1, &dot, vDSP_Length(part.count))
            vDSP_svesq(part, 1, &energy, vDSP_Length(part.count))
            if energy > 0.000001 { subtract(part, fit: Fit(lag: lag + start, gain: dot / energy), from: &mic) }
        }
    }

    private static func correlation(_ a: [Float], _ b: [Float]) -> Float {
        guard !a.isEmpty, a.count == b.count else { return 0 }
        let xMean = a.reduce(0, +) / Float(a.count), yMean = b.reduce(0, +) / Float(b.count)
        let x = a.map { $0 - xMean }, y = b.map { $0 - yMean }
        var dot: Float = 0, xx: Float = 0, yy: Float = 0
        vDSP_dotpr(x, 1, y, 1, &dot, vDSP_Length(x.count))
        vDSP_svesq(x, 1, &xx, vDSP_Length(x.count)); vDSP_svesq(y, 1, &yy, vDSP_Length(y.count))
        return xx * yy > 0.000000001 ? abs(dot) / (xx * yy).squareRoot() : 0
    }

    /// An echo keeps the same delay and polarity across phonemes. A coincidentally similar vowel in the
    /// user's speech is not sufficient, even if it is the largest peak in a short window.
    private static func supportsEcho(_ mic: [Float], reference: [Float], fit: Fit, needed: Int) -> Bool {
        let count = min(12000, reference.count, mic.count - fit.lag)
        guard fit.lag >= 0, count >= 2560 else { return false }
        var supported = 0
        for start in stride(from: 0, through: count - 1280, by: 1280) {
            let x = Array(reference[start..<start + 1280]), y = Array(mic[fit.lag + start..<fit.lag + start + 1280])
            var dot: Float = 0
            vDSP_dotpr(x, 1, y, 1, &dot, vDSP_Length(x.count))
            if dot * fit.gain > 0, correlation(x, y) >= 0.20 { supported += 1 }
        }
        return supported >= needed
    }

    /// Jointly fit the measured room paths. Subtracting one correlated voice/path at a time can create an
    /// inverted copy of another. The small regularized system also handles changing gains in local windows.
    private static func joint(_ original: [Float], reference: [Float], lags: [Int], range: Range<Int>) -> [Float]? {
        let basis = lags.map { lag in range.map { t -> Float in
            let i = t - lag; return i >= 0 && i < reference.count ? reference[i] : 0
        } }
        let heard = Array(original[range]), n = basis.count
        guard n > 0, !heard.isEmpty else { return nil }
        var matrix = Array(repeating: Array(repeating: Double(0), count: n + 1), count: n)
        for i in 0..<n {
            var dot: Float = 0
            vDSP_dotpr(basis[i], 1, heard, 1, &dot, vDSP_Length(heard.count)); matrix[i][n] = Double(dot)
            for j in 0...i {
                vDSP_dotpr(basis[i], 1, basis[j], 1, &dot, vDSP_Length(heard.count))
                matrix[i][j] = Double(dot); matrix[j][i] = Double(dot)
            }
            matrix[i][i] += max(0.000001, matrix[i][i] * 0.001)
        }
        for i in 0..<n {
            guard let pivot = (i..<n).max(by: { abs(matrix[$0][i]) < abs(matrix[$1][i]) }), abs(matrix[pivot][i]) > 1e-12 else { return nil }
            matrix.swapAt(i, pivot)
            let scale = matrix[i][i]
            for j in i...n { matrix[i][j] /= scale }
            for row in 0..<n where row != i {
                let scale = matrix[row][i]
                for j in i...n { matrix[row][j] -= scale * matrix[i][j] }
            }
        }
        var out = heard
        for i in 0..<n {
            let gain = Float(matrix[i][n])
            guard gain.isFinite, abs(gain) < 16 else { return nil }
            for j in out.indices { out[j] -= gain * basis[i][j] }
        }
        return out
    }

    public static func removing(mic: [Float], played: [Float], preRoll: Int = 0) -> Result {
        let reference = Array(played.prefix(16_000 * 4))
        let opening = Array(mic.prefix(16_000 * 5))
        let ref = reduced(reference)
        let keyDown = min(max(0, preRoll), opening.count)
        // Startup and room delays are near key-down. Searching several later seconds can match a user's
        // unrelated vowel and mistake it for a video copy, particularly when both voices share a pitch.
        func longMatch(_ audio: [Float]) -> (lag: Int, score: Float)? {
            let low = preRoll > 0 ? max(0, keyDown - 512) : 0
            let high = preRoll > 0 ? min(audio.count, keyDown + 6400 + min(12000, reference.count)) : audio.count
            guard low < high, let hit = locate(reduced(Array(audio[low..<high])), ref) else { return nil }
            return (low + hit.lag * 8, hit.score)
        }
        var d = Diagnostics()
        if keyDown > 0 { d.preRollRMS = (opening.prefix(keyDown).reduce(Float(0)) { $0 + $1 * $1 } / Float(keyDown)).squareRoot() }
        func unchanged(_ reason: String, match: Float = 0, certain: Bool = false) -> Result {
            var diagnostic = d; diagnostic.reason = reason
            diagnostic.cuts = []; diagnostic.lostUserSamples = 0
            return Result(samples: mic, certain: certain, match: match, diagnostics: diagnostic)
        }
        guard let match = longMatch(opening) else { return unchanged("missingOrSilentReference") }
        // With an already-playing video, a quiet microphone before the user starts is evidence against
        // speaker pickup. A similar vowel said later must not turn headphones into a speaker clean-up.
        if let level = d.preRollRMS, level < 0.003, match.score < 0.30 { return unchanged("quietPreRollNoMeasuredEcho", match: match.score, certain: true) }
        if match.score < 0.10 {
            if let level = d.preRollRMS, level >= 0.003 { return unchanged("audiblePreRollWithoutEchoMatch", match: match.score) }
            return unchanged("noMeasuredEcho", match: match.score, certain: true)
        }
        guard match.score >= 0.14 else { return unchanged("middleBand", match: match.score) }
        guard let direct = fit(opening, reference, coarse: match.lag) else { return unchanged("delayFit", match: match.score) }

        d.gain = direct.gain
        d.lagMinusPreRoll = direct.lag - keyDown
        var cleaned = mic
        var earliestLag = direct.lag
        var lags = [direct.lag]
        subtract(reference, fit: direct, from: &cleaned)
        d.taps = 1
        d.firstResidual = longMatch(Array(cleaned.prefix(opening.count)))?.score ?? 0

        // Rooms carry several delayed, decaying copies. Fit them instead of rejecting the first reflection.
        // Stop before fitting unrelated user speech/noise.
        for _ in 0..<7 {
            let range = max(0, lags.min() ?? 0)..<min(mic.count, reference.count + (lags.max() ?? 0))
            guard let fitted = joint(mic, reference: reference, lags: lags, range: range) else { return unchanged("roomFit", match: match.score) }
            cleaned = mic; cleaned.replaceSubrange(range, with: fitted)
            let residual = Array(cleaned.prefix(opening.count))
            guard rms(residual) >= 0.003, let peak = longMatch(residual), peak.score >= 0.14,
                  let echo = fit(residual, reference, coarse: peak.lag),
                  supportsEcho(residual, reference: reference, fit: echo, needed: 3) else { break }
            guard !lags.contains(where: { abs($0 - echo.lag) < 4 }) else { break }
            subtract(reference, fit: echo, from: &cleaned)
            earliestLag = min(earliestLag, echo.lag)
            if !lags.contains(where: { abs($0 - echo.lag) < 4 }) { lags.append(echo.lag) }
            d.taps += 1
        }

        // The strongest peak can be a later reflection. Only the earliest measured full-reference path
        // defines missing audio; otherwise a loud reflection would erase recoverable opening words.
        let gap = preRoll > 0 ? keyDown..<max(keyDown, earliestLag) : keyDown..<keyDown
        d.gapSamples = gap.count
        d.gapRMS = gap.isEmpty ? 0 : (opening[gap].reduce(Float(0)) { $0 + $1 * $1 } / Float(gap.count)).squareRoot()
        guard gap.count <= 4000 else { return unchanged("earlierSpeechGapTooLong", match: match.score) }

        func applyMasks(_ audio: inout [Float]) {
            for i in 0..<max(keyDown, gap.upperBound) { audio[i] = 0 }
            for range in d.cuts { for i in range { audio[i] = 0 } }
        }

        // Before-key audio is video under the established key-down assumption. The old retained 150 ms
        // could itself contain video words. Only speakers take this path; headphone pre-roll stays intact.
        if !gap.isEmpty {
            d.cuts.append(gap)
        }
        applyMasks(&cleaned)

        // Adapt later windows too. If a measured copy survives four local fits, blank only its measured
        // 240 ms window, rather than refusing the dictation or blanking the entire opening.
        let covered = min(reference.count, cleaned.count - direct.lag)
        guard covered >= 3840 else { return unchanged("shortCoverage", match: match.score) }
        var largestWindow: Float = 0
        for proposed in stride(from: 0, to: covered, by: 3840) {
            let start = min(proposed, covered - 3840)
            let low = max(0, direct.lag + start - 2400)
            let high = min(cleaned.count, direct.lag + start + 3840 + 2400)
            let part = Array(reference[start..<start + 3840])
            for attempt in 0...4 {
                let residual = Array(cleaned[low..<high])
                guard rms(residual) >= 0.003 else { break }
                guard let peak = locate(reduced(residual), reduced(part), minimum: 400, maximum: 480) else { break }
                if peak.score > largestWindow {
                    largestWindow = peak.score; d.windowOffset = start; d.windowScore = peak.score
                }
                guard peak.score >= 0.20 else { break }
                guard let echo = fit(residual, part, coarse: peak.lag * 8) else {
                    d.windowScore = peak.score; d.windowOffset = start
                    return unchanged("windowDelayFit", match: match.score)
                }
                guard supportsEcho(residual, reference: part, fit: echo, needed: 2) else { break }
                if attempt == 4 { break }
                let lag = low + echo.lag - start
                if lag >= 0, lags.count < 12, !lags.contains(where: { abs($0 - lag) < 4 }) { lags.append(lag) }
                subtractWindow(part, lag: low + echo.lag, from: &cleaned)
                applyMasks(&cleaned)
                d.windowFits += 1
            }
        }

        // Reconstruct once from the original recording, using all detected paths together. This prevents
        // overlapping discovery windows from repeatedly adding/subtracting different pieces of the video.
        let reconstruction = max(0, lags.min() ?? 0)..<min(mic.count, reference.count + (lags.max() ?? 0))
        guard let whole = joint(mic, reference: reference, lags: lags, range: reconstruction) else { return unchanged("roomFit", match: match.score) }
        cleaned = mic
        cleaned.replaceSubrange(reconstruction, with: whole)
        applyMasks(&cleaned)

        // A late path/volume change needs a time-local fit. Evaluate fixed output windows and rewrite them
        // from the original, so changing a path cannot contaminate an already-clean neighbouring window.
        let changingPath = d.windowFits > 0
        for start in stride(from: reconstruction.lowerBound, to: reconstruction.upperBound, by: 640) {
            let range = start..<min(reconstruction.upperBound, start + 640)
            let hasEcho = lags.contains { lag in
                let refStart = range.lowerBound - lag, refEnd = range.upperBound - lag
                guard refStart >= 0, refEnd <= reference.count else { return false }
                return correlation(Array(cleaned[range]), Array(reference[refStart..<refEnd])) >= 0.20
            }
            if changingPath || hasEcho {
                guard let local = joint(mic, reference: reference, lags: lags, range: range) else { return unchanged("localRoomFit", match: match.score) }
                cleaned.replaceSubrange(range, with: local)
                d.windowFits += 1
                applyMasks(&cleaned)
            }
        }

        // Overlapping local corrections can change an already-checked later window or its delayed tail.
        // Recheck the entire reference after all fitting, with no further subtraction after this point.
        for proposed in stride(from: 0, to: covered, by: 3840) {
            let start = min(proposed, covered - 3840)
            let low = max(0, direct.lag + start - 2400)
            let high = min(cleaned.count, direct.lag + start + 3840 + 2400)
            let part = Array(reference[start..<start + 3840])
            for attempt in 0...8 {
                let residual = Array(cleaned[low..<high])
                guard rms(residual) >= 0.003 else { break }
                guard let peak = locate(reduced(residual), reduced(part), minimum: 400, maximum: 480) else { break }
                if peak.score > largestWindow { largestWindow = peak.score; d.windowOffset = start; d.windowScore = peak.score }
                guard peak.score >= 0.20 else { break }
                guard attempt < 8, let echo = fit(residual, part, coarse: peak.lag * 8) else {
                    d.windowScore = peak.score; d.windowOffset = start
                    return unchanged("windowResidualUnresolved", match: match.score)
                }
                guard supportsEcho(residual, reference: part, fit: echo, needed: 2) else { break }
                let origin = low + echo.lag
                let previousCuts = d.cuts.count
                // Prefer a 40 ms measured fragment to dropping an entire 240 ms window.
                for offset in stride(from: 0, to: part.count, by: 640) {
                    let end = min(part.count, offset + 640)
                    let from = max(keyDown, origin + offset), to = min(cleaned.count, origin + end)
                    guard from < to else { continue }
                    let refStart = offset + from - (origin + offset)
                    let refEnd = refStart + to - from
                    if correlation(Array(cleaned[from..<to]), Array(part[refStart..<refEnd])) >= 0.20 { d.cuts.append(from..<to) }
                }
                if d.cuts.count == previousCuts {
                    let from = max(keyDown, origin), to = min(cleaned.count, origin + part.count)
                    if from < to { d.cuts.append(from..<to) } else { return unchanged("windowBeforeKey", match: match.score) }
                }
                applyMasks(&cleaned)
            }
        }
        d.windowScore = largestWindow
        d.finalResidual = longMatch(Array(cleaned.prefix(opening.count)))?.score ?? 0
        let finalAudio = Array(cleaned.prefix(opening.count))
        if rms(finalAudio) >= 0.003, let peak = longMatch(finalAudio), peak.score >= 0.14,
           let echo = fit(finalAudio, reference, coarse: peak.lag), supportsEcho(finalAudio, reference: reference, fit: echo, needed: 3) {
            return unchanged("firstResidualUnresolved", match: match.score)
        }
        // Local correction can cross the startup boundary. Keep that unreferenced region blank.
        applyMasks(&cleaned)
        var end = keyDown
        for range in d.cuts.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            let lower = max(end, range.lowerBound)
            d.lostUserSamples += max(0, range.upperBound - lower)
            end = max(end, range.upperBound)
        }
        d.reason = d.cuts.isEmpty ? "echoRemoved" : "measuredAudioBlanked"
        return Result(samples: cleaned, certain: true, match: match.score, diagnostics: d)
    }
}
