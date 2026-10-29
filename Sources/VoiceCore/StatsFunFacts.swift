import Foundation

/// Small comparisons from all-time counts. No history text, outside speed estimates or reward system.
public enum StatsFunFacts {
    public struct Book: Sendable {
        public let title: String
        public let words: Int
    }

    // Standard Ebooks' displayed wordCount metadata, fetched 2026-10-29. Counts belong to those editions;
    // translations and counting rules differ, so every displayed comparison says "about".
    // The complete source list is in docs/book-word-counts.md and the T3 project's notes/book-word-counts.md.
    public static let books: [Book] = [
        .init(title: "A Christmas Carol", words: 28_626), // https://standardebooks.org/ebooks/charles-dickens/a-christmas-carol
        .init(title: "The Call of the Wild", words: 31_792), // https://standardebooks.org/ebooks/jack-london/the-call-of-the-wild
        .init(title: "The Great Gatsby", words: 48_465), // https://standardebooks.org/ebooks/f-scott-fitzgerald/the-great-gatsby
        .init(title: "Frankenstein", words: 77_898), // https://standardebooks.org/ebooks/mary-shelley/frankenstein
        .init(title: "Pride and Prejudice", words: 121_970), // https://standardebooks.org/ebooks/jane-austen/pride-and-prejudice
        .init(title: "Jane Eyre", words: 186_958), // https://standardebooks.org/ebooks/charlotte-bronte/jane-eyre
        .init(title: "Moby-Dick", words: 211_202), // https://standardebooks.org/ebooks/herman-melville/moby-dick
        .init(title: "War and Peace", words: 563_500), // https://standardebooks.org/ebooks/leo-tolstoy/war-and-peace/louise-maude_aylmer-maude
    ]

    /// The nearest book below and above your total. At either end there is just one comparison.
    public static func bookLines(words: Int) -> [String] {
        guard words > 0 else { return [] }
        let lower = books.last { $0.words <= words }
        let upper = books.first { $0.words > words }
        return [lower, upper].compactMap { $0 }.map { book in
            let ratio = Double(words) / Double(book.words)
            if ratio < 0.01 { return "Your \(words.formatted()) \(words == 1 ? "word is" : "words are") less than about 1% of \(book.title)." }
            if ratio < 1 {
                let percent = ratio < 0.1 ? Int((ratio * 100).rounded()) : Int((ratio * 20).rounded()) * 5
                return "You've spoken about \(percent)% of the words in \(book.title)."
            }
            let times = (ratio * 10).rounded() / 10
            if times == 1 { return "You've spoken about as many words as \(book.title)." }
            return "You've spoken about \(times.formatted(.number.precision(.fractionLength(0...1)))) times as many words as \(book.title)."
        }
    }

    public static func lines(_ days: [DayStats], calendar: Calendar = .current) -> [String] {
        let total = Stats.score(days)
        guard total.words > 0 else { return [] }
        var facts = bookLines(words: total.words)
        let byDay = Dictionary(grouping: days, by: \.day).map { (day: $0.key, words: $0.value.reduce(0) { $0 + $1.words }) }
        if let longest = byDay.sorted(by: { $0.words == $1.words ? $0.day < $1.day : $0.words > $1.words }).first {
            let parts = longest.day.split(separator: "-").compactMap { Int($0) }
            if parts.count == 3, let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) {
                facts.append("Your longest day was \(longest.words.formatted()) words on \(date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, calendar: calendar, timeZone: calendar.timeZone))).")
            }
        }
        if total.seconds > 0 { facts.append("You've talked for \(talkingTime(total.seconds)) in total.") }
        return facts
    }

    /// Whole minutes from the recorded duration, without rounding up to a minute not yet spoken.
    public static func talkingTime(_ seconds: Double) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes == 0 { return "less than a minute" }
        let hours = minutes / 60, rest = minutes % 60
        func unit(_ n: Int, _ word: String) -> String { "\(n.formatted()) \(word)\(n == 1 ? "" : "s")" }
        if hours == 0 { return unit(rest, "minute") }
        if rest == 0 { return unit(hours, "hour") }
        return unit(hours, "hour") + " " + unit(rest, "minute")
    }
}
