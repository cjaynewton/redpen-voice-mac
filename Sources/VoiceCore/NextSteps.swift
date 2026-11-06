import Foundation

/// What has to happen after a meeting, most critical first (D-1108, D-1126). The dates and what is critical are found
/// by code in the lines that say each to-do, never by a model, so every one can be heard where it was said.
extension Meeting {
    /// How a to-do ranks. Critical: something else waits on it, or its date is today, tonight or tomorrow. Must do:
    /// a date was said. To do: no date was said. Nobody took it: no one said they would.
    public enum Urgency: Int, Comparable, CaseIterable, Sendable {
        case critical, dated, undated, unowned
        public static func < (a: Urgency, b: Urgency) -> Bool { a.rawValue < b.rawValue }
        public var label: String {
            switch self {
            case .critical: return "Critical"
            case .dated: return "Must do"
            case .undated: return "To do"
            case .unowned: return "Nobody took it"
            }
        }
    }

    /// Owners that mean nobody said they would do it.
    static let nobody: Set<String> = ["not clear", "nobody", "no one", "someone", "unclear", "unknown", "anyone", "tbd"]

    public static func isUnowned(_ who: String) -> Bool { nobody.contains(who.lowercased().trimmingCharacters(in: .whitespaces)) }

    public static func urgency(_ t: ToDo) -> Urgency {
        if isUnowned(t.who) { return .unowned }
        if t.critical { return .critical }
        return t.when == nil ? .undated : .dated
    }

    /// Most critical first, then in the order they were said.
    public static func ranked(_ todos: [ToDo]) -> [ToDo] {
        todos.enumerated().sorted { a, b in
            let x = urgency(a.element), y = urgency(b.element)
            if x != y { return x < y }
            let p = a.element.at ?? .infinity, q = b.element.at ?? .infinity
            return p != q ? p < q : a.offset < b.offset
        }.map(\.element)
    }

    /// Why a critical to-do is critical, in plain words, or nil.
    public static func why(_ t: ToDo) -> String? {
        guard t.critical else { return nil }
        if let w = t.when, isSoon(w) { return "Due \(w)" }
        return "Something waits on it"
    }

    // MARK: Dates

    private static let day = "(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday)"
    private static let part = "(?:\\s+(?:morning|afternoon|evening|night))?"
    private static let month = "(?:january|february|march|april|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec)"
    private static let datePattern = try! NSRegularExpression(pattern: "\\b(?:(?:by|before|on|until|for|this|next|over)\\s+)?(?:" + [
        "today", "tonight", "tomorrow" + part, "(?:this|next)\\s+" + day + part, day + part,
        "(?:the\\s+)?end\\s+of\\s+(?:the\\s+|this\\s+|next\\s+)?(?:day|week|month)", "(?:this|next)\\s+(?:week|month)", "the\\s+weekend",
        "first\\s+thing(?:\\s+(?:tomorrow|in\\s+the\\s+morning|monday))?", "asap", "as\\s+soon\\s+as\\s+possible", "right\\s+away", "eod",
        "this\\s+(?:morning|afternoon|evening)", "noon", "(?:in\\s+)?the\\s+morning",
        // "May 3" and "the 3rd of May" are dates; "may" alone is a verb, so it needs a number.
        // "The 3rd" alone is an ordinal ("the 3rd option"); it is a date with "of May" after it or "by" before it.
        month + "\\s+(?:the\\s+)?\\d{1,2}(?:st|nd|rd|th)?", "may\\s+(?:the\\s+)?\\d{1,2}(?:st|nd|rd|th)?", "the\\s+\\d{1,2}(?:st|nd|rd|th)\\s+of\\s+(?:" + month + "|may)",
    ].joined(separator: "|") + ")\\b|\\b(?:by|before|until)\\s+the\\s+\\d{1,2}(?:st|nd|rd|th)\\b", options: [.caseInsensitive])

