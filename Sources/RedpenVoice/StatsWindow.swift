import AppKit
import SwiftUI
import VoiceCore

/// Your numbers (D-837): this week, the last 30 days and all time, words a day and speed over time. Opened from the
/// menu. Numbers only, from stats.json; the history's keep choice never changes them.
@MainActor
final class StatsWindow {
    private var window: NSWindow?
    let model: StatsModel
    init(model: StatsModel) { self.model = model }

    func show() {
        model.reload()
        if window == nil {
            Ink.registerFonts()
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: StatsView.width, height: 650), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Redpen Voice Stats"
            w.contentView = NSHostingView(rootView: StatsView(model: model).buttonBorderShape(.roundedRectangle(radius: 4)))
            w.contentMinSize = NSSize(width: StatsView.width, height: 460)
            w.center(); w.isReleasedWhenClosed = false
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class StatsModel: ObservableObject {
    @Published var days: [DayStats] = []
    /// Your typing speed from Settings, in words a minute.
    @Published var typing: Double
    var now: () -> Date = { Date() }
    /// Where the counts come from: the app's store, or sample numbers for a picture.
    var load: () -> [DayStats]
    var onReset: () -> Void = {}
    var openSettings: () -> Void = {}
    /// Words landed (D-1034): what the log says about every word going in, read each time the window is drawn again.
    @Published var landed: WordsLanded.Read?
    var loadLanded: () -> WordsLanded.Read? = { nil }

    private var watches: [NSObjectProtocol] = []

    init(typing: Double, load: @escaping () -> [DayStats]) {
        self.typing = typing; self.load = load; days = load()
        // A new day, a new time zone or waking up moves "today" and "this week": drawn again even with no dictation.
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in Task { @MainActor in self?.reload() } }
        watches = [NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main, using: refresh),
                   NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main, using: refresh),
                   NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: refresh)]
    }

    func reload() { days = load(); landed = loadLanded() }
    func reset() { onReset(); reload() }

    /// Made-up heavy daily use from August 16, 2026 through today, shared by all pictures that show stats.
    /// Weekends are lighter, a few working days are big, and speed improves unevenly. Never anyone's real counts.
    static func sample(now: Date, calendar: Calendar = .current) -> [DayStats] {
        var seed: UInt64 = 0x5EED
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(from: DateComponents(year: 2026, month: 8, day: 16)), start <= today else { return [] }
        let count = (calendar.dateComponents([.day], from: start, to: today).day ?? 0) + 1
        let weeklyWPM = [135.0, 141, 140, 146, 148, 147, 153, 154, 160, 158, 165]
        var out: [DayStats] = []
        for day in 0..<count {
            guard let d = calendar.date(byAdding: .day, value: day, to: start) else { continue }
            let weekend = calendar.isDateInWeekend(d)
            let words: Int
            if weekend {
                words = rnd() < 0.30 ? 0 : Int(350 + rnd() * 1_651)
            } else {
                words = rnd() < 0.08 ? Int(8_000 + rnd() * 1_001) : Int(3_500 + rnd() * 3_001)
            }
            let n = words == 0 ? 0 : Int((weekend ? 8 : 80) + rnd() * (weekend ? 28 : 51))
            let wpm = weeklyWPM[min(day / 7, weeklyWPM.count - 1)] - 4 + rnd() * 8
            let secs = Double(words) / wpm * 60
            out.append(DayStats(day: StatsStore.key(d, calendar: calendar), engine: "whisper", words: words, seconds: secs, dictations: n))
        }
        return out
    }

    /// Made-up log lines in the real formats for pictures (D-1034): a week of dictations, a few kept and one lost.
    /// Never anyone's real log.
    static func sampleLanded(now: Date, calendar: Calendar = .current) -> WordsLanded.Read {
        let iso = ISO8601DateFormatter()
        var lines: [String] = []
        let today = calendar.startOfDay(for: now)
        for back in (0..<7).reversed() {
            guard let day = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            let n = calendar.isDateInWeekend(day) ? 9 : 46 - back * 2
            // Today's run ends now, the build started just before it; earlier days start at 9.
            let start = back == 0 ? max(day, now.addingTimeInterval(-Double(n) * 60)) : day.addingTimeInterval(9 * 3600)
            let step = back == 0 ? (now.timeIntervalSince(start) / Double(n + 1)) : 300
            if back == 0 { lines.append(iso.string(from: start) + " launched 0.13.0 (15), built sample") }
            for i in 0..<n {
                let t = start.addingTimeInterval(Double(i + 1) * step)
                if t > now { break }
                let s = iso.string(from: t)
                lines.append("\(s) audio: 63344 frames (4.0s), peak 0.344")
                if i % 23 == 7 { lines.append("\(s) insert: the box you started in was sent after Voice typed into it, nothing typed again, kept for paste") }
                if i == 30, back == 3 { lines.append("\(s) engine: the ending failed, 4 pieces kept") }
                lines.append("\(s) dictation 6s, 18 words, write 200ms, engine 1500ms, key up to done 2100ms, into Sample, inserted \(i % 23 != 7)")
            }
        }
        return WordsLanded.read(lines.joined(separator: "\n"))
    }
}

