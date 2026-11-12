import Foundation

/// Literal ownership proof for a finishing edit. No AX calls or input events.
public enum FinishInBox {
    public static let mouseSettle = 0.150

    public static func exact(_ a: String, _ b: String) -> Bool { a.utf16.elementsEqual(b.utf16) }

    /// Exactly one complete span, including its recorded whitespace. Never expand into a neighbour's space.
    public static func span(of typed: String, in actual: String) -> NSRange? {
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let haystack = Array(actual.utf16), needle = Array(typed.utf16)
        guard haystack.count >= needle.count else { return nil }
        var found: NSRange?
        for i in 0...(haystack.count - needle.count) where haystack[i..<(i + needle.count)].elementsEqual(needle) {
            let range = NSRange(location: i, length: needle.count)
            guard let r = Range(range, in: actual),
                  (r.lowerBound == actual.endIndex || actual.indices.contains(r.lowerBound)),
                  (r.upperBound == actual.endIndex || actual.indices.contains(r.upperBound)) else { return nil }
            // A whole word must not turn into the middle of another word.
            if typed.first?.isLetter == true || typed.first?.isNumber == true,
               r.lowerBound > actual.startIndex {
                let previous = actual[actual.index(before: r.lowerBound)]
                if previous.isLetter || previous.isNumber { continue }
            }
            if typed.last?.isLetter == true || typed.last?.isNumber == true,
               r.upperBound < actual.endIndex {
                let next = actual[r.upperBound]
                if next.isLetter || next.isNumber { continue }
            }
            guard found == nil else { return nil }
            found = range
        }
        return found
    }

    /// A missing span permits only an exact checked-word prefix. Matching a last word alone is ambiguous.
    public static func remaining(typed: String, checked: String) -> String? {
        let before = typed.split(whereSeparator: \.isWhitespace)
        let after = checked.split(whereSeparator: \.isWhitespace)
        guard !before.isEmpty, after.count > before.count,
              zip(before, after).allSatisfy({ exact(String($0.0), String($0.1)) }) else { return nil }
        return String(checked[after[before.count].startIndex...])
    }

    public enum Ending: Equatable { case replace(NSRange), append(String), keep }
    public static func ending(typed: String, checked: String, actual: String, sent: Bool,
                              uncertain: Bool = false) -> Ending {
        guard !sent, !uncertain else { return .keep }
        if let range = span(of: typed, in: actual) { return .replace(range) }
        // If the literal span is present but repeated, never turn ambiguity into an append.
        guard actual.range(of: typed, options: .literal) == nil,
              let rest = remaining(typed: typed, checked: checked) else { return .keep }
        return .append(rest)
    }

    public static func mayResume(typed: String, expected: String?, actual: String?, cursor: NSRange?,
                                 focused: Bool, sent: Bool, userEdited: Bool, keyPressed: Bool,
                                 uncertain: Bool, longTalk: Bool, mouseAge: Double) -> Bool {
        guard focused, !sent, !userEdited, !keyPressed, !uncertain, !longTalk,
              mouseAge >= mouseSettle, let expected, let actual, exact(expected, actual),
              let cursor, cursor.length == 0 else { return false }
        if typed.isEmpty { return cursor.location >= 0 && cursor.location <= actual.utf16.count }
        guard let span = span(of: typed, in: actual) else { return false }
        return cursor.location == NSMaxRange(span)
    }

    /// Two readable, unchanged values and the original insertion point are required. Any partial arrival vetoes.
    public static func mayPaste(before: String?, first: String?, settled: String?, range: NSRange?,
                                currentRange: NSRange?, sameTarget: Bool, alreadyPasted: Bool = false) -> Bool {
        guard sameTarget, !alreadyPasted, let before, let first, let settled, let range,
              range.length == 0, range == currentRange else { return false }
        return exact(before, first) && exact(before, settled)
    }

    // MARK: Landing where the cursor is (D-1603, Nov 12 2026)

    /// How the finished words go into the text box the cursor is in when early words of this dictation may be there.
    /// `already`: the box holds the checked text. `swap`: Voice's early words sit there as one span, and the checked
    /// text replaces them in place. `rest`: you edited the early words, so only the words said after them go in.
    /// `whole`: none of the early words are there, the whole checked text goes in. `hold`: the same conversation
    /// reads empty after words went in (a send, D-998), or the early words can't be told apart: nothing is typed.
    public enum Landing: Equatable { case already, swap(NSRange), rest(String), whole, hold }

