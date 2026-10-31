import Foundation

/// Did every word go in? Counted from RedpenVoice.log (D-1034, Oct 31 2026), which holds timings and counts, never the
/// words. Each finished dictation logs one line, "dictation 2s, 7 words, write 215ms, ..., into <app>, inserted true",
/// and the lines from its "audio:" line up to it say how its ending went.
///
/// - Landed in full: the words went in and Voice found nothing wrong. `inserted true`, nothing lost, and not "typing
///   not seen in the box". In a box Accessibility can't read back, that is Voice's typing finishing without an error,
///   all the app itself knows. Words that waited for a click count too, once the click took them.
/// - Kept: not every word went in, and they are on Paste last (⌃⌥V) and in History. The reason is the log's own.
/// - Lost: the engine's ending (or the whole dictation) never came out, so words are gone: "the ending failed",
///   "instant stopped answering", "finish failed", "timed out". The bar says "The last few words didn't come through".
/// - Not counted: presses with no words and quick taps. Escape twice throws a dictation away on purpose; it is
///   counted on its own, never as lost. "Another key while holding" is a Fn shortcut as often as a dictation, and the
///   log can't tell them apart, so it is only a count in the report.
public enum WordsLanded {
    public enum Outcome: Equatable, Sendable { case landed, kept, lost }

    /// One finished dictation, as the log tells it.
    public struct Dictation: Equatable, Sendable {
        public let at: Date
        public var outcome: Outcome
        /// Why it was kept or lost, one of the fixed names in this file; nil when it landed.
        public var why: String?
    }

    /// Landed, kept and lost dictations, and the ones thrown away with Escape.
    public struct Tally: Equatable, Sendable {
        public var landed = 0, kept = 0, lost = 0, thrownAway = 0
        public var dictations: Int { landed + kept + lost }
        public init(landed: Int = 0, kept: Int = 0, lost: Int = 0, thrownAway: Int = 0) {
            self.landed = landed; self.kept = kept; self.lost = lost; self.thrownAway = thrownAway
        }
        /// Whole percent landed in full, never shown as 100 while one wasn't.
        public var percent: Int? {
            guard dictations > 0 else { return nil }
            let p = Int((Double(landed) * 100 / Double(dictations)).rounded())
            return landed < dictations ? min(p, 99) : 100
        }
    }

    /// What one read of the log found. Only fixed names and times: nothing copied from a log line.
    public struct Read: Equatable, Sendable {
        public var dictations: [Dictation] = []
        public var thrownAway: [Date] = []
        /// Other things worth counting (failures, restarts), by fixed name.
        public var events: [Event] = []
        /// Each "launched" line, with what it says about the build ("" on logs from before D-1034).
        public var launches: [(at: Date, build: String)] = []
        public var first: Date?
        public var last: Date?
        public init() {}
        public static func == (a: Read, b: Read) -> Bool {
            a.dictations == b.dictations && a.thrownAway == b.thrownAway && a.events == b.events && a.first == b.first
                && a.last == b.last && a.launches.map(\.at) == b.launches.map(\.at) && a.launches.map(\.build) == b.launches.map(\.build)
        }
    }

    public struct Event: Equatable, Sendable {
        public let at: Date
        public let name: String
    }

    // MARK: Reading

    /// The log's ending lines that say words are gone, by the start of the line.
    static let lostLines: [(String, String)] = [
        ("engine: the ending failed", "ending failed"),
        ("engine: instant stopped answering", "engine stopped answering"),
        ("finish failed:", "engine failed"),
        ("engine: timed out, cancelling", "engine timed out"),
    ]

