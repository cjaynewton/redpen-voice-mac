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
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: StatsView.width, height: 760), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Redpen Voice Stats"
            w.contentView = NSHostingView(rootView: StatsView(model: model).buttonBorderShape(.roundedRectangle(radius: 4)))
            w.contentMinSize = NSSize(width: StatsView.width, height: 420)
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

    private var watches: [NSObjectProtocol] = []

    init(typing: Double, load: @escaping () -> [DayStats]) {
        self.typing = typing; self.load = load; days = load()
        // A new day, a new time zone or waking up moves "today" and "this week": drawn again even with no dictation.
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in Task { @MainActor in self?.reload() } }
        watches = [NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main, using: refresh),
                   NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main, using: refresh),
                   NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: refresh)]
    }

    func reload() { days = load() }
    func reset() { onReset(); reload() }

    /// Seventy days of made-up numbers for the pictures: busier on weekdays, a few days off, speed creeping up. Never
    /// anyone's real counts.
    static func sample(now: Date, calendar: Calendar = .current) -> [DayStats] {
        var seed: UInt64 = 0x5EED
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 33) / Double(1 << 31) }
        let today = calendar.startOfDay(for: now)
        var out: [DayStats] = []
        for back in (0..<70).reversed() {
            guard let d = calendar.date(byAdding: .day, value: -back, to: today) else { continue }
            let weekend = calendar.isDateInWeekend(d)
            if rnd() < (weekend ? 0.55 : 0.08) { continue }
            let n = Int((weekend ? 4 : 14) + rnd() * (weekend ? 6 : 22))
            let wpm = 112 + Double(70 - back) * 0.32 + rnd() * 14
            let secs = Double(n) * (14 + rnd() * 22)
            out.append(DayStats(day: StatsStore.key(d, calendar: calendar), engine: "whisper", words: Int(secs / 60 * wpm), seconds: secs, dictations: n))
        }
        return out
    }
}

struct StatsView: View {
    static let width: CGFloat = 600
    @ObservedObject var model: StatsModel
    @State private var confirmReset = false

    private var typing: Int { Int(model.typing) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Stats").font(Ink.serif(26)).foregroundStyle(Ink.text)
                HStack(spacing: 4) {
                    Text("Time saved is compared with typing at \(typing) words a minute.").foregroundStyle(Ink.dim)
                    Button("Change") { model.openSettings() }.buttonStyle(.plain).foregroundStyle(Ink.red)
                }.font(.system(size: 12.5)).padding(.top, 2)

                if model.days.isEmpty {
                    Text("Nothing counted yet. Your numbers show up here after your first dictation.")
                        .font(.system(size: 13)).foregroundStyle(Ink.dim).padding(.top, 28)
                } else {
                    totals.padding(.top, 26)
                    heading("Words a day", "The last 30 days.")
                    WordsChart(points: Stats.daily(model.days, now: model.now()))
                        .frame(height: 132)
                    speedSection
                }
                footer
            }
            .padding(.horizontal, 32).padding(.top, 22).padding(.bottom, 22)
        }
        .frame(minWidth: Self.width, minHeight: 420)
        .background(Ink.paper)
        .alert("Reset your stats?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { model.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every count goes back to zero and starts again with your next dictation. Your history isn't touched.")
        }
    }

    // MARK: Totals

    private var totals: some View {
        let now = model.now(), t = model.typing
        return HStack(alignment: .top, spacing: 0) {
            column("This week", Stats.thisWeek(model.days, now: now, typing: t))
            column("Last 30 days", Stats.lastDays(30, model.days, now: now, typing: t))
            column("All time", Stats.score(model.days, typing: t))
        }
    }

    private func column(_ title: String, _ s: Score) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).kerning(0.6).foregroundStyle(Ink.dim)
            Text(s.words.formatted()).font(Ink.serif(30)).foregroundStyle(Ink.text).monospacedDigit().padding(.top, 6)
            Text(s.words == 1 ? "word" : "words").font(.system(size: 12.5)).foregroundStyle(Ink.dim)
            VStack(alignment: .leading, spacing: 4) {
                line(Score.savedText(s.minutesSaved), "saved")
                line(s.wordsPerMinute > 0 ? "\(s.wordsPerMinute)" : "–", "words a minute")
                line(s.count.formatted(), s.count == 1 ? "dictation" : "dictations")
            }.padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func line(_ figure: String, _ label: String) -> some View {
        (Text(figure).foregroundStyle(Ink.text).fontWeight(.medium) + Text(" " + label).foregroundStyle(Ink.mid))
            .font(.system(size: 13)).monospacedDigit()
    }

    // MARK: Speed

    private var speedSection: some View {
        let sp = Stats.speed(model.days, now: model.now())
        let drawn = sp.points.contains { $0.wpm != nil }
        return VStack(alignment: .leading, spacing: 0) {
            heading("Speed", "Words a minute while talking, by \(sp.weekly ? "week" : "day"). \(sp.weekly ? "Weeks" : "Days") under \(Int(Stats.minSecondsForSpeed)) seconds of talking are skipped.")
            if drawn {
                SpeedChart(points: sp.points, weekly: sp.weekly).frame(height: 112)
            } else {
                Text("Not enough talking yet to draw your speed.").font(.system(size: 13)).foregroundStyle(Ink.dim).padding(.top, 4)
            }
        }
    }

    private func heading(_ s: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(s).font(Ink.serif(18)).foregroundStyle(Ink.text)
                .padding(.bottom, 3)
                .overlay(alignment: .bottom) { Rectangle().fill(Ink.red).frame(height: 2) }
            Text(sub).font(.system(size: 12.5)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 30).padding(.bottom, 12)
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Numbers only, never your words, in stats.json on this Mac. Deleting history doesn't change them.")
                .foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Button("Reset stats…") { confirmReset = true }.buttonStyle(.plain).foregroundStyle(Ink.red)
                .disabled(model.days.isEmpty)
        }
        .font(.system(size: 12.5))
        .padding(.top, 14)
        .overlay(alignment: .top) { Divider().overlay(Ink.line) }
        .padding(.top, 30)
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
                        .frame(width: axis - 8, alignment: .trailing)
                        .offset(y: plotH * (1 - f) - 7)
                }
                Rectangle().fill(Ink.mid.opacity(0.5)).frame(width: plotW, height: 1).offset(x: axis, y: plotH)
                ForEach(Array(points.enumerated()), id: \.offset) { i, p in
                    let h = top > 0 ? max(0, CGFloat(Double(p.score.words) / top) * plotH) : 0
                    Rectangle().fill(Ink.red)
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

/// Speed as a 2 px line through dots, scaled to the range you actually talk in (a speed chart from zero is a flat
/// line). Hover a dot for its day or week.
private struct SpeedChart: View {
    let points: [(date: Date, wpm: Int?)]
    let weekly: Bool
    private let axis: CGFloat = 40, under: CGFloat = 18

    var body: some View {
        let vals = points.compactMap(\.wpm)
        let lo = Double(((vals.min() ?? 0) - 5) / 10 * 10), hi = Double(((vals.max() ?? 0) + 14) / 10 * 10)
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