    /// `typed`: the early words Voice confirmed in a box. `late`: one more insertion Voice attempted and couldn't
    /// confirm, in full or in part. `sameBox`: the cursor is in that same box and conversation. In any other box only
    /// an exact single span of the early words counts, so words there by coincidence never shorten the dictation.
    public static func landing(typed: String, late: String = "", checked: String, actual: String,
                               sameBox: Bool = true) -> Landing {
        func blank(_ t: String) -> Bool { t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let want = checked.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !want.isEmpty else { return .already }
        let early = !blank(typed) || !blank(late)
        guard early else { return .whole }
        if sameBox, DictationEnding.looksSent(actual) { return .hold }
        let box = actual as NSString
        func holdsChecked(from range: NSRange) -> Bool {
            let tail = box.substring(from: range.location)
            let lead = tail.prefix(while: { $0.isWhitespace })
            let body = tail[lead.endIndex...]
            guard body.hasPrefix(want), exact(String(body.prefix(want.count)), want) else { return false }
            let next = body.dropFirst(want.count).first
            return !(want.last.map { $0.isLetter || $0.isNumber } == true && next.map { $0.isLetter || $0.isNumber } == true)
        }
        if !blank(typed), var range = span(of: typed, in: actual) {
            // A late insertion lands right after the confirmed words. Count exactly as much of it as is there.
            if !late.isEmpty {
                let tail = Array(actual.utf16.dropFirst(NSMaxRange(range))), more = Array(late.utf16)
                var n = 0
                while n < tail.count, n < more.count, tail[n] == more[n] { n += 1 }
                while n > 0, Range(NSRange(location: range.location, length: range.length + n), in: actual) == nil { n -= 1 }
                if n > 0 {
                    let longer = NSRange(location: range.location, length: range.length + n)
                    guard span(of: box.substring(with: longer), in: actual) == longer else { return .hold }
                    range = longer
                }
            }
            return holdsChecked(from: range) ? .already : .swap(range)
        }
        if blank(typed), let range = span(of: late, in: actual) {
            return holdsChecked(from: range) ? .already : .swap(range)
        }
        guard sameBox else { return .whole }
        if span(of: want, in: actual) != nil { return .already }
        // The early words are there more than once, or inside another word: no safe place to swap.
        if !blank(typed), actual.range(of: typed, options: .literal) != nil { return .hold }
        func token(_ w: Substring) -> String { w.lowercased().filter { $0.isLetter || $0.isNumber } }
        let earlyWords = (typed + late).split(whereSeparator: \.isWhitespace).map(token).filter { !$0.isEmpty }
        let boxWords = Set(actual.split(whereSeparator: \.isWhitespace).map(token))
        guard !earlyWords.isEmpty else { return .whole }
        let present = earlyWords.filter(boxWords.contains).count
        // Fewer than half of the early words are still there: you took them out, so every word goes in.
        guard present * 2 >= earlyWords.count else { return .whole }
        // Most are still there, edited. Only the words said after them go in, so nothing is there twice.
        let said = checked.split(whereSeparator: \.isWhitespace)
        let saidWords = said.map(token)
        let n = earlyWords.count
        var cut = min(n, said.count)
        let last = earlyWords[n - 1], before = n >= 2 ? earlyWords[n - 2] : nil
        for offset in [0, 1, -1, 2, -2, 3, -3] {
            let p = n + offset
            guard p >= 1, p <= said.count, saidWords[p - 1] == last else { continue }
            if let before, p >= 2, saidWords[p - 2] != before { continue }
            cut = p; break
        }
        guard cut < said.count else { return .already }
        return .rest(String(checked[said[cut].startIndex...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// After a swap or an erase that wasn't confirmed: read the box once. It holds the text the edit was making: it
    /// landed. It reads exactly as Voice left it before the edit: try once more. Anything else: nothing is typed on top.
    public enum SwapRecovery: Equatable { case landed, retry, hold }
    public static func afterFailedSwap(wanted: String?, asLeft: String?, actual: String?, retried: Bool) -> SwapRecovery {
        guard let actual else { return .hold }
        if let wanted, BoxText.same(wanted, actual) { return .landed }
        if !retried, let asLeft, exact(asLeft, actual) { return .retry }
        return .hold
    }

    /// A finishing attempt that stopped because you clicked (into the box again, or into another one) may run once
    /// more where the cursor now is. Only when no key was pressed, no part of the words arrived, and two reads of the
    /// first box show it exactly as it was before the attempt.
    public static func mayRetryAfterClick(before: String?, first: String?, settled: String?, keysQuiet: Bool,
                                          partArrived: Bool, clickedOrMoved: Bool, retried: Bool) -> Bool {
        guard !retried, keysQuiet, !partArrived, clickedOrMoved, let before, let first, let settled else { return false }
        return exact(before, first) && exact(before, settled)
    }

    /// A finishing attempt Voice couldn't confirm in time: one read showing exactly the text it was making counts.
    public static func landedOnRead(expected: String?, actual: String?) -> Bool {
        guard let expected, let actual else { return false }
        return BoxText.same(expected, actual)
    }
}
