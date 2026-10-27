import Foundation

/// One day's numbers for one engine (D-837). Numbers only: never a word you said.
public struct DayStats: Codable, Equatable {
    /// The day on this Mac's calendar, "2026-10-27".
    public var day: String
    /// The engine that wrote them ("whisper", "live", "dictation"), or "unknown" for days counted from the history.
    public var engine: String
    public var words: Int
    public var seconds: Double
    public var dictations: Int
    public init(day: String, engine: String, words: Int, seconds: Double, dictations: Int) {
        self.day = day; self.engine = engine; self.words = words; self.seconds = seconds; self.dictations = dictations
    }
}

/// The daily counts behind the menu's numbers and the Stats window, in stats.json beside the history. Its own file, so
/// keeping no history, keeping a week, or deleting a dictation never changes them. Only Reset does.
public final class StatsStore {
    struct File: Codable {
        var version = 1
        /// Counted once from history.jsonl when the file was first made, so the counts from before it carry over.
        var backfilled = false
        var days: [DayStats] = []
    }

    public let url: URL
    private var file = File()
    /// False when stats.json is there but can't be read: the counts are kept in memory and the file is never written
    /// over, so nothing on disk is lost.
    public private(set) var writable = true
    /// What went wrong with the file, said plainly, for the log.
    public private(set) var problem: String?

    public init(url: URL) {
        self.url = url
        reload()
    }

    public var days: [DayStats] { file.days }
    public var backfilled: Bool { file.backfilled }

    /// Reads the file again. Missing: a new store. Unreadable: kept as it is, never written. Readable but damaged:
    /// moved aside to stats.damaged-<time>.json and a new store started (the history is counted into it again).
    public func reload() {
        writable = true; problem = nil; file = File()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let d = try? Data(contentsOf: url) else {
            writable = false; problem = "stats.json can't be read; counts kept in memory only"
            return
        }
        if let f = try? JSONDecoder().decode(File.self, from: d) { file = f; return }
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = url.deletingLastPathComponent().appendingPathComponent("stats.damaged-\(stamp).json")
        if (try? FileManager.default.moveItem(at: url, to: aside)) != nil {
            problem = "stats.json was damaged; kept as \(aside.lastPathComponent) and started again"
        } else {
            writable = false; problem = "stats.json is damaged and couldn't be moved aside; counts kept in memory only"
        }
    }

    /// "2026-10-27" for a date, on this Mac's calendar and time zone.
    public static func key(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Counts one dictation.
    public func add(words: Int, seconds: Double, engine: String, date: Date = Date(), calendar: Calendar = .current) {
        tally(&file.days, day: StatsStore.key(date, calendar: calendar), engine: engine, words: words, seconds: seconds)
        _ = save()
    }

    /// The first time only: counts the dictations already in the history, so today's and all-time numbers carry over.
    /// Presses that caught no words are skipped, the same as a new dictation. Returns whether it ran.
    @discardableResult
    public func backfillIfNeeded(_ entries: [Entry], calendar: Calendar = .current) -> Bool {
        guard !file.backfilled else { return false }
        let before = file
        for e in entries where !e.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tally(&file.days, day: StatsStore.key(e.date, calendar: calendar), engine: "unknown", words: e.words, seconds: e.seconds)
        }
        file.backfilled = true
        // Not saved: counted again next time rather than marked done and lost.
        if !save() { file = before; return false }
        return true
    }

    /// Every count back to zero. The history is never counted again. False, and nothing changed, if it can't be saved.
    @discardableResult
    public func reset() -> Bool {
        let before = file
        file = File(backfilled: true, days: [])
        if !save() { file = before; return false }
        return true
    }

    private func tally(_ days: inout [DayStats], day: String, engine: String, words: Int, seconds: Double) {
        if let i = days.firstIndex(where: { $0.day == day && $0.engine == engine }) {
            days[i].words += words; days[i].seconds += seconds; days[i].dictations += 1
        } else {
            days.append(DayStats(day: day, engine: engine, words: words, seconds: seconds, dictations: 1))
        }
    }