struct StatsView: View {
    static let width: CGFloat = 640
    @ObservedObject var model: StatsModel
    @State private var confirmReset = false
    @State private var section = "activity"
    @State private var period = "7 days"
    @State private var metric = "Words"
    @State private var showCounting = false
    @State private var appearanceRevision = 0

    init(model: StatsModel, initialSection: String = "activity") {
        self.model = model
        _section = State(initialValue: initialSection)
    }

    private var total: Score { Stats.score(model.days, typing: model.typing) }
    private var score: Score {
        switch period {
        case "This week": return Stats.thisWeek(model.days, now: model.now(), typing: model.typing)
        case "30 days": return Stats.lastDays(30, model.days, now: model.now(), typing: model.typing)
        case "All time": return total
        default: return Stats.lastDays(7, model.days, now: model.now(), typing: model.typing)
        }
    }
    private var points: [(date: Date, score: Score)] {
        let n: Int
        switch period {
        case "This week":
            let start = Calendar.current.dateInterval(of: .weekOfYear, for: model.now())?.start ?? model.now()
            n = max(1, (Calendar.current.dateComponents([.day], from: start, to: model.now()).day ?? 0) + 1)
        case "30 days": n = 30
        case "All time": n = 30
        default: n = 7
        }
        return Stats.daily(model.days, n: n, now: model.now())
    }

