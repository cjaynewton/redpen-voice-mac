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
    /// text replaces them in place. `rest`: the early words stay as they are (you edited them, they are there more
    /// than once, or a swap was already tried), so only the words said after them go in. `whole`: none of the early
    /// words are there, the whole checked text goes in. Every case lands: nothing here holds the words back.
    public enum Landing: Equatable { case already, swap(NSRange), rest(String), whole }

    /// `typed`: the early words Voice confirmed in a box. `late`: one more insertion Voice attempted and couldn't
    /// confirm, in full or in part. `sameBox`: the cursor is in that same box and conversation. In any other box only
    /// an exact single span of the early words counts, so words there by coincidence never shorten the dictation.
    /// `canSwap`: false once the in-place swap has had its tries, or for a long talk, which is never retyped.
    public static func landing(typed: String, late: String = "", checked: String, actual: String,
                               sameBox: Bool = true, canSwap: Bool = true) -> Landing {
        func blank(_ t: String) -> Bool { t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let want = checked.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !want.isEmpty else { return .already }
        guard !blank(typed) || !blank(late) else { return .whole }
        let box = actual as NSString
        func holdsChecked(from range: NSRange) -> Bool {
            let tail = box.substring(from: range.location)
            let lead = tail.prefix(while: { $0.isWhitespace })
            let body = tail[lead.endIndex...]
            guard body.hasPrefix(want), exact(String(body.prefix(want.count)), want) else { return false }
            let next = body.dropFirst(want.count).first
            return !(want.last.map { $0.isLetter || $0.isNumber } == true && next.map { $0.isLetter || $0.isNumber } == true)
        }
        // The early words stay as they are: the cursor still needs only the words said after them.
        func afterEarly(_ early: String) -> Landing { wordsAfter(early: early, checked: checked).map { .rest($0) } ?? .already }
        if !blank(typed), var range = span(of: typed, in: actual) {
            // A late insertion lands right after the confirmed words. Count exactly as much of it as is there, and
            // only while the longer run is still one whole span: a part ending inside another word is left alone.
            if !late.isEmpty {
                let tail = Array(actual.utf16.dropFirst(NSMaxRange(range))), more = Array(late.utf16)
                var n = 0
                while n < tail.count, n < more.count, tail[n] == more[n] { n += 1 }
                while n > 0, Range(NSRange(location: range.location, length: range.length + n), in: actual) == nil { n -= 1 }
                if n > 0 {
                    let longer = NSRange(location: range.location, length: range.length + n)
                    if span(of: box.substring(with: longer), in: actual) == longer { range = longer }
                }
            }
            if holdsChecked(from: range) { return .already }
            return canSwap ? .swap(range) : afterEarly(box.substring(with: range))
        }
        if blank(typed), let range = span(of: late, in: actual) {
            if holdsChecked(from: range) { return .already }
            return canSwap ? .swap(range) : afterEarly(late)
        }
        guard sameBox else { return .whole }
        if span(of: want, in: actual) != nil { return .already }
        func token(_ w: Substring) -> String { w.lowercased().filter { $0.isLetter || $0.isNumber } }
        let earlyWords = (typed + late).split(whereSeparator: \.isWhitespace).map(token).filter { !$0.isEmpty }
        let boxWords = Set(actual.split(whereSeparator: \.isWhitespace).map(token))
        guard !earlyWords.isEmpty else { return .whole }
        let present = earlyWords.filter(boxWords.contains).count
        // Fewer than half of the early words are still there (an emptied box has none): every word goes in.
        guard present * 2 >= earlyWords.count else { return .whole }
        // Most are still there, edited or more than once. Only the words said after them go in, so nothing is there twice.
        return afterEarly(typed + late)
    }

    /// The words of `checked` said after the early words, for when those stay in the box as they are. The cut is the
    /// early word count, moved a few words either way to where the last early words are found in the checked text
    /// (the check can add or drop a word). nil: nothing was said after them.
    public static func wordsAfter(early: String, checked: String) -> String? {
        func token(_ w: Substring) -> String { w.lowercased().filter { $0.isLetter || $0.isNumber } }
        let earlyWords = early.split(whereSeparator: \.isWhitespace).map(token).filter { !$0.isEmpty }
        let said = checked.split(whereSeparator: \.isWhitespace)
        guard !said.isEmpty else { return nil }
        guard !earlyWords.isEmpty else { return checked.trimmingCharacters(in: .whitespacesAndNewlines) }
        let saidWords = said.map(token)
        let n = earlyWords.count
        var cut = min(n, said.count)
        let last = earlyWords[n - 1], before = n >= 2 ? earlyWords[n - 2] : nil
        search: for distance in 0...max(3, n / 10) {
            for offset in distance == 0 ? [0] : [distance, -distance] {
                let p = n + offset
                guard p >= 1, p <= said.count, saidWords[p - 1] == last else { continue }
                if let before, p >= 2, saidWords[p - 2] != before { continue }
                cut = p; break search
            }
        }
        guard cut < said.count else { return nil }
        return String(checked[said[cut].startIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// After a swap or an erase that wasn't confirmed: read the box once (D-1603). `landed`: it holds the text the
    /// edit was making. `retry`: it reads exactly as Voice left it before the edit, so the same edit runs once more.
    /// `finish`: the edit stopped partway, and this range holds what is left of it (the start of the old words, or
    /// the start of the new ones); the new words replace exactly that. `reread`: none of those. Nothing is typed on
    /// top blindly: the box is read again and `landing` decides from what is there.
    public enum SwapRecovery: Equatable { case landed, retry, finish(NSRange), reread }
    public static func afterFailedSwap(wanted: String?, asLeft: String?, actual: String?, range: NSRange? = nil,
                                       fixed: String? = nil, retried: Bool) -> SwapRecovery {
        guard let actual else { return .reread }
        if let wanted, BoxText.same(wanted, actual) { return .landed }
        if let asLeft, exact(asLeft, actual) { return retried ? .reread : .retry }
        if let asLeft, let range, let fixed,
           let left = unfinished(asLeft: asLeft, range: range, fixed: fixed, actual: actual) { return .finish(left) }
        return .reread
    }

    /// What is left of Voice's own swap of `range` in `asLeft` for `fixed` when it stopped partway. The text before
    /// and after the span must be literally as it was. Between them: the start of the old words (the erase stopped),
    /// or the start of the new words (the typing stopped), possibly nothing. Anything else is not Voice's edit.
    public static func unfinished(asLeft: String, range: NSRange, fixed: String, actual: String) -> NSRange? {
        let old = Array(asLeft.utf16), now = Array(actual.utf16)
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= old.count else { return nil }
        let head = old[..<range.location], tail = old[NSMaxRange(range)...]
        guard now.count >= head.count + tail.count, now.prefix(head.count).elementsEqual(head),
              now.suffix(tail.count).elementsEqual(tail) else { return nil }
        let middle = Array(now[head.count..<(now.count - tail.count)])
        let held = Array(old[range.location..<NSMaxRange(range)]), new = Array(fixed.utf16)
        guard (middle.count < held.count && held.starts(with: middle))
                || (middle.count < new.count && new.starts(with: middle)) else { return nil }
        let left = NSRange(location: range.location, length: middle.count)
        return Range(left, in: actual) == nil ? nil : left
    }

    /// A finishing attempt that stopped before any word arrived (your click into the box or into another one, a key
    /// that typed nothing, a cursor that moved) runs once more where the cursor now is. Only when no part of the
    /// words arrived and two reads of the first box show it exactly as it was before the attempt.
    public static func mayRetryAfterStop(before: String?, first: String?, settled: String?, partArrived: Bool,
                                         retried: Bool) -> Bool {
        guard !retried, !partArrived, let before, let first, let settled else { return false }
        return exact(before, first) && exact(before, settled)
    }

    /// Words you selected are never replaced (D-1603): the finished words go in at the end of the selection.
    public static func caretPastSelection(_ selection: NSRange) -> NSRange {
        NSRange(location: NSMaxRange(selection), length: 0)
    }

    /// A finishing attempt Voice couldn't confirm in time: one read showing exactly the text it was making counts.
    public static func landedOnRead(expected: String?, actual: String?) -> Bool {
        guard let expected, let actual else { return false }
        return BoxText.same(expected, actual)
    }
}
