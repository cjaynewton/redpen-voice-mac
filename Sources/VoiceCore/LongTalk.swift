import Foundation

/// Long talks land whole (D-1023, Oct 31 2026). Past `after` seconds Voice stops typing rough words into the box; the
/// bar keeps counting them. At the end the box keeps the words Whisper already checked there, only the rough words
/// after them come out, and the rest of the checked dictation goes in with one paste. The old ending erased the whole
/// rough draft key by key and typed it all again: on Oct 31, 8 of 11 dictations over a minute didn't land, and the
/// 3-minute one (568 words) erased 1,686 of 2,914 letters, couldn't confirm the box, and stopped halfway.
/// Enter on a long talk waits up to `enterWait` for the words and is never sent when they didn't all go in.
public enum LongTalk {
    /// When a dictation counts as long, from the press.
    public static let after: Double = 45
    /// How long a held Enter waits on a long talk. Past it the Enter is dropped, not sent.
    public static let enterWait: Double = 60

    public static func isLong(seconds: Double) -> Bool { seconds >= after }

    /// The talk's length in the bar's words: "50 seconds", "1 minute", "3 minutes".
    public static func length(seconds: Double) -> String {
        guard seconds >= 60 else { return "\(Int(seconds)) seconds" }
        let m = Int((seconds / 60).rounded())
        return m == 1 ? "1 minute" : "\(m) minutes"
    }

    /// Beside "Writing" once a long talk stops.
    public static func writingNote(seconds: Double) -> String { "Putting in your \(length(seconds: seconds)) of talk" }
    /// Beside "Writing" while a held Enter waits on a long talk.
    public static func sendingNote(seconds: Double) -> String { "Sends when your \(length(seconds: seconds)) is in" }
    /// The bar when a held Enter waited a minute and was dropped. Part of the talk may be in the box, so it points
    /// at the box, not at ⌃⌥V, which pastes every word and would repeat that part.
    public static let notSent = "Not sent. Check the box before you press Enter"

    /// The ending's split of the runs typed into the box, in order, each checked by Whisper or still rough: the
    /// leading checked runs stay, and the text of every run after them comes out.
    public static func split(_ runs: [(text: String, checked: Bool)]) -> (keep: Int, erase: String) {
        let keep = runs.prefix { $0.checked }.count
        return (keep, runs.dropFirst(keep).map(\.text).joined())
    }
}