    var body: some View {
        let _ = appearanceRevision
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VoiceMark().foregroundStyle(Ink.red)
                Text(section == "fun" ? "Fun facts" : section == "delivery" ? "Words landed" : "Your words")
                    .font(.system(size: 23, weight: .semibold))
                Spacer()
                if section != "activity" {
                    Button("Back to Stats") { section = "activity" }.buttonStyle(.plain).foregroundStyle(Ink.mid)
                }
            }.foregroundStyle(Ink.text).padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if section == "fun" { funFacts }
                    else if section == "delivery" {
                        if let r = model.landed { landedSection(r) }
                        else { Text("Nothing in the log yet.").foregroundStyle(Ink.mid) }
                    } else { activity }
                    footer
                }.padding(.horizontal, 28).padding(.bottom, 24)
            }
        }
        .frame(minWidth: Self.width, minHeight: 460)
        .background(Ink.paper)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("VoiceAppearanceChanged"))) { _ in appearanceRevision += 1 }
        .alert("Reset your stats?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { model.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every count goes back to zero and starts again with your next dictation. Your history isn't touched.")
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("\(score.count.formatted()) dictations").font(.system(size: 13)).foregroundStyle(Ink.mid)
                Spacer()
                Picker("Time range", selection: $period) {
                    ForEach(["7 days", "This week", "30 days", "All time"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 306)
            }
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(score.words.formatted()).font(.system(size: 49, weight: .medium, design: .rounded)).monospacedDigit()
                    Text("words spoken").font(.system(size: 14)).foregroundStyle(Ink.mid)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Score.savedText(score.minutesSaved)).font(.system(size: 27, weight: .medium)).monospacedDigit()
                    Text("of typing saved").font(.system(size: 13)).foregroundStyle(Ink.mid)
                    Text(score.seconds >= Stats.minSecondsForSpeed ? "\(score.wordsPerMinute) words a minute" : "Pace appears after 20 seconds")
                        .font(.system(size: 12)).foregroundStyle(Ink.mid).padding(.top, 7)
                }.padding(.top, 10)
            }.foregroundStyle(Ink.text)
            if model.days.isEmpty {
                Text("Your first dictation starts the count.").font(.system(size: 14)).foregroundStyle(Ink.mid).padding(.vertical, 24)
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text(metric == "Words" ? (period == "All time" ? "Words a day · last 30 days" : "Words a day") : "Speaking pace")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.text)
                        Spacer()
                        Picker("Chart", selection: $metric) {
                            Text("Words").tag("Words")
                            Text("Pace").tag("Pace")
                        }.pickerStyle(.segmented).labelsHidden().frame(width: 134)
                    }
                    if metric == "Words" {
                        WordsChart(points: points).frame(height: 160)
                        if let today = points.last {
                            Text("\(shortDate(today.date)) · \(today.score.words.formatted()) words").font(.system(size: 12)).foregroundStyle(Ink.red)
                        }
                    } else { speedSection }
                }
                Button { section = "fun" } label: {
                    HStack(spacing: 16) {
                        Image(systemName: "book.closed").font(.system(size: 24)).foregroundStyle(Ink.red)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your words add up").font(.system(size: 14, weight: .medium)).foregroundStyle(Ink.text)
                            Text(StatsFunFacts.bookLines(words: total.words).first ?? "See your all-time totals in a different way.")
                                .font(.system(size: 12)).foregroundStyle(Ink.mid).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right").foregroundStyle(Ink.mid)
                    }.padding(16).contentShape(Rectangle())
                }.buttonStyle(.plain).background(Ink.raised, in: RoundedRectangle(cornerRadius: 3))
            }
        }
    }

    private var speedSection: some View {
        let sp = period == "All time" ? Stats.speed(model.days, now: model.now()) :
            (weekly: false, points: points.map { (date: $0.date, wpm: $0.score.seconds >= Stats.minSecondsForSpeed ? $0.score.wordsPerMinute : nil) })
        return VStack(alignment: .leading, spacing: 14) {
            if sp.points.contains(where: { $0.wpm != nil }) {
                SpeedChart(points: sp.points, weekly: sp.weekly).frame(height: 160)
            } else {
                Text("Talk for 20 seconds in a day to see its pace.").font(.system(size: 13)).foregroundStyle(Ink.mid).frame(height: 160)
            }
            Text("\(sp.weekly ? "Weeks" : "Days") under 20 seconds are skipped. \(period == "All time" ? "Up to 26 weeks shown." : "")")
                .font(.system(size: 12)).foregroundStyle(Ink.mid)
        }
    }

    private var funFacts: some View {
        let book = StatsFunFacts.books.last(where: { $0.words <= total.words }) ?? StatsFunFacts.books[0]
        let ratio = Double(total.words) / Double(book.words)
        let amount = ratio < 0.01 ? "<1%" : ratio < 1 ? "\(Int((ratio * 100).rounded()))%" : "\((ratio * 10).rounded() / 10)×"
        return VStack(alignment: .leading, spacing: 26) {
            Text("From \(total.words.formatted()) words, all time.").font(.system(size: 13)).foregroundStyle(Ink.mid)
            HStack(alignment: .center, spacing: 32) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("REDPEN\nREADING ROOM").font(.system(size: 10, weight: .bold)).tracking(1)
                    Spacer()
                    Text(book.title).font(.system(size: 22, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Rectangle().frame(height: 2)
                    Text("A book's worth of words").font(.system(size: 11))
                }.foregroundStyle(Ink.text).padding(20).frame(width: 172, height: 226)
                    .background(Ink.subtle).overlay(alignment: .leading) { Rectangle().fill(Ink.red).frame(width: 6) }
                    .overlay(Rectangle().strokeBorder(Ink.border.opacity(0.5)))
                VStack(alignment: .leading, spacing: 10) {
                    Text(total.words == 0 ? "0" : amount).font(.system(size: 56, weight: .medium)).monospacedDigit().foregroundStyle(Ink.text)
                    Text(ratio < 1 ? "of \(book.title)'s word count" : "the word count of \(book.title)").font(.system(size: 17, weight: .medium)).foregroundStyle(Ink.text)
                    Text("An approximate comparison. \(total.words.formatted()) spoken words against this edition's \(book.words.formatted()).")
                        .font(.system(size: 13)).foregroundStyle(Ink.mid).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.vertical, 6)
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(Score.savedText(total.minutesSaved)).font(.system(size: 25, weight: .medium)).foregroundStyle(Ink.text)
                    Text("of typing saved, all time").font(.system(size: 13)).foregroundStyle(Ink.mid)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    Text(total.count.formatted()).font(.system(size: 25, weight: .medium)).foregroundStyle(Ink.text)
                    Text("dictations, all time").font(.system(size: 13)).foregroundStyle(Ink.mid)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(StatsFunFacts.lines(model.days).dropFirst(StatsFunFacts.bookLines(words: total.words).count)), id: \.self) { fact in
                Text(fact).font(.system(size: 13)).foregroundStyle(Ink.mid).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func heading(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Ink.text)
            Text(detail).font(.system(size: 13)).foregroundStyle(Ink.mid).fixedSize(horizontal: false, vertical: true)
        }.padding(.bottom, 16)
    }

    private func landedSection(_ r: WordsLanded.Read) -> some View {
        let now = model.now(), cal = Calendar.current
        let week = cal.date(byAdding: .day, value: -6, to: cal.startOfDay(for: now)) ?? now
        let lines = WordsLanded.table(r, now: now, calendar: cal)
        return VStack(alignment: .leading, spacing: 0) {
            heading("Words landed", "Did every word go in? Landed in full means they went in and Voice found nothing wrong. Kept means they wait on Paste last (⌃⌥V) and in History. Lost means some never came out of the engine.")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                    Text(l).foregroundStyle(i == 0 ? Ink.text : Ink.mid)
                }
            }.font(.system(size: 13)).monospacedDigit()
            VStack(alignment: .leading, spacing: 4) {
                if let s = WordsLanded.sinceLine(r, calendar: cal) { Text(s).foregroundStyle(Ink.text) }
                if let why = WordsLanded.reasonsLine(r, from: week) { Text(why).foregroundStyle(Ink.mid) }
                Text(r.first.map { "From the log on this Mac, which goes back to \(WordsLanded.stamp($0, calendar: cal)). Voice starts a new log when it passes 1 MB." }
                     ?? "Nothing in the log yet.").foregroundStyle(Ink.dim)
            }
            .font(.system(size: 12.5)).monospacedDigit().fixedSize(horizontal: false, vertical: true).padding(.top, 10)
        }
    }


    private var footer: some View {
        VStack(alignment: .leading, spacing: 13) {
            Divider().overlay(Ink.line)
            HStack {
                Button("How we count") { showCounting.toggle() }
                Spacer()
                if section != "delivery" { Button("Words landed") { section = "delivery" } }
            }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Ink.mid)
            if showCounting {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Time saved compares typing at \(Int(model.typing)) words a minute with the time you spent talking. It is an estimate.")
                    Button("Change typing speed…") { model.openSettings() }.buttonStyle(.plain).foregroundStyle(Ink.text)
                    Text("Counts stay on this Mac. Deleting history does not change them. Book comparisons use approximate word counts from Standard Ebooks editions.")
                    Button("Reset stats…") { confirmReset = true }.buttonStyle(.plain).foregroundStyle(Ink.text).disabled(model.days.isEmpty)
                }.font(.system(size: 13)).foregroundStyle(Ink.mid).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A round top for a chart's scale: 1, 2, 2.5 or 5 times a power of ten, at or above the value.
private func niceCeil(_ v: Double) -> Double {
    guard v > 0 else { return 1 }
    let p = pow(10, floor(log10(v)))
    for m in [1, 2, 2.5, 5, 10] where m * p >= v { return m * p }
    return 10 * p
}

private func shortDate(_ d: Date) -> String { d.formatted(.dateTime.month(.abbreviated).day()) }

/// Words a day as thin bars on one baseline, a faint top and middle rule with their values, and the first and last
/// day named underneath. Hover a bar for its day and count.
private struct WordsChart: View {
    let points: [(date: Date, score: Score)]
    private let axis: CGFloat = 40, under: CGFloat = 18

    var body: some View {
        let top = niceCeil(Double(points.map(\.score.words).max() ?? 0))
        GeometryReader { g in
            let plotW = g.size.width - axis, plotH = g.size.height - under
            let step = plotW / CGFloat(max(points.count, 1))
            ZStack(alignment: .topLeading) {
                ForEach([1.0, 0.5], id: \.self) { f in
                    Rectangle().fill(Ink.line).frame(width: plotW, height: 1)
                        .offset(x: axis, y: plotH * (1 - f))
                    Text(Int(top * f).formatted()).font(.system(size: 11)).monospacedDigit().foregroundStyle(Ink.dim)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: axis - 8, alignment: .trailing)
                        .offset(y: plotH * (1 - f) - 7)
                }
                Rectangle().fill(Ink.mid.opacity(0.5)).frame(width: plotW, height: 1).offset(x: axis, y: plotH)
                ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                    let h = top > 0 ? max(0, CGFloat(Double(p.score.words) / top) * plotH) : 0
                    Rectangle().fill(i == points.count - 1 ? Ink.red : Ink.mid.opacity(0.48))
                        .frame(width: max(1, step - 3), height: p.score.words > 0 ? max(2, h) : 0)
                        .offset(x: axis + CGFloat(i) * step + 1.5, y: plotH - (p.score.words > 0 ? max(2, h) : 0))
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .frame(width: step, height: plotH)
                        .offset(x: axis + CGFloat(i) * step, y: 0)
                        .help("\(shortDate(p.date)): \(p.score.words.formatted()) words, \(p.score.count) \(p.score.count == 1 ? "dictation" : "dictations")")
                }
                Text(points.first.map { shortDate($0.date) } ?? "").font(.system(size: 11)).foregroundStyle(Ink.dim)
                    .offset(x: axis, y: plotH + 5)
                Text("Today").font(.system(size: 11)).foregroundStyle(Ink.dim)
                    .frame(width: plotW, alignment: .trailing)
                    .offset(x: axis, y: plotH + 5)
            }
        }
    }
}

