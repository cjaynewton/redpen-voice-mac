import Foundation

/// The scorecard: words spoken, how fast, and the typing time they replaced.
public struct Score: Equatable {
    public var words: Int
    public var seconds: Double
    public var count: Int
    /// The typing speed the saving is measured against, in words a minute: yours, from Settings (D-837).
    public var typing: Double
    /// The default when you haven't set your own: a typed draft runs about 40 words a minute for most people.
    public static let typedWordsPerMinute = 40.0

    public init(words: Int = 0, seconds: Double = 0, count: Int = 0, typing: Double = Score.typedWordsPerMinute) {
        self.words = words; self.seconds = seconds; self.count = count; self.typing = typing
    }

    public init(_ entries: [Entry], typing: Double = Score.typedWordsPerMinute) {
        self.init(words: entries.reduce(0) { $0 + $1.words }, seconds: entries.reduce(0) { $0 + $1.seconds }, count: entries.count, typing: typing)
    }

    public var wordsPerMinute: Int { seconds > 0 ? Int((Double(words) / seconds * 60).rounded()) : 0 }
    /// Minutes typing would have taken, less the minutes spent talking. Never below zero.
    public var minutesSaved: Int { typing > 0 ? max(0, Int((Double(words) / typing - seconds / 60).rounded())) : 0 }

    /// "9 min", "1 h 5 min", or whole hours from 10 hours up.
    public static func savedText(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        if h >= 10 { return "\(Int((Double(minutes) / 60).rounded()).formatted()) h" }
        if m == 0 { return "\(h) h" }
        return "\(h) h \(m) min"
    }

    public static func today(_ entries: [Entry], now: Date = Date(), calendar: Calendar = .current) -> Score {
        Score(entries.filter { calendar.isDate($0.date, inSameDayAs: now) })
    }
}
