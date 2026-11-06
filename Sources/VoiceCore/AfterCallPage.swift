import Foundation

/// After the call (D-1108, D-1126): one meeting's notes as the page the app shows when they are ready. What has to
/// happen comes first, most critical first, each with the line that says it; then a follow-up email written only from
/// the notes; then everything else, folded, for whoever wants it. Built from the notes file alone. Every word that
/// came from the meeting is escaped, the page loads nothing from anywhere, and sound plays through the app, so the
/// page itself never reads a file.
public enum AfterCallPage {
    /// What the page needs from a notes file.
    public struct Notes: Equatable {
        public var title: String
        public var started: String?
        public var length: String?
        public var summary: Meeting.Summary?
        /// Why there is no summary, when there isn't one.
        public var noSummary: String?
        public var lines: [Meeting.Said]
        /// Voices still called Person 2, Person 3: the page offers Name the voices.
        public var unnamed: Bool
        /// The others' names, for the email's greeting.
        public var people: [String]
        /// Who wrote the notes, as their label says ("Basic notes, made on this Mac by Apple's model."), and whether
        /// they're Apple's, so the page can offer better ones (D-1272).
        public var byline: String? = nil
        public var basic = false
    }

    /// The notes file read for the page. The summary on top (a better one when there is one) is the one shown.
    public static func read(_ file: String) -> Notes {
        let lines = file.components(separatedBy: "\n")
        let title = lines.first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? "Meeting notes"
        func field(_ k: String) -> String? {
            lines.first { $0.hasPrefix("- \(k): ") }.map { String($0.dropFirst(k.count + 4)).trimmingCharacters(in: .whitespaces) }
        }
        var summary: Meeting.Summary?, why: String?, byline: String?, basic = false
        if let r = file.range(of: "\n## Summary\n") ?? (file.hasPrefix("## Summary\n") ? file.range(of: "## Summary\n") : nil) {
            let rest = file[r.upperBound...]
            let block = rest.range(of: "\n## ").map { String(rest[..<$0.lowerBound]) } ?? String(rest)
            summary = Meeting.parse(written: block)
            basic = Meeting.isBasic(block)
            byline = block.components(separatedBy: "\n").first { $0.hasPrefix("*") && $0.hasSuffix("*") && $0.count > 2 }
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "*")).replacingOccurrences(of: " Check them against the transcript.", with: "")
                    .replacingOccurrences(of: " Check it against the transcript.", with: "") }
            if summary == nil, let n = block.range(of: "No summary was written.") {
                why = block[n.lowerBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        let said = Meeting.said(Meeting.transcript(inFile: file))
        let voices = Meeting.voices(inFile: file).map(\.rawValue)
        let unnamed = voices.contains { $0.range(of: "^Person [0-9]+$", options: .regularExpression) != nil }
        let people = voices.filter { $0 != Speaker.me.rawValue && $0.range(of: "^Person [0-9]+$", options: .regularExpression) == nil }
        return Notes(title: title, started: field("Started"), length: field("Length"), summary: summary, noSummary: why,
                     lines: said, unnamed: unnamed, people: people, byline: byline, basic: basic)
    }

    /// Text made safe to put in the page: nothing said in a meeting can become markup.
    public static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(c)
            }
        }
        return out
    }

    /// Who, as the page says it: Me is You.
    static func owner(_ who: String) -> String {
        if who == Speaker.me.rawValue { return "You" }
        return Meeting.isUnowned(who) ? "Nobody yet" : who
    }

    /// The line an item points at: the one said at its time, else the last one before it.
    /// The line an item points at: the one said at its time (by `speaker` when two share the second), else the last
    /// one before it.
    static func line(at: Double?, in lines: [Meeting.Said], speaker: String? = nil) -> Int? {
        guard let at, !lines.isEmpty else { return nil }
        return lines.firstIndex { $0.at == at && $0.speaker == speaker } ?? lines.firstIndex { $0.at == at }
            ?? lines.lastIndex { $0.at <= at } ?? 0
    }

    /// Where one line's sound is, for the app to play: which track, from when, until when.
    static func sound(_ i: Int, in lines: [Meeting.Said]) -> (track: String, from: Double, to: Double) {
        let l = lines[i]
        let next = lines[(i + 1)...].first { $0.at > l.at }?.at ?? l.at + 20
        // A line holds the paragraph that starts there; a few seconds at least, half a minute at most.
        let to = min(max(next, l.at + 3), l.at + 30)
        return (l.speaker == Speaker.others.rawValue ? "others" : "me", max(0, l.at - 0.3), to)
    }

    /// The button that plays the line an item came from and shows its words.
    static func source(_ i: Int?, lines: [Meeting.Said], audio: Bool) -> String {
        guard let i else { return "" }
        let s = sound(i, in: lines), l = lines[i]
        let label = audio ? "Hear it · \(Meeting.clock(l.at))" : "Show what was said · \(Meeting.clock(l.at))"
        return """
        <div class="act-src"><button class="src" data-line="\(i)" data-track="\(s.track)" data-from="\(s.from)" data-to="\(s.to)" data-audio="\(audio ? 1 : 0)">\(label)</button></div>
        <div class="quote" id="q\(i)-ID"><div class="qt">\(escape(l.text))</div><div class="qm"><span>\(escape(l.speaker == Speaker.me.rawValue ? "You" : l.speaker)), \(Meeting.clock(l.at))</span><span class="qbar"><i></i></span></div></div>
        """
    }

    /// The whole page. `fonts` is the @font-face CSS for Newsreader (data URLs), or empty for the system serif.
    public static func html(_ n: Notes, sender: String, audio: Bool, fonts: String = "") -> String {
        var quoteID = 0
        func src(_ at: Double?, speaker: String? = nil) -> String {
            quoteID += 1
            return source(line(at: at, in: n.lines, speaker: speaker), lines: n.lines, audio: audio).replacingOccurrences(of: "-ID\"", with: "-\(quoteID)\"")
        }
        var body = "<main class=\"note\">"
        body += "<h1>\(escape(n.title))</h1>"
        var meta: [String] = []
        if let s = n.started { meta.append("Started " + escape(s)) }
        if let l = n.length { meta.append(escape(l)) }
        if !n.people.isEmpty { meta.append("With " + escape(n.people.joined(separator: ", "))) }
        body += "<div class=\"meta\">\(meta.joined(separator: " · "))"
        if n.unnamed { body += " <button class=\"link\" data-act=\"names\">Name the voices</button>" }
        body += "</div>"
        // Who wrote these notes, said plainly, and for Apple's, the way to better ones (D-1272).
        if n.byline != nil || n.basic {
            body += "<div class=\"byline\">\(escape(n.byline ?? ""))"
            if n.basic { body += " <button class=\"link\" data-act=\"better\">Get better notes</button>" }
            body += "</div>"
        }

        guard let s = n.summary else {
            body += "<p class=\"settled\">\(escape(n.noSummary ?? "No summary was written for this meeting."))</p>"
            body += whole(n, cited: [], audio: audio, open: true)
            return page(body + "</main>", fonts: fonts)
        }
        if !s.overview.isEmpty { body += "<p class=\"settled\">\(escape(s.overview))</p>" }

        // What has to happen, most critical first.
        let todos = Meeting.ranked(s.todos)
        body += "<div class=\"sec-h\"><h2>What has to happen</h2><span>\(todos.count)</span></div>"
        body += "<div class=\"rule\">Critical means something else waits on it, or it's due by tomorrow.</div>"
        if todos.isEmpty {
            body += "<p class=\"empty\">Nobody took anything on in this meeting.</p>"
        } else {
            body += "<div class=\"acts\">"
            for (k, t) in todos.enumerated() {
                let u = Meeting.urgency(t)
                let when = t.when.map { escape($0.prefix(1).uppercased() + $0.dropFirst()) } ?? "No date said"
                body += "<div class=\"act\"><div class=\"act-n\">\(k + 1)</div><div>"
                body += "<div class=\"act-rank r-\(u)\">\(u.label)</div>"
                body += "<div class=\"act-what\">\(escape(t.task))</div>"
                body += "<div class=\"act-meta\"><strong>\(escape(owner(t.who)))</strong><span>·</span><span>\(when)</span></div>"
                // The date already shows when it's the reason; only a reason the date doesn't give is said.
                if let why = Meeting.why(t), !why.hasPrefix("Due ") { body += "<div class=\"act-why\">\(escape(why))</div>" }
                body += src(t.at, speaker: t.who) + "</div></div>"
            }
            body += "</div>"
        }

        // The follow-up email, only from what was said.
        let mail = Meeting.followUp(s, meeting: subjectName(n.title), sender: sender, people: n.people)
        body += "<div class=\"sec-h\"><h2>Follow-up email</h2></div>"
        body += "<div class=\"mail\"><div class=\"mail-h\"><div><span class=\"k\">To</span>\(escape(n.people.isEmpty ? "Everyone who was there" : n.people.joined(separator: ", ")))</div>"
        body += "<div><span class=\"k\">Subject</span>\(escape(mail.subject))</div></div>"
        body += "<pre class=\"mail-b\" id=\"mailbody\">\(escape(mail.body))</pre>"
        body += "<div class=\"mail-f\"><button class=\"btn\" data-act=\"copy\">Copy</button><button class=\"btn\" data-act=\"mail\">Open in Mail</button>"
        body += "<span class=\"mail-note\">Written only from what was said. Nothing sends by itself.</span></div></div>"
        // In attributes, where the page reads them back exactly; never inside a script, where markup isn't undone.
        body += "<div id=\"mail\" hidden data-subject=\"\(escape(mail.subject))\" data-body=\"\(escape(mail.body))\"></div>"

        // Go deeper.
        body += "<div class=\"sec-h\"><h2>Go deeper</h2></div><div class=\"deep\">"
        func fold(_ title: String, _ items: [Meeting.Cited], empty: String) {
            body += "<button class=\"deep-row\"><span>\(title)</span><span class=\"n\">\(items.count)</span><span class=\"chev\">Show</span></button><div class=\"deep-body\">"
            if items.isEmpty { body += "<p class=\"empty\">\(empty)</p>" }
            for c in items { body += "<div class=\"dli\"><div class=\"dli-t\">\(escape(c.text))</div>" + src(c.at) + "</div>" }
            body += "</div>"
        }
        fold("What was decided", s.decisions, empty: "Nothing was agreed out loud.")
        fold("Still open", s.open, empty: "Nothing was left open.")
        fold("Key points", s.points, empty: "None heard.")
        let cited = Set((s.todos.map(\.at) + s.decisions.map(\.at) + s.open.map(\.at) + s.points.map(\.at)).compactMap { $0 })
        body += whole(n, cited: cited, audio: audio, open: false)
        body += "</div>"
        body += "<div class=\"foot\"><button class=\"link\" data-act=\"file\">Open the notes file</button></div>"
        return page(body + "</main>", fonts: fonts)
    }

    /// "Meeting notes, Monday 2 November 2026" is "the meeting on Monday 2 November 2026" in a subject line.
    static func subjectName(_ title: String) -> String {
        if let r = title.range(of: "Meeting notes, ") { return "the meeting on " + title[r.upperBound...] }
        return title
    }

    /// The whole call, every line, the ones the notes point at lit.
    static func whole(_ n: Notes, cited: Set<Double>, audio: Bool, open: Bool) -> String {
        let lit = n.lines.filter { cited.contains($0.at) }.count
        var out = "<button class=\"deep-row\(open ? " on" : "")\"><span>The whole call</span><span class=\"n\">\(n.lines.count) lines\(cited.isEmpty ? "" : ", \(lit) lit")</span><span class=\"chev\">\(open ? "Hide" : "Show")</span></button>"
        out += "<div class=\"deep-body\(open ? " on" : "")\">"
        if n.lines.isEmpty { out += "<p class=\"empty\">Nothing was heard.</p>" }
        for (i, l) in n.lines.enumerated() {
            let s = sound(i, in: n.lines)
            out += "<div class=\"ln\(cited.contains(l.at) ? " lit" : "")\" data-line=\"\(i)\" data-track=\"\(s.track)\" data-from=\"\(s.from)\" data-to=\"\(s.to)\" data-audio=\"\(audio ? 1 : 0)\">"
            out += "<time>\(Meeting.clock(l.at))</time><div><div class=\"who\">\(escape(l.speaker == Speaker.me.rawValue ? "You" : l.speaker))</div><div class=\"txt\">\(escape(l.text))</div></div></div>"
        }
        return out + "</div>"
    }

    static func page(_ body: String, fonts: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; font-src data:; script-src 'unsafe-inline'">
        <style>\(fonts)\(css)</style></head><body>\(body)<script>\(script)</script></body></html>
        """
    }

    static let css = """
    :root { --win: #1c1c1c; --raise: #242424; --line: rgba(255,255,255,.10); --edge: rgba(255,255,255,.32); --text: #F6F4F1;
      --mid: rgba(246,244,241,.76); --dim: rgba(246,244,241,.52); --red: #FF5A4A; --amber: #E9B44C;
      --serif: "Newsreader", Georgia, serif; --sans: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif; }
    * { box-sizing: border-box; }
    html, body { margin: 0; background: var(--win); color: var(--text); font-family: var(--sans); -webkit-font-smoothing: antialiased; }
    button { font: inherit; color: inherit; background: none; border: 0; padding: 0; cursor: pointer; }
    .note { padding: 8px 34px 90px; max-width: 760px; margin: 0 auto; }
    h1 { font-family: var(--serif); font-weight: 500; font-size: 2rem; margin: 22px 0 6px; line-height: 1.12; }
    .meta { color: var(--dim); font-size: .86rem; }
    .link { color: var(--mid); text-decoration: underline; text-underline-offset: 3px; margin-left: 6px; }
    .link:hover { color: var(--text); }
    .settled { font-family: var(--serif); font-size: 1.28rem; line-height: 1.42; margin: 20px 0 6px; max-width: 34em; }
    .empty { color: var(--dim); font-size: .92rem; margin: 10px 0; }
    .byline { color: var(--dim); font-size: .82rem; margin-top: 6px; }
    .byline .link { margin-left: 4px; }
    .sec-h { display: flex; align-items: baseline; gap: 10px; margin: 36px 0 6px; }
    .sec-h h2 { font-size: 1.05rem; font-weight: 600; margin: 0; }
    .sec-h span { color: var(--dim); font-size: .9rem; }
    .rule { color: var(--dim); font-size: .82rem; margin-bottom: 8px; }
    .act { display: grid; grid-template-columns: 28px 1fr; gap: 0 12px; padding: 16px 0; border-top: 1px solid var(--line); }
    .act:first-child { border-top: 0; }
    .act-n { font-size: .9rem; color: var(--dim); font-variant-numeric: tabular-nums; padding-top: 22px; }
    .act-rank { font-size: .76rem; font-weight: 600; margin-bottom: 4px; color: var(--mid); }
    .act-rank.r-critical { color: var(--red); }
    .act-rank.r-undated { color: var(--dim); }
    .act-rank.r-unowned { color: var(--amber); }
    .act-what { font-family: var(--serif); font-size: 1.2rem; line-height: 1.35; }
    .act-meta { display: flex; gap: 6px; font-size: .88rem; color: var(--mid); margin-top: 5px; }
    .act-meta strong { color: var(--text); font-weight: 600; }
    .act-why { font-size: .86rem; color: var(--dim); margin-top: 4px; }
    .act-src { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 10px; }
    .src { display: inline-flex; align-items: center; gap: 6px; border: 1px solid var(--edge); border-radius: 3px; padding: 4px 9px; font-size: .8rem; color: var(--mid); font-variant-numeric: tabular-nums; }
    .src:hover, .src.on { color: var(--text); border-color: var(--text); }
    .quote { display: none; margin-top: 10px; padding: 12px 14px; background: var(--raise); border-radius: 3px; }
    .quote.on { display: block; }
    .quote .qt { font-family: var(--serif); font-size: 1.05rem; line-height: 1.45; }
    .quote .qm { font-size: .8rem; color: var(--dim); margin-top: 6px; display: flex; align-items: center; gap: 10px; }
    .qbar { flex: 1; height: 2px; background: var(--line); position: relative; max-width: 160px; }
    .qbar i { position: absolute; left: 0; top: 0; bottom: 0; width: 0; background: var(--text); }
    .mail { border: 1px solid var(--line); border-radius: 4px; background: #202020; }
    .mail-h { padding: 12px 16px; border-bottom: 1px solid var(--line); font-size: .9rem; display: grid; gap: 4px; }
    .mail-h .k { color: var(--dim); display: inline-block; width: 64px; }
    .mail-b { margin: 0; padding: 14px 16px; font-family: var(--sans); font-size: .92rem; line-height: 1.55; color: var(--mid); white-space: pre-wrap; user-select: text; }
    .mail-f { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; padding: 12px 16px; border-top: 1px solid var(--line); }
    .mail-note { color: var(--dim); font-size: .8rem; margin-left: 6px; }
    .btn { border: 1px solid var(--edge); border-radius: 3px; padding: 7px 14px; font-size: .88rem; }
    .btn:hover { background: rgba(255,255,255,.06); }
    .deep { border-top: 1px solid var(--line); }
    .deep-row { display: flex; width: 100%; align-items: baseline; gap: 10px; padding: 14px 0; border-bottom: 1px solid var(--line); text-align: left; font-size: .98rem; }
    .deep-row .n { color: var(--dim); font-size: .86rem; }
    .deep-row .chev { margin-left: auto; color: var(--dim); font-size: .84rem; }
    .deep-row:hover .chev { color: var(--text); }
    .deep-body { display: none; padding: 4px 0 10px; border-bottom: 1px solid var(--line); }
    .deep-body.on { display: block; }
    .dli { padding: 10px 0; }
    .dli-t { font-family: var(--serif); font-size: 1.06rem; margin-bottom: 6px; }
    .dli .act-src { margin-top: 4px; }
    .ln { display: grid; grid-template-columns: 52px 1fr; gap: 0 14px; padding: 8px 12px; margin: 0 -12px; border-radius: 3px; cursor: pointer; }
    .ln:hover { background: rgba(255,255,255,.035); }
    .ln time { color: var(--dim); font-size: .78rem; font-variant-numeric: tabular-nums; padding-top: 5px; }
    .ln .who { font-size: .78rem; color: var(--dim); margin-bottom: 2px; }
    .ln .txt { font-family: var(--serif); font-size: 1.06rem; line-height: 1.5; color: var(--mid); }
    .ln.lit { box-shadow: inset 2px 0 0 var(--red); }
    .ln.lit .txt { color: var(--text); }
    .ln.playing { background: rgba(255,255,255,.06); }
    .foot { margin-top: 28px; font-size: .86rem; }
    .foot .link { margin-left: 0; }
    """

    /// Clicks go to the app by message; the app plays the sound and calls `heard` with how far along it is.
    static let script = """
    const app = (m) => window.webkit && window.webkit.messageHandlers.redpen && window.webkit.messageHandlers.redpen.postMessage(m);
    let playing = null;
    function stopShown() {
      if (!playing) return;
      playing.classList.remove('on', 'playing');
      const q = playing.parentElement && playing.parentElement.nextElementSibling;
      if (q && q.classList.contains('quote')) { const b = q.querySelector('.qbar i'); if (b) b.style.width = '0'; }
      playing = null;
    }
    window.heard = (fraction) => {
      if (!playing) return;
      const q = playing.parentElement && playing.parentElement.nextElementSibling;
      if (q && q.classList.contains('quote')) { const b = q.querySelector('.qbar i'); if (b) b.style.width = Math.round(fraction * 100) + '%'; }
      if (fraction >= 1) { const p = playing; stopShown(); if (p.classList.contains('src')) p.classList.add('on'); }
    };
    function hear(el) {
      const again = playing === el;
      if (playing) { app({ act: 'stop' }); stopShown(); }
      if (again) return;
      playing = el;
      el.classList.add(el.classList.contains('ln') ? 'playing' : 'on');
      if (el.dataset.audio === '1') app({ act: 'hear', track: el.dataset.track, from: +el.dataset.from, to: +el.dataset.to });
    }
    document.addEventListener('click', (e) => {
      const src = e.target.closest('.src');
      if (src) {
        const q = src.parentElement.nextElementSibling;
        const open = q.classList.toggle('on');
        if (open) hear(src); else { if (playing === src) { app({ act: 'stop' }); stopShown(); } src.classList.remove('on'); }
        return;
      }
      const ln = e.target.closest('.ln');
      if (ln) { hear(ln); return; }
      const row = e.target.closest('.deep-row');
      if (row) {
        const body = row.nextElementSibling, on = body.classList.toggle('on');
        row.classList.toggle('on', on);
        row.querySelector('.chev').textContent = on ? 'Hide' : 'Show';
        return;
      }
      const act = e.target.closest('[data-act]');
      if (act) {
        const a = act.dataset.act;
        if (a === 'copy' || a === 'mail') {
          const m = document.getElementById('mail').dataset;
          app({ act: a, subject: m.subject, body: m.body });
          if (a === 'copy') { act.textContent = 'Copied'; setTimeout(() => act.textContent = 'Copy', 1600); }
        } else app({ act: a });
      }
    });
    """
}