/// Speaking pace starts at zero so changes are not exaggerated. Hover a dot for its day or week.
private struct SpeedChart: View {
    let points: [(date: Date, wpm: Int?)]
    let weekly: Bool
    private let axis: CGFloat = 40, under: CGFloat = 18

    var body: some View {
        let vals = points.compactMap(\.wpm)
        let lo = 0.0, hi = niceCeil(Double(vals.max() ?? 0))
        GeometryReader { g in
            let plotW = g.size.width - axis, plotH = g.size.height - under
            let step = plotW / CGFloat(max(points.count, 1))
            let xy: (Int, Int) -> CGPoint = { i, v in
                CGPoint(x: axis + (CGFloat(i) + 0.5) * step, y: plotH * (1 - CGFloat((Double(v) - lo) / max(hi - lo, 1))))
            }
            let drawn = points.enumerated().compactMap { i, p in p.wpm.map { (i, $0) } }
            ZStack(alignment: .topLeading) {
                ForEach([hi, lo], id: \.self) { v in
                    Rectangle().fill(v == lo ? Ink.mid.opacity(0.5) : Ink.line).frame(width: plotW, height: 1)
                        .offset(x: axis, y: v == lo ? plotH : 0)
                    Text("\(Int(v))").font(.system(size: 11)).monospacedDigit().foregroundStyle(Ink.dim)
                        .frame(width: axis - 8, alignment: .trailing)
                        .offset(y: (v == lo ? plotH : 0) - 7)
                }
                Path { p in
                    for (n, d) in drawn.enumerated() { let pt = xy(d.0, d.1); if n == 0 { p.move(to: pt) } else { p.addLine(to: pt) } }
                }.stroke(Ink.red, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                ForEach(drawn, id: \.0) { i, v in
                    let pt = xy(i, v)
                    Circle().fill(Ink.red).frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Ink.paper, lineWidth: 2))
                        .frame(width: max(step, 12), height: 16).contentShape(Rectangle())
                        .help("\(weekly ? "Week of " : "")\(shortDate(points[i].date)): \(v) words a minute")
                        .position(pt)
                }
                Text(points.first.map { (weekly ? "Week of " : "") + shortDate($0.date) } ?? "").font(.system(size: 11)).foregroundStyle(Ink.dim)
                    .offset(x: axis, y: plotH + 5)
                Text(weekly ? "This week" : "Today").font(.system(size: 11)).foregroundStyle(Ink.dim)
                    .frame(width: plotW, alignment: .trailing)
                    .offset(x: axis, y: plotH + 5)
            }
        }
    }
}
