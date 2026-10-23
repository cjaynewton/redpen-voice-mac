import Foundation

/// The scorecard: words spoken, how fast, and the typing time they replaced.
public struct Score: Equatable {
    public var words: Int
    public var seconds: Double
    public var count: Int
    /// A typed draft runs about 40 words a minute for most people. That is the clock the saving is measured against.
    public static let typedWordsPerMinute = 40.0

    public init(words: Int = 0, seconds: Double = 0, count: Int = 0) { self.words = words; self.seconds = seconds; self.count = count }

    public init(_ entries: [Entry]) {
        self.init(words: entries.reduce(0) { $0 + $1.words }, seconds: entries.reduce(0) { $0 + $1.seconds }, count: entries.count)
    }

    public var wordsPerMinute: Int { seconds > 0 ? Int((Double(words) / seconds * 60).rounded()) : 0 }
    /// Minutes typing would have taken, less the minutes spent talking. Never below zero.
    public var minutesSaved: Int { max(0, Int((Double(words) / Score.typedWordsPerMinute - seconds / 60).rounded())) }

    public static func today(_ entries: [Entry], now: Date = Date(), calendar: Calendar = .current) -> Score {
        Score(entries.filter { calendar.isDate($0.date, inSameDayAs: now) })
    }
}
