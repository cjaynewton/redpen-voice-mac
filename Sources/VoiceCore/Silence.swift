import Foundation

/// Whisper writes something even when nobody spoke: a sound label ("*Loud sound*", "[Music]") or one of the
/// phrases it learned from video endings ("Thank you."). Neither should be typed into your message.
public enum Silence {
    /// Phrases Whisper is known to invent from silence and noise. Dropped only when the audio was quiet, so a real
    /// "Thank you." said out loud still goes through.
    static let invented: Set<String> = [
        "thank you", "thank you so much", "thanks", "thanks for watching", "thank you for watching",
        "thank you very much", "bye", "you", "so", "okay", "oh", "subtitles by the amara.org community",
    ]

    /// Loudest sample below this means no one spoke near the mic. Talking at a normal distance peaks around 0.3 to 0.6.
    public static let quietPeak: Float = 0.08

    public static func clean(_ text: String, peak: Float) -> String {
        // Sound labels in stars, brackets or parentheses never hold your words.
        var out = text.replacingOccurrences(of: #"\*[^*]{1,40}\*|\[[^\]]{1,40}\]|\([^)]{1,40}\)"#, with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        if out.allSatisfy({ $0.isPunctuation || $0.isWhitespace }) { return "" }
        let bare = out.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        if peak < quietPeak, invented.contains(bare) { return "" }
        return out
    }
}
