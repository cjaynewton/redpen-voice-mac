import Foundation

/// The summary, version 2 (D-956). Every key point, decision and to-do ends with the time of the transcript line that
/// says it, and code checks that line before the item is kept: the words it shares with the item, every number in it,
/// and for a to-do, that someone said they would do it or asked for it. The same check runs on Apple's summary and on
/// one written by Claude, ChatGPT or Gemini.
extension Meeting {
    /// A key point or a decision, and when it was said, in seconds from the start (nil when no time was given).
    public struct Cited: Equatable, Sendable {
        public var text: String
        public var at: Double?
        public init(_ text: String, at: Double? = nil) { self.text = text; self.at = at }
    }

    public struct ToDo: Equatable, Sendable {
        public var who: String
        public var task: String
        public var at: Double?
        public init(who: String, task: String, at: Double? = nil) { self.who = who; self.task = task; self.at = at }
    }

    public struct Summary: Equatable, Sendable {
        public var overview: String
        public var points: [Cited]
        public var decisions: [Cited]
        public var todos: [ToDo]
        public init(overview: String = "", points: [Cited] = [], decisions: [Cited] = [], todos: [ToDo] = []) {
            self.overview = overview; self.points = points; self.decisions = decisions; self.todos = todos
        }
        public var isEmpty: Bool { overview.isEmpty && points.isEmpty && decisions.isEmpty && todos.isEmpty }
        public var items: Int { points.count + decisions.count + todos.count }
    }

    /// One line of the transcript: when, who, what.
    public struct Said: Equatable, Sendable {
        public var at: Double
        public var speaker: String
        public var text: String
        public init(at: Double, speaker: String, text: String) { self.at = at; self.speaker = speaker; self.text = text }
    }

    /// What the check did: items kept as cited, kept with the time moved to the line that says them, and left out.
    public struct Checked: Equatable, Sendable {
        public var summary: Summary
        /// Items that came with no time, or a time that isn't a moment of the meeting.
        public var uncited = 0
        /// Items whose time pointed at a line that doesn't say them, moved to one that does.
        public var moved = 0
        /// Items no line of the transcript says: left out.
        public var dropped = 0
        /// To-dos left out because nobody said they would do it or asked for it (thanks, goodbyes, plain points).
        public var notTasks = 0
        public init(summary: Summary) { self.summary = summary }
    }

    /// The label above Apple's summary.
    public static let summaryLabel = "*Written on this Mac by Apple's model. Check it against the transcript.*"

    /// The label above a summary from the user's own Claude, ChatGPT or Gemini.
    public static func betterLabel(_ who: String) -> String { "*Written by \(who) (your account). Check it against the transcript.*" }

    /// The label above a summary from the writer downloaded to this Mac (D-1010).
    public static func localLabel(_ who: String) -> String { "*Written on this Mac by \(who) (your download). Check it against the transcript.*" }

    /// The label above a summary from the user's own command (D-1012). Never the command itself, which may hold a key.
    public static let commandLabel = "*Written by your own command (your choice). Check it against the transcript.*"

    /// Apple's summary's heading once a better one sits above it.
    public static let freeHeading = "## Summary written on this Mac"

    // MARK: Times

    /// Seconds from `12:34`, `1:02:03` or `[12:34]`; nil for anything else.
    public static func seconds(_ clock: String) -> Double? {
        let parts = clock.trimmingCharacters(in: CharacterSet(charactersIn: "[]() ")).split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        let n = parts.compactMap { Int($0) }
        guard n.count == parts.count, n.allSatisfy({ $0 >= 0 }), n[n.count - 1] < 60, parts.last?.count == 2 else { return nil }
        if n.count == 3 { guard n[1] < 60, parts[1].count == 2 else { return nil } }
        return Double(n.reduce(0) { $0 * 60 + $1 })
    }

