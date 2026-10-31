import Foundation

/// Send a report (D-1034, Oct 31 2026): what a tester can send the maintainer without him sitting beside them. Counts
/// and settings only. Never words, never app or window names, never file or folder names. Everything in it is a fixed
/// name from this file or WordsLanded, a number, or a setting value from the list below; the one exception is the
/// "What happened?" line, there only because the tester typed it. Nothing is sent: the window copies or saves it.
public enum VoiceReport {
    public struct Facts {
        public var version: String
        public var build: String
        public var macOS: String
        public var model: String
        public var memoryGB: Int
        /// Setting name and value, as the app reads them. Names and values not in `allowed` are left out or "other".
        public var settings: [(String, String)]
        public var log: String
        public var now: Date
        public var calendar: Calendar
        /// What the tester typed in "What happened?", or "".
        public var note: String
        public init(version: String, build: String, macOS: String, model: String, memoryGB: Int, settings: [(String, String)],
                    log: String, now: Date, calendar: Calendar = .current, note: String = "") {
            self.version = version; self.build = build; self.macOS = macOS; self.model = model; self.memoryGB = memoryGB
            self.settings = settings; self.log = log; self.now = now; self.calendar = calendar; self.note = note
        }
    }

    /// Every setting the report may name, with every value it may show. "#" allows a whole number.
    public static let allowed: [(String, Set<String>)] = [
        ("engine", ["dictation", "transcription", "whisper", "live", "parakeet"]),
        ("language", ["#locale"]),
        ("words", ["raw", "noUms", "rewrite"]),
        ("talk key", ["fnOrOption", "fn", "rightOption", "rightCommand", "rightControl", "other key"]),
        ("double tap for hands-free", ["on", "off"]),
        ("Enter stops and sends", ["on", "off"]),
        ("while I talk", ["box", "bar"]),
        ("quick drafts", ["on", "off"]),
        ("pause videos", ["on", "off"]),
        ("play again after", ["on", "off"]),
        ("point out words to check", ["on", "off"]),
        ("history kept", ["all", "week", "none"]),
        ("suggest words", ["on", "off"]),
        ("screen hints", ["on", "off"]),
        ("sounds", ["on", "off"]),
        ("level bar", ["pen", "bars", "tape", "dot", "classic", "off"]),
        ("appearance", ["light", "dark", "Mac"]),
        ("microphone", ["Mac default", "chosen"]),
        ("better summary", ["off", "claude", "chatgpt", "gemini", "cursor", "command", "mac"]),
        ("keep meeting audio", ["on", "off"]),
        ("meetings folder", ["default", "chosen"]),
        ("typing speed", ["#"]),
    ]

    /// The value as the report shows it: allowed, a whole number where one is allowed, a language code, or "other".
    public static func clean(_ name: String, _ value: String) -> String? {
        guard let ok = allowed.first(where: { $0.0 == name })?.1 else { return nil }
        if ok.contains(value) { return value }
        if ok.contains("#"), let n = Int(value), (0...10_000).contains(n) { return String(n) }
        if ok.contains("#locale"), isLocale(value) { return value }
        return "other"
    }

    /// "en-CA", "fr", "zh-Hans-CN": letters, digits and dashes in short parts.
    static func isLocale(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false).flatMap { $0.split(separator: "_", omittingEmptySubsequences: false) }
        guard let first = parts.first, (2...3).contains(first.count), first.allSatisfy({ $0.isASCII && $0.isLowercase }) else { return false }
        return parts.count <= 4 && parts.dropFirst().allSatisfy { (2...8).contains($0.count) && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }
    }

    /// Only a shape that can't hold a name: "0.12.2", "14", "27.0.1", "MacBookPro18,2". Anything else is "unknown".
    static func shaped(_ s: String, _ kind: String) -> String {
        let ascii = s.allSatisfy(\.isASCII)
        switch kind {
        case "version":
            return ascii && (1...16).contains(s.count) && s.first?.isNumber == true && s.allSatisfy({ $0.isNumber || $0 == "." }) ? s : "unknown"
        case "build":
            return ascii && (1...8).contains(s.count) && s.allSatisfy(\.isNumber) ? s : "unknown"
        default:
            // A Mac model id: letters, then numbers, a comma, numbers.
            let letters = s.prefix { $0.isLetter }, rest = s.dropFirst(letters.count)
            let nums = rest.split(separator: ",", omittingEmptySubsequences: false)
            return ascii && (2...20).contains(letters.count) && nums.count == 2
                && nums.allSatisfy({ (1...3).contains($0.count) && $0.allSatisfy(\.isNumber) }) ? s : "unknown"
        }
    }

    /// The note on one line, at most 1,000 characters.
    public static func note(_ s: String) -> String {
        let one = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return one.count > 1000 ? String(one.prefix(1000)) + "…" : one
    }

    public static func text(_ f: Facts) -> String {
        let r = WordsLanded.read(f.log)
        let cal = f.calendar
        let week = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: f.now)) ?? f.now
        var out: [String] = []
        out.append("Redpen Voice report")
        out.append("Made \(WordsLanded.stamp(f.now, utc: true)). Counts and settings only, never your words, app names or file names.")
        out.append("")
        out.append("Redpen Voice: \(shaped(f.version, "version")) (\(shaped(f.build, "build")))")
        out.append("macOS: \(shaped(f.macOS, "version"))")
        out.append("Mac: \(shaped(f.model, "model")), \(max(0, min(f.memoryGB, 4096))) GB memory")
        out.append("")
        out.append("Settings")
        for (name, value) in f.settings { if let v = clean(name, value) { out.append("  \(name): \(v)") } }
        out.append("")
        out.append("Words landed, the last 7 days")
        for l in WordsLanded.table(r, now: f.now, calendar: cal) { out.append("  " + l) }
        if let s = WordsLanded.sinceLine(r, calendar: cal, utc: true) { out.append("  " + s) }
        out.append("")
        out.append("Why words were kept or lost, the last 7 days")
        let (kept, lost) = WordsLanded.reasons(r, from: week)
        if kept.isEmpty && lost.isEmpty { out.append("  none") }
        for (why, n) in kept { out.append("  kept, \(why): \(n)") }
        for (why, n) in lost { out.append("  lost, \(why): \(n)") }
        out.append("")
        out.append("Other counts, the last 7 days")
        out.append("  Voice started: \(r.launches.filter { $0.at >= week }.count)")
        var counts: [String: Int] = [:]
        for e in r.events where e.at >= week { counts[e.name, default: 0] += 1 }
        counts["restarted after a crash", default: 0] += 0
        for (name, n) in counts.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }) { out.append("  \(name): \(n)") }
        out.append("")
        out.append(r.first.map { "The log goes back to \(WordsLanded.stamp($0, utc: true))." } ?? "The log is empty.")
        return out.joined(separator: "\n") + "\n" + noteSection(f.note)
    }

    /// The tester's own words, at the end, only when they typed some. The window adds it as they type.
    public static func noteSection(_ typed: String) -> String {
        let n = note(typed)
        return n.isEmpty ? "" : "\nWhat happened (typed by the person sending this)\n  \(n)\n"
    }
}