    /// Readable only by you, written whole so a crash mid-write never leaves half a file.
    private func save() -> Bool {
        guard writable else { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        guard let d = try? enc.encode(file), (try? d.write(to: url, options: .atomic)) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }
}

/// Where a finished dictation goes (D-825, D-837): into the history as you chose to keep it, and into the day's
/// numbers always.
public enum Dictations {
    public static func record(_ e: Entry, keep: String, history: History, stats: StatsStore, engine: String, calendar: Calendar = .current) {
        if keep != "none" { history.append(e) }
        if keep == "week" { history.apply(keep: keep, now: e.date) }
        stats.add(words: e.words, seconds: e.seconds, engine: engine, date: e.date, calendar: calendar)
    }
}

/// Totals and series from the daily counts, for the menu and the Stats window.
public enum Stats {
    /// The days from `from` to `to`, both included (day keys compare as text).
    public static func score(_ days: [DayStats], from: String = "", to: String = "9999", typing: Double = Score.typedWordsPerMinute) -> Score {
        let d = days.filter { $0.day >= from && $0.day <= to }
        return Score(words: d.reduce(0) { $0 + $1.words }, seconds: d.reduce(0) { $0 + $1.seconds },
                     count: d.reduce(0) { $0 + $1.dictations }, typing: typing)
    }

    public static func today(_ days: [DayStats], now: Date = Date(), calendar: Calendar = .current, typing: Double = Score.typedWordsPerMinute) -> Score {
        let k = StatsStore.key(now, calendar: calendar)
        return score(days, from: k, to: k, typing: typing)
    }

    /// This calendar week, on this Mac's first day of the week.
    public static func thisWeek(_ days: [DayStats], now: Date = Date(), calendar: Calendar = .current, typing: Double = Score.typedWordsPerMinute) -> Score {
        let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        return score(days, from: StatsStore.key(start, calendar: calendar), to: StatsStore.key(now, calendar: calendar), typing: typing)
    }

    /// The last `n` days, today included.
    public static func lastDays(_ n: Int, _ days: [DayStats], now: Date = Date(), calendar: Calendar = .current, typing: Double = Score.typedWordsPerMinute) -> Score {
        let start = calendar.date(byAdding: .day, value: -(n - 1), to: calendar.startOfDay(for: now)) ?? now
        return score(days, from: StatsStore.key(start, calendar: calendar), to: StatsStore.key(now, calendar: calendar), typing: typing)
    }

    /// One slot per day for the last `n` days, oldest first, today last.
    public static func daily(_ days: [DayStats], n: Int = 30, now: Date = Date(), calendar: Calendar = .current) -> [(date: Date, score: Score)] {
        let today = calendar.startOfDay(for: now)
        return (0..<n).reversed().compactMap { back in
            guard let d = calendar.date(byAdding: .day, value: -back, to: today) else { return nil }
            let k = StatsStore.key(d, calendar: calendar)
            return (d, score(days, from: k, to: k))
        }
    }

    /// A day or week needs this much talking before its speed is drawn: one short "yes" would read as 300 words a minute.
    public static let minSecondsForSpeed = 20.0

    /// Speed over time: by day for the last 30 days, or by week (up to 26) once there is more than six weeks of
    /// counts. Nil where there was too little talking to say.
    public static func speed(_ days: [DayStats], now: Date = Date(), calendar: Calendar = .current) -> (weekly: Bool, points: [(date: Date, wpm: Int?)]) {
        let todayKey = StatsStore.key(now, calendar: calendar)
        let used = days.filter { $0.dictations > 0 && $0.day <= todayKey }.map(\.day)
        let today = calendar.startOfDay(for: now)
        let sixWeeksAgo = calendar.date(byAdding: .day, value: -42, to: today) ?? today
        func wpm(_ s: Score) -> Int? { s.seconds >= minSecondsForSpeed ? s.wordsPerMinute : nil }
        guard let first = used.min(), first < StatsStore.key(sixWeeksAgo, calendar: calendar) else {
            return (false, daily(days, now: now, calendar: calendar).map { ($0.date, wpm($0.score)) })
        }
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        var points: [(Date, Int?)] = []
        for back in (0..<26).reversed() {
            guard let start = calendar.date(byAdding: .weekOfYear, value: -back, to: thisWeek),
                  let end = calendar.date(byAdding: .day, value: 6, to: start) else { continue }
            let from = StatsStore.key(start, calendar: calendar), to = StatsStore.key(end, calendar: calendar)
            if to < first { continue }
            points.append((start, wpm(score(days, from: from, to: to))))
        }
        return (true, points)
    }
}