    private static let clockPattern = #"\d{1,2}:\d{2}(?::\d{2})?"#
    private static let trailingTime = try! NSRegularExpression(
        pattern: #"\s*\[\s*(\#(clockPattern))(?:\s*(?:,|;|-|–|and|to)\s*\#(clockPattern))*\s*\]\s*[.;,]?\s*$"#)
    private static let leadingTime = try! NSRegularExpression(pattern: #"^\s*\[\s*(\#(clockPattern))\s*\]\s*"#)

    /// An item's words and its time, from `The budget goes up 20%. [12:34]`. With several times, the first one counts.
    /// Only square brackets cite: "Next call Tuesday (10:30)" keeps its time of day.
    public static func cited(_ s: String) -> (text: String, at: Double?) {
        let ns = s as NSString
        for re in [trailingTime, leadingTime] {
            if let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) {
                let text = ns.replacingCharacters(in: m.range, with: "").trimmingCharacters(in: .whitespaces)
                return (text, seconds(ns.substring(with: m.range(at: 1))))
            }
        }
        return (s.trimmingCharacters(in: .whitespaces), nil)
    }

    /// The transcript's lines (`[12:34] Me: words`), without pause marks or anything else.
    public static func said(_ transcript: String) -> [Said] {
        var out: [Said] = []
        for line in transcript.components(separatedBy: "\n") where line.hasPrefix("[") {
            guard let close = line.firstIndex(of: "]"), let at = seconds(String(line[...close])) else { continue }
            let rest = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
            // The speaker is what comes before the first ": ": Me, Others, Person 2, or a name given to a voice.
            guard let colon = rest.range(of: ": ") else { continue }
            let who = String(rest[..<colon.lowerBound])
            guard isSpeaker(who) else { continue }
            out.append(Said(at: at, speaker: who, text: String(rest[colon.upperBound...])))
        }
        return out
    }

    /// A speaker label: one to six words starting with a letter, at most 40 characters, with no brackets, colon or
    /// line break. The same rule decides what Name the voices accepts, so a named voice is never lost.
    public static func isSpeaker(_ s: String) -> Bool {
        guard let f = s.first, f.isLetter, s == s.trimmingCharacters(in: .whitespaces), s.count <= 40,
              s.split(separator: " ").count <= 6 else { return false }
        return s.rangeOfCharacter(from: CharacterSet(charactersIn: "[]:\n")) == nil
    }

    /// The transcript part of a notes file: what comes after `## Transcript`, up to the next heading.
    public static func transcript(inFile file: String) -> String {
        guard let r = file.range(of: "\n## Transcript\n") ?? (file.hasPrefix("## Transcript\n") ? file.range(of: "## Transcript\n") : nil) else { return "" }
        let rest = file[r.upperBound...]
        if let next = rest.range(of: "\n## ") { return String(rest[..<next.lowerBound]) }
        return String(rest)
    }

    // MARK: Words

    /// Words that say nothing about what a line is about, and summary words a transcript rarely uses.
    static let common: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one", "our", "out",
        "has", "him", "his", "how", "its", "may", "now", "see", "who", "did", "get", "got", "let", "say", "she", "too",
        "use", "that", "this", "with", "have", "from", "they", "will", "would", "there", "their", "what", "about",
        "which", "when", "make", "like", "just", "know", "take", "into", "your", "some", "could", "them", "than",
        "then", "also", "been", "were", "said", "each", "more", "other", "others", "very", "well", "want", "going",
        "gonna", "yeah", "okay", "really", "think", "need", "needs", "should", "these", "those", "thing", "things",
        "here", "where", "being", "because", "does", "doing", "done", "over", "only", "even", "much", "many", "such",
        "most", "through", "after", "before", "while", "again", "once", "both", "between", "yes", "right", "kind",
        "sort", "lot", "way", "able", "sure", "maybe", "still", "back", "come", "look", "good", "great", "thank",
        "thanks", "percent", "people", "everyone", "everybody", "someone", "something", "anything", "team", "meeting", "call",
        "discussed", "discuss", "discussion", "mentioned", "noted", "explained", "highlighted", "emphasized",
        "emphasised", "suggested", "proposed", "stated", "shared", "agreed", "decided", "talked", "speaker",
        "shall", "must", "might", "ill", "youll", "theyll", "lets", "im", "ive", "dont",
    ]