    private static let soonPattern = try! NSRegularExpression(pattern: "\\b(?:today|tonight|tomorrow|asap|as soon as possible|right away|eod|first thing|end of (?:the |this )?day|this (?:morning|afternoon|evening)|noon|the morning)\\b", options: [.caseInsensitive])

    /// Today, tonight, tomorrow or sooner.
    public static func isSoon(_ when: String) -> Bool {
        soonPattern.firstMatch(in: when, range: NSRange(when.startIndex..., in: when)) != nil
    }

    /// The first date said in `text`, as said, without "by" or "on" ("tomorrow morning", "Monday", "end of the week").
    /// Past dates ("we spoke Monday") can't be told apart here, which is why each to-do keeps its source line.
    public static func date(in text: String) -> String? {
        let t = text.replacingOccurrences(of: "’", with: "'")
        let ns = t as NSString
        // After the "I'll" or "can you" when there is one: "I'll send it Friday" is the deadline, not "on Monday we met".
        var from = 0
        if let c = commitmentRange(t) { from = c.location }
        let matches = datePattern.matches(in: t, range: NSRange(location: 0, length: ns.length))
        guard let m = matches.first(where: { $0.range.location >= from }) ?? matches.first else { return nil }
        var s = ns.substring(with: m.range)
        if let r = s.range(of: "^(?:(?:by|before|on|until|for|over|in)\\s+(?=\\S))?(?:the\\s+(?=end\\b))?", options: [.regularExpression, .caseInsensitive]) { s.removeSubrange(r) }
        return s.lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .split(separator: " ").map { w in
                let d = String(w)
                let names = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march",
                             "april", "may", "june", "july", "august", "september", "october", "november", "december", "asap", "eod"]
                if d == "asap" || d == "eod" { return d.uppercased() }
                return names.contains(d) ? d.prefix(1).uppercased() + d.dropFirst() : d
            }.joined(separator: " ")
    }

    private static let replyStart = try! NSRegularExpression(pattern: "^\\W*(?:sure|yes|yeah|yep|ok|okay|will do|no problem|absolutely|definitely|done|got it|sounds good|fine|by)\\b", options: [.caseInsensitive])

    /// A to-do's words without any date that the line saying it, or the line on either side, doesn't say. A writer
    /// adding "by this afternoon" to a job nobody gave a time is the commonest made-up detail (D-1272).
    public static func withoutUnsaidDates(_ task: String, around i: Int, in lines: [Said]) -> String {
        guard lines.indices.contains(i) else { return task }
        let near = (max(0, i - 1)...min(lines.count - 1, i + 1)).map { lines[$0].text }.joined(separator: " ")
        let said = Set(keys(near))
        let ns = task as NSString
        var out = task
        // Only a deadline is taken out, never a date that names something ("Friday's board meeting", "the May 12
        // workshop", "the Sunday Times", "the 3rd quarter"): it starts with by, before, until or on, ends its clause,
        // and none of its words is said near the line. Anything less certain stays as written.
        for m in datePattern.matches(in: task, range: NSRange(location: 0, length: ns.length)).reversed() {
            let phrase = ns.substring(with: m.range)
            guard phrase.range(of: "^(?:by|before|until|on)\\s", options: [.regularExpression, .caseInsensitive]) != nil else { continue }
            let after = ns.substring(from: m.range.location + m.range.length)
            guard after.range(of: "^\\s*(?:[,.;!?]|$)", options: .regularExpression) != nil else { continue }
            let words = keys(phrase).filter { !["by", "before", "on", "until", "for", "over", "in", "the", "this", "of"].contains($0) }
            guard !words.isEmpty, !words.contains(where: said.contains) else { continue }
            out = (out as NSString).replacingCharacters(in: m.range, with: "")
        }
        guard out != task else { return task }
        out = out.replacingOccurrences(of: "\\s+([,.;!?])", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: ",\\s*([.;!?]|$)", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return out.isEmpty ? task : out
    }

    /// A line's sentences.
    public static func sentences(_ text: String) -> [String] {
        text.replacingOccurrences(of: "([.!?])\\s+", with: "$1\n", options: .regularExpression)
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The sentence of a line that says the to-do: the one sharing the most meaning words with it (the first on a
    /// tie). A line is one speaker's whole turn, so it can hold several to-dos with different dates.
    static func sentence(for task: String?, in text: String) -> (index: Int, all: [String]) {
        let all = sentences(text)
        guard let task, all.count > 1 else { return (0, all.isEmpty ? [text] : all) }
        let want = content(task)
        var best = 0, score = -1
        for (k, x) in all.enumerated() {
            let n = want.intersection(content(x)).count
            if n > score { best = k; score = n }
        }
        return (best, all)
    }

    /// The deadline for the to-do said at line `i`: in the sentence that says it, else in a short reply right after
    /// it that starts like one ("Sure, by Friday"), never in the next ask ("Can you order it Monday?"). Nil when none
    /// was said.
    public static func deadline(around i: Int, in lines: [Said], task: String? = nil) -> String? {
        guard lines.indices.contains(i) else { return nil }
        let s = sentence(for: task, in: lines[i].text)
        if let d = date(in: s.all[s.index]) { return d }
        // A reply only counts after the line's last sentence: what comes next answers that.
        guard s.index == s.all.count - 1 else { return nil }
        let next = i + 1
        guard lines.indices.contains(next) else { return nil }
        let t = lines[next].text
        guard t.split(separator: " ").count <= 10, replyStart.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil else { return nil }
        return date(in: t)
    }

    private static let waitsPattern = try! NSRegularExpression(pattern: "\\b(?:" + [
        "before (?:we|you|they|he|she|i|anyone|anybody) can", "until (?:we|you|they|he|she|i|that|this|it)(?:'s| is| are| has| have| get| gets| hear| know| do| does)?",
        "waiting (?:on|for)", "wait(?:s)? on", "depends on", "hinges on", "hold(?:s|ing)? (?:us|everything|it|things|the \\w+) up",
        "blocked", "blocks", "blocking", "can't (?:\\w+ ){0,5}until", "cannot (?:\\w+ ){0,5}until", "won't (?:\\w+ ){0,5}until",
        "nothing (?:\\w+ ){0,5}until", "push(?:es|ed)? (?:\\w+ ){0,5}past", "delay(?:s)? (?:the|everything|us)", "the one thing that could",
    ].joined(separator: "|") + ")\\b", options: [.caseInsensitive])

    /// Someone said something waits on it: in the sentence that says the to-do, or just before or after it (across
    /// the turn before or after when the sentence starts or ends one).
    public static func waitsOn(around i: Int, in lines: [Said], task: String? = nil) -> Bool {
        guard lines.indices.contains(i) else { return false }
        let s = sentence(for: task, in: lines[i].text)
        var near = [s.all[s.index]]
        if s.index > 0 { near.append(s.all[s.index - 1]) } else if i > 0, let last = sentences(lines[i - 1].text).last { near.append(last) }
        if s.index < s.all.count - 1 { near.append(s.all[s.index + 1]) } else if i + 1 < lines.count, let first = sentences(lines[i + 1].text).first { near.append(first) }
        return near.contains { x in
            let t = x.replacingOccurrences(of: "’", with: "'")
            return waitsPattern.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
        }
    }

    /// "Let me know" and "I can't" are not promises; "I need to" and "I have to" own the job but can be about anything,
    /// so only the owner rule uses them, never the sweep.
    private static let firstPerson = try! NSRegularExpression(pattern: "\\b(?:i'll|i will|i'm going to|i am going to|i'm gonna|i need to|i have to)\\b", options: [.caseInsensitive])
    private static let promise = try! NSRegularExpression(pattern: "\\b(?:i'll|i will|i'm going to|i am going to|i'm gonna)\\b", options: [.caseInsensitive])
    private static let negation = try! NSRegularExpression(pattern: "\\b(?:not|never|can't|cannot|won't|don't|couldn't|wouldn't|no longer)\\b", options: [.caseInsensitive])

    /// Who said they would do it, when the sentence that says the to-do is the speaker's own promise ("I'll send
    /// it"): that line's speaker, whoever a model named. Nil when it isn't a promise in the first person.
    public static func promiser(around i: Int, in lines: [Said], task: String) -> String? {
        guard lines.indices.contains(i) else { return nil }
        let s = sentence(for: task, in: lines[i].text)
        let t = s.all[s.index].replacingOccurrences(of: "’", with: "'")
        guard firstPerson.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil else { return nil }
        return lines[i].speaker
    }

    private static let leadIn = try! NSRegularExpression(pattern: "^(?:(?:okay|ok|so|then|and|but|well|yes|yeah|sure|right|alright|good|great|perfect|uh|um|and then|so then)[,.]?\\s+)*(?:i'll|i will|i'm going to|i am going to|i'm gonna)\\s+", options: [.caseInsensitive])

    /// Dated promises in the first person ("I'll redraw it tonight"), found by code in the transcript, so one a
    /// model missed is still on the list (D-1126). Each is the speaker's own sentence without its "I'll", at the line
    /// that says it. Questions and promises with no date are left to the writer.
    public static func promises(in lines: [Said]) -> [ToDo] {
        var out: [ToDo] = []
        for (i, l) in lines.enumerated() where l.speaker != Speaker.pause.rawValue {
            for x in sentences(l.text) where !x.hasSuffix("?") {
                let t = x.replacingOccurrences(of: "’", with: "'")
                let all = NSRange(t.startIndex..., in: t)
                guard promise.firstMatch(in: t, range: all) != nil, negation.firstMatch(in: t, range: all) == nil,
                      let when = date(in: t), !isPleasantry(t) else { continue }
                // Only a sentence that is the promise ("So I'll send it Friday"), never one with a promise somewhere in
                // the middle of something else: a real meeting's long run-on sentences made jobs of whole paragraphs.
                let ns = t as NSString
                guard let lead = leadIn.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { continue }
                var task = ns.replacingCharacters(in: lead.range, with: "").trimmingCharacters(in: .whitespaces)
                guard (2...30).contains(task.split(separator: " ").count), let f = task.first else { continue }
                task = f.uppercased() + task.dropFirst()
                out.append(ToDo(who: l.speaker, task: task, at: l.at, when: when,
                                critical: isSoon(when) || waitsOn(around: i, in: lines, task: task)))
            }
        }
        return out
    }

    /// A still-open item as the list shows it: as written when it is short; from a long pasted turn, its first
    /// question when it has one; otherwise nil.
    public static func openItem(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.split(separator: " ").count <= 30 { return t.isEmpty ? nil : t }
        return sentences(t).first { $0.hasSuffix("?") && $0.split(separator: " ").count <= 30 }
    }

    /// Near-repeats out (most of the shorter one's meaning words in the other), the first kept.
    static func distinct<T>(_ items: [T], text: (T) -> String, same: (T, T) -> Bool = { _, _ in true }) -> [T] {
        var out: [T] = [], seen: [Set<String>] = []
        for x in items {
            let c = content(text(x))
            let repeated = zip(out, seen).contains { kept, s in
                let n = min(s.count, c.count)
                return same(kept, x) && n > 0 && Double(s.intersection(c).count) >= 0.6 * Double(n)
            }
            if !repeated { out.append(x); seen.append(c) }
        }
        return out
    }

    private static let commitmentStart = try! NSRegularExpression(pattern: "\\b(?:i'll|i will|i'm going to|we'll|we will|you'll|can you|could you|let's|please|i need to|we need to)\\b", options: [.caseInsensitive])
    private static func commitmentRange(_ t: String) -> NSRange? {
        commitmentStart.firstMatch(in: t, range: NSRange(t.startIndex..., in: t))?.range
    }

    // MARK: In the file

    /// A to-do as the notes write it: `Me: Call the city (critical, by tomorrow morning)`.
    public static func todoLine(_ t: ToDo) -> String {
        var marks: [String] = []
        if t.critical { marks.append("critical") }
        if let w = t.when { marks.append("by \(w)") }
        return "\(t.who): \(t.task)" + (marks.isEmpty ? "" : " (\(marks.joined(separator: ", ")))")
    }

    private static let markPattern = try! NSRegularExpression(pattern: "\\s*\\((critical)?(?:,\\s*)?(?:by\\s+([^()]+?))?\\)\\s*$", options: [.caseInsensitive])

    /// A to-do's words without its marks, and the marks: the reverse of `todoLine`.
    public static func todoMark(_ text: String) -> (text: String, when: String?, critical: Bool) {
        let ns = text as NSString
        guard let m = markPattern.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.range(at: 1).location != NSNotFound || m.range(at: 2).location != NSNotFound else { return (text, nil, false) }
        let when = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)) : nil
        // "(by email)" in an older file or another writer's notes is how, not when: only a date counts.
        if let when, date(in: "by " + when) == nil, m.range(at: 1).location == NSNotFound { return (text, nil, false) }
        return (ns.replacingCharacters(in: m.range, with: ""), when.flatMap { date(in: "by " + $0) == nil ? nil : $0 }, m.range(at: 1).location != NSNotFound)
    }

    // MARK: The follow-up email

    /// A follow-up email written only from the checked notes: what was decided, who does what by when, and what is
    /// still open. `sender` signs it and stands in for Me; `people` are the others' names, when they have them.
    /// Nothing in it is anyone's guess, and nothing sends it.
    public static func followUp(_ s: Summary, meeting: String, sender: String, people: [String]) -> (subject: String, body: String) {
        let me = sender.isEmpty ? "Me" : sender
        func owner(_ who: String) -> String {
            switch who {
            case Speaker.me.rawValue: return me
            case Speaker.others.rawValue: return "You"
            default: return isUnowned(who) ? "Not decided yet" : who
            }
        }
        func sentence(_ t: String) -> String {
            let x = t.trimmingCharacters(in: .whitespaces)
            guard let f = x.first else { return x }
            let up = f.uppercased() + x.dropFirst()
            // A question keeps its question mark; a statement loses its full stop, so ", by Friday" can follow.
            return up.hasSuffix(".") || up.hasSuffix("!") ? String(up.dropLast()) : up
        }
        let named = people.filter { !$0.isEmpty }
        let hi = named.isEmpty ? "Hi all," : "Hi " + (named.count == 1 ? named[0] : named.dropLast().joined(separator: ", ") + " and " + named.last!) + ","
        var body = hi + "\n\nHere's what we agreed and what happens next.\n"
        if !s.decisions.isEmpty {
            body += "\nDecided\n" + s.decisions.map { "- " + sentence($0.text) }.joined(separator: "\n") + "\n"
        }
        let todos = ranked(s.todos)
        if !todos.isEmpty {
            body += "\nNext steps\n" + todos.map { t in
                "- \(owner(t.who)): " + sentence(t.task) + (t.when.map { ", by \($0)" } ?? "")
            }.joined(separator: "\n") + "\n"
        }
        if !s.open.isEmpty {
            body += "\nStill open\n" + s.open.map { "- " + sentence($0.text) }.joined(separator: "\n") + "\n"
        }
        if s.decisions.isEmpty && todos.isEmpty && s.open.isEmpty { body += "\nNothing was settled and nobody took anything on.\n" }
        body += "\nTell me if I missed anything.\n\n\(me)\n"
        return ("Next steps from " + meeting, body)
    }
}