    /// Lines that say why a dictation's words were kept for Paste last. The last one before its dictation line wins.
    static let keptLines: [(String, String)] = [
        ("insert: the box you started in was sent", "box was sent"),
        ("insert: the box you started in was changed", "box was changed"),
        ("insert: the box you started in was left unconfirmed", "Voice's fix not confirmed"),
        ("draft: replacement not confirmed", "Voice's fix not confirmed"),
        ("draft: edit not confirmed", "Voice's fix not confirmed"),
        ("insert: away from the box you started in and a new press began", "a new press began"),
        ("insert: back in the box you started in and a new press began", "a new press began"),
        ("media: the video's words couldn't be written down", "video's words not checked"),
        ("draft blocked: echo failed", "video's words not checked"),
        ("insert: a Redpen Voice window is in front", "Voice window in front"),
        ("insert: no focused element", "no text box"),
        ("insert: focus left the text box", "no text box"),
        ("insert: no typing target while typing", "no text box"),
        ("insert: app changed while typing", "typing stopped"),
        ("insert: you typed or clicked, stopped", "typing stopped"),
        ("insert: draft target unreadable", "typing not confirmed"),
        ("insert: draft AX edit not confirmed", "typing not confirmed"),
        ("insert: draft typing not confirmed", "typing not confirmed"),
        ("insert: typing not seen in the box after a second", "typing not seen"),
    ]

    static let unseenLine = "insert: typing not seen in the box after a second"

    /// Counted for the report, by the start of the line. Never the rest of the line.
    static let eventLines: [(String, String)] = [
        ("cancelled: another key while holding", "stopped by another key while holding"),
        ("cancelled: quick tap", "quick tap"),
        ("mic failed:", "microphone failed to start"),
        ("first run: mic failed", "microphone failed to start"),
        ("mic warm failed:", "microphone failed to warm up"),
        // The longer starts first: "engine: whisper failed once" is a retry, "engine: whisper failed" a load failure.
        ("engine: whisper failed once, trying again", "Whisper tried a piece again"),
        ("engine: a check failed", "a piece failed, the ending covers it"),
        ("engine: a piece failed", "a piece failed, the ending covers it"),
        ("engine: instant failed while you talked", "a piece failed, the ending covers it"),
        ("engine: instant ending failed", "Instant's ending tried again"),
        ("engine: failed", "engine failed to load"),
        ("engine: parakeet failed", "engine failed to load"),
        ("engine: instant failed", "engine failed to load"),
        ("engine: whisper failed", "engine failed to load"),
        ("engine: draft engine failed", "engine failed to load"),
        ("draft: could not type", "typing stopped while talking: could not type"),
        ("live: you moved away from the box", "typing stopped while talking: left the box"),
        ("paste last: false", "Paste last not confirmed"),
        ("paste last: cursor not in a text box", "Paste last with no text box"),
        ("insert: couldn't confirm taking the typed words back out", "typed words not taken back"),
        ("hold key: release was missed", "missed key release"),
        ("meeting: no sound from the Mac", "meeting: no sound from the Mac"),
        ("meeting: write failed", "meeting: audio write failed"),
        ("watchdog: the app ended without quitting", "restarted after a crash"),
        ("watchdog: three crashes in a minute", "three crashes in a minute, not reopened"),
        ("watchdog: could not start", "watchdog could not start"),
    ]

    /// Paste's own failure reasons (Insert.paste, PasteAttempt), the only ones counted by name.
    static let pasteReasons: Set<String> = ["no text target", "target changed", "delivery not confirmed", "cancelled",
                                            "clipboard changed before posting", "shortcut keys still held",
                                            "could not construct Command-V"]
    /// Better summary's helpers (Config.betterSummaryWith).
    static let helpers: Set<String> = ["claude", "chatgpt", "gemini", "cursor", "command", "mac"]