    /// Numbers said as words, so "five thousand" in the transcript backs "5,000" in a summary.
    static let smallNumbers: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    static let bigNumbers: [String: Int] = ["thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]

    /// The text's words with every number as digits: "five thousand" is 5000, "twenty five" is 25, "2 million" is
    /// 2000000. "One" is a number only inside a bigger one ("one hundred", "twenty one"), never in "no one".
    static func words(_ text: String) -> [String] {
        // A time of day is the number said: "10:00" is 10, "12:30" is 1230, as a transcript writes "at 10" or "1230".
        let w = keys(text.replacingOccurrences(of: #"\b(\d{1,2}):00\b"#, with: "$1", options: .regularExpression))
        var out: [String] = [], total = 0, cur = 0, inNumber = false
        // What came last in the number: 1 a unit or teen, 2 a ten, 3 hundred, thousand or more.
        var last = 0
        func flush() { if inNumber { out.append(String(total + cur)); total = 0; cur = 0; inNumber = false; last = 0 } }
        for (i, k) in w.enumerated() {
            let next = i + 1 < w.count ? w[i + 1] : ""
            let scale = next == "hundred" || bigNumbers[next] != nil
            if k == "one", !inNumber, !scale { flush(); out.append(k); continue }
            if let v = smallNumbers[k] {
                // "five six" is two numbers; "twenty five" and "two hundred fifty" are one.
                if inNumber, last == 1 || (last == 2 && v >= 10) { flush() }
                cur += v; inNumber = true; last = v >= 20 && v % 10 == 0 ? 2 : 1
            } else if k == "hundred" {
                cur = max(cur, 1) * 100; inNumber = true; last = 3
            } else if let m = bigNumbers[k] {
                total += max(cur, 1) * m; cur = 0; inNumber = true; last = 3
            } else if let d = Int(k), scale, !inNumber {
                cur = d; inNumber = true; last = 1
            } else {
                flush(); out.append(k)
            }
        }
        flush()
        return out
    }

    /// A rough stem, so "budgets", "budgeting" and "budget" match.
    static func stem(_ w: String) -> String {
        if w.contains(where: \.isNumber) { return w }
        var s = w
        for suffix in ["ing", "ed", "es", "s", "ly"] where s.count > suffix.count + 3 && s.hasSuffix(suffix) {
            s.removeLast(suffix.count); break
        }
        return String(s.prefix(6))
    }

    /// The words of `text` that carry its meaning, stemmed; numbers kept whole.
    static func content(_ text: String) -> Set<String> {
        Set(words(text).compactMap { w -> String? in
            if w.contains(where: \.isNumber) { return w }
            return w.count >= 3 && !common.contains(w) ? stem(w) : nil
        })
    }

    /// The numbers in `text` ("20%" is 20, "$5,000" is 5000, "Q3" is q3), and numbers said as words.
    static func numbers(_ text: String) -> Set<String> {
        Set(words(text).filter { $0.contains(where: \.isNumber) })
    }

    /// Said when someone takes something on or asks for it. "Going to" counts only after a person ("we're going
    /// to send it"), never after a thing ("sales are going to drop").
    private static let commitment = try! NSRegularExpression(pattern: "\\b(" + [
        "i'll", "i will", "i'm going to", "i am going to", "i'm gonna", "i need to", "i have to", "i'd like to", "let me",
        "we'll", "we will", "we're going to", "we are going to", "we're gonna", "we need to", "we have to", "we should",
        "you'll", "you will", "you're going to", "you are going to", "he'll", "she'll", "they'll", "he's going to",
        "she's going to", "they're going to", "will you", "can you", "could you", "would you", "can we", "could we",
        "let's", "let us", "please", "make sure", "action item", "need you to", "want you to",
    ].joined(separator: "|") + ")\\b", options: [.caseInsensitive])

    /// Words of thanks, goodbyes and small talk. A task made only of these (and common words) is never a to-do.
    private static let pleasantryWords: Set<String> = [
        "weekend", "enjoy", "thank", "thanks", "nice", "meet", "meeting", "see", "talk", "soon", "care", "good",
        "great", "lovely", "bye", "goodbye", "congratulations", "congrats", "birthday", "safe", "travels", "trip",
        "feel", "better", "happy", "holiday", "holidays", "day", "evening", "night", "everyone", "everybody", "rest",
        "hope", "wish", "time", "joining", "coming", "chat", "catching", "wonderful", "fun",
    ]

    public static func isCommitment(_ text: String) -> Bool {
        let t = text.replacingOccurrences(of: "’", with: "'")
        return commitment.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

    /// Thanks or a goodbye and nothing else: "Have a lovely weekend" is, "Finish the report over the weekend" isn't.
    public static func isPleasantry(_ text: String) -> Bool {
        let w = keys(text)
        guard w.contains(where: { pleasantryWords.contains($0) || $0.hasPrefix("thank") || $0.hasPrefix("congrat") }) else { return false }
        return w.filter { !pleasantryWords.contains($0) && !common.contains($0) && !$0.hasPrefix("thank") && $0.count >= 3 }.count <= 1
    }

    // MARK: The check

    /// Where an item is said: the line at its time or either neighbour, else (stricter) anywhere in the meeting.
    /// Returns the index of the line that says it best, whether that meant moving the time, or nil when no line does.
    static func find(_ text: String, near at: Double?, in lines: [Said], words: [Set<String>], task: Bool) -> (index: Int, moved: Bool)? {
        // Speaker labels in the item ("Person 3 said...") are who, not what: their words and numbers aren't in the
        // line's own text, so they don't count either way (D-1034).
        var bare = text
        for who in Set(lines.map(\.speaker)) {
            bare = bare.replacingOccurrences(of: "(?<![A-Za-z0-9])" + NSRegularExpression.escapedPattern(for: who) + "(?![A-Za-z0-9])",
                                             with: " ", options: .regularExpression)
        }
        let item = content(bare), nums = numbers(bare)
        guard !item.isEmpty else { return nil }
        func window(_ i: Int) -> ClosedRange<Int> { max(0, i - 1)...min(lines.count - 1, i + 1) }
        // Backed when every number is there, at least two meaning words are shared (one for a one-word item), and
        // they are a third of the item's (half when searching the whole meeting).
        func backs(_ i: Int, strict: Bool) -> Int? {
            let near = window(i).reduce(into: Set<String>()) { $0.formUnion(words[$1]) }
            guard nums.isSubset(of: near) else { return nil }
            // A to-do's "I'll" or "can you" is in the line itself or a short reply beside it ("Sure, I'll do that").
            if task, !window(i).contains(where: { j in (j == i || lines[j].text.split(separator: " ").count <= 15) && isCommitment(lines[j].text) }) { return nil }
            let shared = item.intersection(near).count
            let need = strict ? max(min(3, item.count), (item.count + 1) / 2) : max(min(2, item.count), (item.count + 2) / 3)
            return shared >= need ? shared : nil
        }
        guard !lines.isEmpty else { return nil }
        if let at {
            let i = lines.lastIndex(where: { $0.at <= at + 1 }) ?? 0
            if backs(i, strict: false) != nil {
                // The neighbour that shares the most words, the cited line on a tie.
                let best = window(i).max { a, b in
                    let x = item.intersection(words[a]).count, y = item.intersection(words[b]).count
                    return x != y ? x < y : b == i
                } ?? i
                return (best, best != i && lines[best].at != lines[i].at)
            }
        }
        var best: (i: Int, score: Int)?
        for i in lines.indices {
            guard let s = backs(i, strict: true), item.intersection(words[i]).count > 0 else { continue }
            if best == nil || s > best!.score { best = (i, s) }
        }
        return best.map { ($0.i, true) }
    }

    /// Every item checked against the transcript: kept at its time, moved to the line that says it, or left out.
    /// To-dos also need someone taking it on or asking for it, and are never thanks or goodbyes.
    public static func check(_ s: Summary, transcript: String) -> Checked {
        let lines = said(transcript), words = lines.map { content($0.text) }
        // A time past the end (ten minutes of slack for a last long paragraph) isn't a moment of this meeting.
        let end = (lines.last?.at ?? 0) + 600
        var out = Checked(summary: Summary(overview: s.overview))
        func real(_ at: Double?) -> Double? { at.flatMap { $0 <= end ? $0 : nil } }
        /// The time of the line that says it, or nil when none does.
        func locate(_ text: String, _ at: Double?, task: Bool) -> Double? {
            if real(at) == nil { out.uncited += 1 }
            guard let hit = find(text, near: real(at), in: lines, words: words, task: task) else { return nil }
            if hit.moved, real(at) != nil { out.moved += 1 }
            return lines[hit.index].at
        }
        for p in s.points {
            if let at = locate(p.text, p.at, task: false) { out.summary.points.append(Cited(p.text, at: at)) } else { out.dropped += 1 }
        }
        for d in s.decisions {
            if let at = locate(d.text, d.at, task: false) { out.summary.decisions.append(Cited(d.text, at: at)) } else { out.dropped += 1 }
        }
        for t in s.todos {
            if isPleasantry(t.task) { out.notTasks += 1; continue }
            if let at = locate(t.task, t.at, task: true) {
                out.summary.todos.append(ToDo(who: who(t.who, transcript: transcript), task: t.task, at: at))
            } else if find(t.task, near: real(t.at), in: lines, words: words, task: false) != nil {
                // Said, but nobody took it on or asked for it: not a to-do.
                out.notTasks += 1
            } else {
                out.dropped += 1
            }
        }
        return out
    }

    /// The pieces of a long meeting as one summary: items taken in turn from each piece, so the end of a meeting
    /// counts as much as its start, near-repeats left out, up to the caps, then in the order they were said.
    public static func merge(_ parts: [Summary], overview: String, points: Int = 10, decisions: Int = 6, todos: Int = 10) -> Summary {
        func inTurn<T>(_ lists: [[T]], cap: Int, text: (T) -> String, at: (T) -> Double?) -> [T] {
            var out: [T] = [], seen: [Set<String>] = []
            for i in 0..<(lists.map(\.count).max() ?? 0) {
                for l in lists where i < l.count && out.count < cap {
                    let c = content(text(l[i]))
                    let repeated = seen.contains { s in
                        let n = min(s.count, c.count)
                        return n > 0 && Double(s.intersection(c).count) >= 0.6 * Double(n)
                    }
                    if !repeated { out.append(l[i]); seen.append(c) }
                }
            }
            return out.sorted { (at($0) ?? .infinity) < (at($1) ?? .infinity) }
        }
        return Summary(overview: overview,
                       points: inTurn(parts.map(\.points), cap: points, text: \.text, at: \.at),
                       decisions: inTurn(parts.map(\.decisions), cap: decisions, text: \.text, at: \.at),
                       todos: inTurn(parts.map(\.todos), cap: todos, text: \.task, at: \.at))
    }

    // MARK: Markdown

    /// The summary as Markdown, under its label. Sections with nothing in them say so; items left out are counted.
    public static func summaryMarkdown(_ c: Checked, transcript: String, label: String = summaryLabel) -> String {
        let s = c.summary
        func time(_ at: Double?) -> String { at.map { " [\(clock($0))]" } ?? "" }
        func list(_ items: [String]) -> String { items.isEmpty ? "None heard.\n" : items.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        var out = "## Summary\n\n\(label)\n\n"
        out += "### Overview\n\n" + (s.overview.isEmpty ? "None heard." : s.overview) + "\n\n"
        out += "### Key points\n\n" + list(s.points.map { $0.text + time($0.at) }) + "\n"
        out += "### Decisions\n\n" + list(s.decisions.map { $0.text + time($0.at) }) + "\n"
        out += "### To-dos\n\n" + list(s.todos.map { "\($0.who): \($0.task)" + time($0.at) })
        let body = ([s.overview] + s.points.map(\.text) + s.decisions.map(\.text) + s.todos.map(\.task)).joined(separator: ". ")
        let odd = unknownNames(body, transcript: transcript)
        if !odd.isEmpty { out += "\nNot in the transcript, so check them: \(odd.joined(separator: ", ")).\n" }
        if c.dropped > 0 {
            out += "\n\(c.dropped) more \(c.dropped == 1 ? "item was" : "items were") left out because no line of the transcript says \(c.dropped == 1 ? "it" : "them").\n"
        }
        return out
    }

    // MARK: Reading a written summary

    /// A summary written as Markdown (`### Overview`, `### Key points`, `### Decisions`, `### To-dos`, items ending
    /// in `[mm:ss]`, to-dos as `Owner: task`), as Claude, ChatGPT or Gemini answer. Nil when it has none of those
    /// headings.
    public static func parse(written: String) -> Summary? {
        var s = Summary(), section = "", found = false, overview: [String] = []
        let bullet = try! NSRegularExpression(pattern: #"^(?:[-*•]|\d+[.)])\s+"#)
        for raw in written.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("```") { continue }
            let bare = line.trimmingCharacters(in: CharacterSet(charactersIn: "#*_: ")).lowercased()
            let known = ["overview", "key points", "points", "decisions", "to-dos", "todos", "to do", "action items"].contains(bare)
            let heading = line.hasPrefix("#") || known
            if heading {
                switch bare {
                case let b where b.hasPrefix("overview"): section = "overview"; found = true
                case let b where b.hasPrefix("key point") || b == "points": section = "points"; found = true
                case let b where b.hasPrefix("decision"): section = "decisions"; found = true
                case let b where b.hasPrefix("to-do") || b.hasPrefix("todo") || b.hasPrefix("action item"): section = "todos"; found = true
                default: section = ""
                }
                continue
            }
            let ns = line as NSString
            let m = bullet.firstMatch(in: line, range: NSRange(location: 0, length: ns.length))
            let item = (m.map { ns.substring(from: $0.range.length) } ?? line).replacingOccurrences(of: "**", with: "")
            if item.lowercased().hasPrefix("none heard") || item.lowercased() == "none" || item.lowercased() == "none." { continue }
            switch section {
            case "overview": overview.append(item)
            case "points" where m != nil: let c = cited(item); s.points.append(Cited(c.text, at: c.at))
            case "decisions" where m != nil: let c = cited(item); s.decisions.append(Cited(c.text, at: c.at))
            case "todos" where m != nil:
                let c = cited(item)
                if let colon = c.text.range(of: ": "), c.text[..<colon.lowerBound].split(separator: " ").count <= 4 {
                    s.todos.append(ToDo(who: String(c.text[..<colon.lowerBound]), task: String(c.text[colon.upperBound...]), at: c.at))
                } else {
                    s.todos.append(ToDo(who: "Not clear", task: c.text, at: c.at))
                }
            default: break
            }
        }
        s.overview = overview.joined(separator: " ")
        return found ? s : nil
    }

    // MARK: Where the summary goes

    /// The file in blocks: the header, then one block per `## ` heading.
    private static func blocks(_ file: String) -> [String] {
        var out: [String] = [], cur: [String] = []
        for line in file.components(separatedBy: "\n") {
            if line.hasPrefix("## "), !cur.isEmpty { out.append(cur.joined(separator: "\n")); cur = [] }
            cur.append(line)
        }
        if !cur.isEmpty { out.append(cur.joined(separator: "\n")) }
        return out
    }

    private static func isBetter(_ block: String) -> Bool {
        block.hasPrefix("## Summary\n") && ["(your account)", "(your download)", "(your choice)"]
            .contains { block.contains($0 + ". Check it against the transcript.") }
    }
    private static func isFree(_ block: String) -> Bool { (block.hasPrefix("## Summary\n") && !isBetter(block)) || block.hasPrefix(freeHeading + "\n") }

    private static func joined(_ blocks: [String]) -> String {
        blocks.map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n") + "\n"
    }

    private static func beforeTranscript(_ new: [String], in rest: [String]) -> [String] {
        var rest = rest
        let i = rest.firstIndex { $0.hasPrefix("## Transcript") } ?? rest.count
        rest.insert(contentsOf: new, at: i)
        return rest
    }

    /// The notes with Apple's summary above the transcript, in place of any earlier one. A better summary already
    /// there stays on top.
    public static func placing(_ section: String, in file: String) -> String {
        let all = blocks(file)
        let better = all.filter(isBetter)
        let rest = all.filter { !isFree($0) && !isBetter($0) }
        let free = better.isEmpty ? section : section.replacingOccurrences(of: "## Summary\n", with: freeHeading + "\n", options: .anchored)
        return joined(beforeTranscript(better + [free], in: rest))
    }

    /// The notes with a better summary on top as `## Summary`, and Apple's kept below it under its own heading.
    public static func placingBetter(_ section: String, in file: String) -> String {
        let all = blocks(file)
        let free = all.filter(isFree).map { $0.replacingOccurrences(of: "## Summary\n", with: freeHeading + "\n", options: .anchored) }
        let rest = all.filter { !isFree($0) && !isBetter($0) }
        return joined(beforeTranscript([section] + free, in: rest))
    }
}
