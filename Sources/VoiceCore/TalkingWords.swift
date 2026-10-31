import Foundation

/// What happens to your words while you talk (D-972, Oct 31 2026). `box`: they are typed into the text box as you go
/// (live words and quick drafts, D-763 and D-764). `bar`: they show on the bar and nothing is typed until you finish,
/// when the whole checked text goes in once, by the D-965 rules (the box you're in, or the next click into one).
public enum TalkingWords: String, Sendable {
    case box, bar

    /// The saved choice. Config files from before it keep what they did: quick drafts typed into the box whatever
    /// the old live words switch said, so drafts on means `box`; otherwise live words on (on when missing) typed
    /// into the box, and live words off typed nothing until the end, which `bar` still does.
    public static func choice(saved: String?, liveWords: Bool?, draftMode: Bool?) -> TalkingWords {
        if let saved, let c = TalkingWords(rawValue: saved) { return c }
        if draftMode == true { return .box }
        return liveWords == false ? .bar : .box
    }

    /// The newest words that fit the bar, from the first whole word, with "…" in front when the start is cut. Line
    /// breaks become spaces, so a long dictation never grows the bar past one line.
    public static func tail(_ text: String, limit: Int = 56) -> String {
        let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard limit > 1, flat.count > limit else { return flat }
        var start = flat.index(flat.endIndex, offsetBy: -(limit - 1))
        // Cut in the middle of a word: start at the next whole one, unless the rest is a single long word.
        if flat[flat.index(before: start)] != " ", let space = flat[start...].firstIndex(of: " "), flat.index(after: space) < flat.endIndex {
            start = flat.index(after: space)
        }
        return "…" + flat[start...]
    }

    public static func words(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    /// Why typing into the box stopped while you talked, in the bar's words.
    public enum Stop: Equatable, Sendable {
        case typed, clicked, typedOrClicked, leftBox, boxChanged, noBox, unchecked

        public var phrase: String {
            switch self {
            case .typed: return "you typed"
            case .clicked: return "you clicked"
            case .typedOrClicked: return "you typed or clicked"
            case .leftBox: return "you left the box"
            case .boxChanged: return "the box changed"
            case .noBox: return "not in a text box"
            case .unchecked: return "couldn't check the box"
            }
        }

        public init(_ failure: DraftSafety.Failure) {
            switch failure {
            case .hardwareKey: self = .typed
            case .hardwareClick: self = .clicked
            case .userActed: self = .typedOrClicked
            case .appChanged, .elementChanged: self = .leftBox
            case .boxCheck: self = .boxChanged
            case .deliveryUncertain, .editUnconfirmed, .echoFailed, .emptyText, .noRuns: self = .unchecked
            }
        }
    }

    /// The bar once typing stops while you still talk: what happened, the words so far (it keeps counting, so you
    /// can see it is still listening), and what happens next. Since D-965 the whole checked text goes in when you
    /// finish, so the bar no longer says the clipboard.
    public static func stoppedLine(_ why: Stop?, words: Int) -> String {
        let what = why.map { "Typing stopped (\($0.phrase))." } ?? "Typing stopped."
        guard words > 0 else { return what + " Your words go in at the end." }
        return "\(what) \(words) \(words == 1 ? "word" : "words") so far, all go in at the end."
    }

    /// The bar while words go into the box: how many so far, and hands-free how to stop.
    public static func typingLine(words: Int, handsFree: Bool, key: String) -> String {
        let count = "\(words) \(words == 1 ? "word" : "words")"
        return handsFree ? "Hands-free · \(count) · tap \(key) to stop" : count
    }

    /// Beside "Writing" after you stop, when typing had stopped earlier.
    public static let writingAfterStop = "All your words go in now"
}

/// The words the bar shows while you talk (D-972), kept in the order they were said. Drafts sit at their place in the
/// dictation and Whisper's check of a run of them takes their place.
public struct BarWords: Equatable, Sendable {
    public private(set) var parts: [String] = []
    public init() {}

    public mutating func draft(_ i: Int, _ text: String) {
        guard i >= 0 else { return }
        while parts.count <= i { parts.append("") }
        parts[i] = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func check(_ range: Range<Int>, _ text: String) {
        guard range.lowerBound >= 0, !range.isEmpty else { return }
        while parts.count < range.upperBound { parts.append("") }
        for i in range { parts[i] = "" }
        parts[range.lowerBound] = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var text: String { parts.filter { !$0.isEmpty }.joined(separator: " ") }
    public var words: Int { TalkingWords.words(text) }
}