    /// Reads the whole log. Lines it doesn't know are skipped; nothing from a line but its time is kept.
    public static func read(_ log: String) -> Read {
        var r = Read()
        // What this dictation's ending has said so far, from its "audio:" line on.
        var lost: String?, kept: String?, unseen = false, waits = false
        // The dictation whose words wait for a click (D-965, D-987), and whether typing them after it wasn't seen.
        var waiting: Int?, waitUnseen = false
        func settle(_ why: String) {
            if let w = waiting { r.dictations[w].why = why }
            waiting = nil; waitUnseen = false
        }
        for raw in log.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let at = time(raw) else { continue }
            let m = raw.dropFirst(21)
            if r.first == nil { r.first = at }
            r.last = at
            if m.hasPrefix("dictation "), let (words, inserted) = dictationLine(m) {
                if let why = lost { r.dictations.append(.init(at: at, outcome: .lost, why: why)) }
                else if words == 0 {}  // an empty press: no words to land
                else if waits, !inserted {
                    settle("no text box, still waiting")
                    r.dictations.append(.init(at: at, outcome: .kept, why: "no text box, still waiting"))
                    waiting = r.dictations.count - 1
                } else if inserted, !unseen { r.dictations.append(.init(at: at, outcome: .landed, why: nil)) }
                else if inserted { r.dictations.append(.init(at: at, outcome: .kept, why: "typing not seen")) }
                else { r.dictations.append(.init(at: at, outcome: .kept, why: kept ?? "not typed")) }
                lost = nil; kept = nil; unseen = false; waits = false
                continue
            }
            if m.hasPrefix("audio: ") { lost = nil; kept = nil; unseen = false; waits = false; continue }
            if m == "launched" || m.hasPrefix("launched ") {
                r.launches.append((at, m == "launched" ? "" : String(m.dropFirst("launched ".count))))
                if waiting != nil { settle("no text box, Voice quit or restarted") }
                continue
            }
            if m.hasPrefix("cancelled: Escape") { r.thrownAway.append(at); continue }
            if lost == nil, let hit = lostLines.first(where: { m.hasPrefix($0.0) }) { lost = hit.1 }
            if m.hasPrefix(unseenLine) { unseen = true; if waiting != nil { waitUnseen = true } }
            if let hit = keptLines.first(where: { m.hasPrefix($0.0) }) { kept = hit.1 }
            if m.hasPrefix("insert: cursor not in a text box (") {
                if m.hasSuffix("waiting for a click") { waits = true } else { kept = "a new press began" }
            }
            // How words waiting for a click ended.
            if let w = waiting {
                if m.hasPrefix("insert: pasted after a click into ") {
                    if m.hasSuffix(", true"), !waitUnseen { r.dictations[w].outcome = .landed; r.dictations[w].why = nil; waiting = nil; waitUnseen = false }
                    else { settle(m.hasSuffix(", true") ? "no text box, typing not seen after the click" : "no text box, couldn't type after the click") }
                }
                else if m.hasPrefix("insert: nobody clicked a text box") { settle("no text box, nobody clicked one in 10 minutes") }
                else if m.hasPrefix("insert: waiting words copied") { settle("no text box, copied from the bar") }
                else if m.hasPrefix("insert: waiting words thrown away") { settle("no text box, thrown away from the bar") }
                else if m.hasPrefix("insert: new press, the waiting words stay") { settle("no text box, a new press began") }
                else if m.hasPrefix("paste last: ") { settle("no text box, pasted with ⌃⌥V") }
            }
            if let name = eventName(m) { r.events.append(.init(at: at, name: name)) }
        }
        return r
    }

    /// The fixed name this line is counted under, if any. Codes are kept only in their own shape (domain and number).
    public static func eventName(_ m: Substring) -> String? {
        if let hit = eventLines.first(where: { m.hasPrefix($0.0) }) { return hit.1 }
        if m.hasPrefix("draft blocked: ") {
            let rest = m.dropFirst("draft blocked: ".count)
            guard let open = rest.firstIndex(of: "(") else { return nil }
            let reason = rest[..<open].trimmingCharacters(in: .whitespaces)
            return DraftSafety.Failure(rawValue: reason).map { "typing stopped while talking: \($0.rawValue)" }
        }
        // A failed paste, "paste: target changed; clipboard kept for Command-V". Its other lines aren't failures.
        if m.hasPrefix("paste: "), let semi = m.firstIndex(of: ";"), m[semi...].hasPrefix("; clipboard ") {
            let reason = String(m[m.index(m.startIndex, offsetBy: 7)..<semi])
            return pasteReasons.contains(reason) ? "paste: \(reason)" : "paste: other"
        }
        for (start, name) in [("meeting: could not start, ", "meeting could not start"), ("meeting: notes failed, ", "meeting notes failed"),
                              ("meeting: mic failed, ", "meeting microphone failed"), ("meeting: audio not saved, ", "meeting audio not saved"),
                              ("meeting: summary not saved, ", "meeting summary not saved")] where m.hasPrefix(start) {
            return "\(name) (\(code(m.dropFirst(start.count))))"
        }
        if m.hasPrefix("meeting: summary failed (") {
            // "(Type, domain code)": the code after the last comma.
            let inner = m.dropFirst("meeting: summary failed (".count).dropLast(m.hasSuffix(")") ? 1 : 0)
            let tail = inner.range(of: ", ", options: .backwards).map { inner[$0.upperBound...] } ?? inner
            return "meeting summary failed (\(code(tail)))"
        }
        if m.hasPrefix("meeting: better summary failed (") {
            let inner = m.dropFirst("meeting: better summary failed (".count)
            let helper = inner.prefix { $0 != ")" }
            return "better summary failed (\(helpers.contains(String(helper)) ? String(helper) : "other"))"
        }
        return nil
    }

    /// An error code as MeetingNotes.code writes it, "NSCocoaErrorDomain 4". Anything else is "other".
    static func code(_ s: Substring) -> String {
        let parts = s.split(separator: " ")
        guard parts.count == 2, let n = Int(parts[1]), parts[0].count <= 80, let first = parts[0].first, first.isLetter,
              parts[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_") }) else { return "other" }
        return "\(parts[0]) \(n)"
    }

    /// "dictation 2s, 7 words, ..., inserted true": the word count and whether it went in.
    public static func dictationLine(_ m: Substring) -> (words: Int, inserted: Bool)? {
        let inserted: Bool
        if m.hasSuffix(", inserted true") { inserted = true } else if m.hasSuffix(", inserted false") { inserted = false } else { return nil }
        let parts = m.split(separator: ",", maxSplits: 2)
        guard parts.count >= 2 else { return nil }
        let w = parts[1].trimmingCharacters(in: .whitespaces)
        guard w.hasSuffix(" words"), let words = Int(w.dropLast(" words".count)) else { return nil }
        return (words, inserted)
    }

    /// The line's time, "2026-10-31T08:57:20Z" at the start, read by hand: thousands of lines, no formatter.
    public static func time(_ line: Substring) -> Date? {
        let u = Array(line.utf8.prefix(21))
        guard u.count == 21, u[4] == 45, u[7] == 45, u[10] == 84, u[13] == 58, u[16] == 58, u[19] == 90, u[20] == 32 else { return nil }
        func n(_ a: Int, _ b: Int) -> Int? {
            var v = 0
            for i in a..<b { let c = Int(u[i]) - 48; guard (0...9).contains(c) else { return nil }; v = v * 10 + c }
            return v
        }
        guard let y = n(0, 4), let mo = n(5, 7), let d = n(8, 10), let h = n(11, 13), let mi = n(14, 16), let s = n(17, 19),
              (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, s < 61 else { return nil }
        // Days since 1970-01-01 (Howard Hinnant's days_from_civil).
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        return Date(timeIntervalSince1970: Double(days * 86_400 + h * 3600 + mi * 60 + s))
    }

    // MARK: Counting

    public static func tally(_ r: Read, from: Date = .distantPast, to: Date = .distantFuture) -> Tally {
        var t = Tally()
        for d in r.dictations where d.at >= from && d.at < to {
            switch d.outcome { case .landed: t.landed += 1; case .kept: t.kept += 1; case .lost: t.lost += 1 }
        }
        t.thrownAway = r.thrownAway.filter { $0 >= from && $0 < to }.count
        return t
    }

    /// The last `count` days on this Mac's calendar, today first.
    public static func days(_ r: Read, now: Date, count: Int = 7, calendar: Calendar = .current) -> [(day: Date, tally: Tally)] {
        let today = calendar.startOfDay(for: now)
        return (0..<count).compactMap { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: today),
                  let next = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            return (day, tally(r, from: day, to: next))
        }
    }

    /// When this build first started: the newest "launched" line, back through the ones before it that name the same
    /// build. Older logs name no build, so there it is the newest launch.
    public static func buildStarted(_ r: Read) -> Date? {
        guard var i = r.launches.indices.last else { return nil }
        let build = r.launches[i].build
        guard !build.isEmpty else { return r.launches[i].at }
        while i > 0, r.launches[i - 1].build == build { i -= 1 }
        return r.launches[i].at
    }

    /// "Today: 46 of 48 landed in full, 2 kept for ⌃⌥V, 0 lost".
    public static func line(_ label: String, _ t: Tally) -> String {
        let away = t.thrownAway > 0 ? "\(t.thrownAway) thrown away with Escape" : nil
        guard t.dictations > 0 else { return "\(label): " + (["no dictations"] + [away].compactMap { $0 }).joined(separator: ", ") }
        return "\(label): " + (["\(t.landed) of \(t.dictations) landed in full", "\(t.kept) kept for ⌃⌥V", "\(t.lost) lost"]
            + [away].compactMap { $0 }).joined(separator: ", ")
    }

    /// "Today", "Yesterday", then "Thu Oct 29".
    public static func label(_ day: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)), calendar.isDate(day, inSameDayAs: y) { return "Yesterday" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.dateFormat = "EEE MMM d"
        return f.string(from: day)
    }

    /// One line a day for the last `count` days, today first.
    public static func table(_ r: Read, now: Date, count: Int = 7, calendar: Calendar = .current) -> [String] {
        days(r, now: now, count: count, calendar: calendar).map { line(label($0.day, now: now, calendar: calendar), $0.tally) }
    }

    /// "Since this build started, Oct 31 4:57 AM: 30 of 32 landed in full (94%)".
    public static func sinceLine(_ r: Read, calendar: Calendar = .current, utc: Bool = false) -> String? {
        guard let start = buildStarted(r) else { return nil }
        let t = tally(r, from: start)
        let when = stamp(start, calendar: calendar, utc: utc)
        guard let p = t.percent else { return "Since this build started, \(when): no dictations yet" }
        return "Since this build started, \(when): \(t.landed) of \(t.dictations) landed in full (\(p)%), \(t.kept) kept, \(t.lost) lost"
    }

    /// Why words were kept or lost from `from` on, most first: "box was sent (2)".
    public static func reasons(_ r: Read, from: Date) -> (kept: [(String, Int)], lost: [(String, Int)]) {
        func count(_ o: Outcome) -> [(String, Int)] {
            var c: [String: Int] = [:]
            for d in r.dictations where d.at >= from && d.outcome == o { c[d.why ?? "not typed", default: 0] += 1 }
            return c.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { ($0.key, $0.value) }
        }
        return (count(.kept), count(.lost))
    }

    /// "Kept: box was sent (2). Lost: ending failed (1)." Nil when nothing was kept or lost.
    public static func reasonsLine(_ r: Read, from: Date) -> String? {
        let (k, l) = reasons(r, from: from)
        let parts = [("Kept", k), ("Lost", l)].filter { !$0.1.isEmpty }
            .map { "\($0.0): " + $0.1.map { "\($0.0) (\($0.1))" }.joined(separator: ", ") + "." }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// "Oct 31 4:57 AM" on this Mac's clock, or "2026-10-31 08:57 UTC" for a report read elsewhere.
    public static func stamp(_ d: Date, calendar: Calendar = .current, utc: Bool = false) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        if utc {
            f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd HH:mm"
            return f.string(from: d) + " UTC"
        }
        f.calendar = calendar; f.timeZone = calendar.timeZone; f.dateFormat = "MMM d h:mm a"
        return f.string(from: d)
    }

    /// The table, the line for this build, and why words were kept or lost, as `--words-landed` prints them.
    public static func summary(_ r: Read, now: Date, calendar: Calendar = .current) -> [String] {
        var out = table(r, now: now, calendar: calendar)
        if let s = sinceLine(r, calendar: calendar) { out.append(s) }
        let week = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? now
        if let why = reasonsLine(r, from: week) { out.append(why) }
        out.append(r.first.map { "The log goes back to \(stamp($0, calendar: calendar))." } ?? "The log is empty.")
        return out
    }
}
