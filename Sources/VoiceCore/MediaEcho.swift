import Foundation

/// Takes the video's words off the start of a dictation (D-817), instead of blanking the first second of audio,
/// which also lost your first words when you started talking before the video went quiet. Voice listens to the
/// paused app itself for that moment and writes down what it played; those words, at the start, are removed.
public enum MediaEcho {
    static func key(_ w: Substring) -> String {
        w.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Removes from the start of `text` everything up to the last word that matches the video's words. Only the first
    /// stretch is searched (the video's words plus a few), so the same word said later is never touched. Nothing is
    /// removed when the video said nothing that was heard.
    public static func strip(_ text: String, video: String) -> String {
        let v = video.split(whereSeparator: \.isWhitespace).map(key).filter { !$0.isEmpty }
        guard !v.isEmpty else { return text }
        let words = text.split(whereSeparator: \.isWhitespace)
        let window = min(words.count, v.count + 4)
        var lastMatch = -1, vi = 0
        for i in 0..<window {
            let k = key(words[i])
            guard !k.isEmpty else { continue }
            // In order: each video word may match once, a little ahead allowed for a word the two hearings disagree on.
            if let j = (vi..<min(v.count, vi + 3)).first(where: { v[$0] == k || alike(v[$0], k) }) {
                lastMatch = i; vi = j + 1
            }
        }
        guard lastMatch >= 0 else { return text }
        let rest = words.dropFirst(lastMatch + 1).joined(separator: " ")
        // A capital back on the first word kept, when the cut fell mid-sentence.
        guard let f = rest.first else { return "" }
        return f.uppercased() + rest.dropFirst()
    }

    /// Spelled much alike ("tel" and "tell"): two hearings of the same played word.
    static func alike(_ a: String, _ b: String) -> Bool {
        guard a.count >= 3, b.count >= 3 else { return false }
        let x = Array(a), y = Array(b)
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1)) }
            prev = cur
        }
        return prev[y.count] <= max(1, max(x.count, y.count) / 4)
    }
}
