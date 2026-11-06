import AppKit
import VoiceCore

/// The meeting control (D-957, variant A): the talking bar's dark 40-point bar, kept on screen while meeting notes
/// are on. The time, Me and Others level bars, Pause or Resume, and a red Stop. Drag it anywhere and it stays there
/// next time; click the time to fold it into a small square. It never takes the keyboard from the call app, and it
/// steps aside while you dictate. Dark on a light or dark Mac, like the talking bar.
@MainActor
final class MeetingBar: NSObject {
    /// What the bar shows while recording, read ten times a second.
    struct Now { var recorded: Double; var paused: Bool; var me: Float; var others: Float; var noSound: Bool; var savingFailed = false }

    /// `offer`: notes saved, with a button for a better summary from this helper ("claude", "chatgpt", "gemini",
    /// "cursor", "command" or "mac"; D-956, D-1010, D-1012). `busy`: waiting on it.
    enum Mode: Equatable { case recording, writing(Int, String), done(String, Bool), offer(String), busy(String) }

    var source: () -> Now? = { nil }
    /// True while a dictation is on screen: the bar steps aside.
    var dictating: () -> Bool = { false }
    var onStop: () -> Void = {}
    var onPause: () -> Void = {}
    var onAllow: () -> Void = {}
    /// Better summary clicked, with the helper the button named.
    var onBetter: (String) -> Void = { _ in }

    private let panel: Panel
    private let box = NSView()
    private let rec = NSView()
    private let time = NSButton(title: "0:00", target: nil, action: nil)
    private let pausedLabel = NSTextField(labelWithString: "Paused")
    private let sep1 = NSView(), sep2 = NSView()
    private let meBars = Bars(), othersBars = Bars()
    private let meLabel = NSTextField(labelWithString: "Me"), othersLabel = NSTextField(labelWithString: "Others")
    private let warn = NSTextField(labelWithString: "No sound from the Mac")
    private let allow = NSButton(title: "Allow it", target: nil, action: nil)
    private let pause = NSButton(title: "Pause", target: nil, action: nil)
    private let stop = NSButton(title: "Stop", target: nil, action: nil)
    private let better = NSButton(title: "Better summary", target: nil, action: nil)
    private let notNow = NSButton(title: "Not now", target: nil, action: nil)
    private let message = NSTextField(labelWithString: "")
    private let progress = NSView(), progressFill = NSView()
    private let tick = NSTextField(labelWithString: "✓")
    private var timer: Timer?
    private(set) var mode: Mode = .recording
    private var folded = false
    private var shown = false
    private var hideWork: DispatchWorkItem?
    private var lastLayout = ""
    private static let positionKey = "meetingBarPosition"

    static let red = NSColor(srgbRed: 1, green: 0.353, blue: 0.29, alpha: 1)
    static let text = NSColor(srgbRed: 0.953, green: 0.945, blue: 0.925, alpha: 1)
    static let dim = NSColor(srgbRed: 0.71, green: 0.69, blue: 0.66, alpha: 1)
    static let warnText = NSColor(srgbRed: 1, green: 0.706, blue: 0.659, alpha: 1)

    /// A panel that never becomes key or main, so a click on Stop leaves the call app in front with its keyboard.
    final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    override init() {
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 40), styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: true)
        super.init()
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.appearance = NSAppearance(named: .darkAqua)
        box.frame = panel.contentView!.bounds
        box.autoresizingMask = [.width, .height]
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(srgbRed: 0.08, green: 0.08, blue: 0.075, alpha: 0.97).cgColor
        box.layer?.cornerRadius = 3
        panel.contentView?.addSubview(box)

        rec.wantsLayer = true
        rec.layer?.cornerRadius = 2
        time.isBordered = false
        time.font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        time.contentTintColor = Self.dim
        time.target = self; time.action = #selector(toggleFold)
        time.toolTip = "Fold the bar into a small square"
        for l in [pausedLabel, message] { l.font = NSFont.systemFont(ofSize: 13, weight: .medium); l.textColor = Self.text }
        for l in [meLabel, othersLabel] { l.font = NSFont.systemFont(ofSize: 11.5); l.textColor = Self.dim }
        warn.font = NSFont.systemFont(ofSize: 13, weight: .medium); warn.textColor = Self.warnText
        for s in [sep1, sep2] { s.wantsLayer = true; s.layer?.backgroundColor = NSColor(white: 1, alpha: 0.16).cgColor }
        for (b, title, act) in [(pause, "Pause", #selector(pauseTapped)), (stop, "Stop", #selector(stopTapped)), (allow, "Allow it", #selector(allowTapped)),
                                (better, "Better summary", #selector(betterTapped)), (notNow, "Not now", #selector(notNowTapped))] {
            b.title = title
            b.isBordered = false
            b.wantsLayer = true
            b.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
            b.layer?.cornerRadius = 3
            b.target = self; b.action = act
        }
        pause.contentTintColor = Self.text
        pause.layer?.backgroundColor = NSColor(white: 1, alpha: 0.10).cgColor
        pause.layer?.borderColor = NSColor(white: 1, alpha: 0.30).cgColor
        pause.layer?.borderWidth = 1
        pause.toolTip = "Pause: nothing is recorded until you resume (⌃⌥P)"
        better.layer?.backgroundColor = NSColor(white: 1, alpha: 0.10).cgColor
        better.layer?.borderColor = NSColor(white: 1, alpha: 0.30).cgColor
        better.layer?.borderWidth = 1
        notNow.attributedTitle = NSAttributedString(string: "Not now", attributes: [.foregroundColor: Self.dim, .font: NSFont.systemFont(ofSize: 12.5)])
        stop.attributedTitle = NSAttributedString(string: "Stop", attributes: [.foregroundColor: NSColor(srgbRed: 0.106, green: 0.027, blue: 0.02, alpha: 1),
                                                                               .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)])
        stop.layer?.backgroundColor = Self.red.cgColor
        stop.toolTip = "Stop and write the notes (⌃⌥M)"
        allow.attributedTitle = NSAttributedString(string: "Allow it", attributes: [.foregroundColor: Self.red, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                                                                    .font: NSFont.systemFont(ofSize: 12.5, weight: .medium)])
        allow.toolTip = "Opens System Audio Recording in Privacy & Security"
        progress.wantsLayer = true; progress.layer?.backgroundColor = NSColor(srgbRed: 0.953, green: 0.945, blue: 0.925, alpha: 0.28).cgColor
        progressFill.wantsLayer = true; progressFill.layer?.backgroundColor = Self.red.cgColor
        progress.addSubview(progressFill)
        tick.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        tick.textColor = NSColor(srgbRed: 0.3, green: 0.77, blue: 0.43, alpha: 1)
        for v in [rec, time, pausedLabel, sep1, meBars, meLabel, othersBars, othersLabel, warn, allow, sep2, pause, stop, message, progress, tick, better, notNow] as [NSView] {
            box.addSubview(v)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(moved), name: NSWindow.didMoveNotification, object: panel)
    }

    // MARK: Showing

    func showRecording() {
        hideWork?.cancel()
        mode = .recording
        folded = false
        start()
    }

    func showWriting(_ pct: Int, _ words: String) {
        hideWork?.cancel()
        mode = .writing(pct, words)
        start()
    }

    /// "Notes saved" with a tick, or a plain failure, then the bar goes.
    func finish(_ text: String, ok: Bool) {
        mode = .done(text, ok)
        start()
        let w = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (ok ? 2.5 : 4), execute: w)
    }

    /// "Notes saved" with the offer of a better summary from `helper`; it goes after a minute untouched.
    func offer(_ helper: String) {
        mode = .offer(helper)
        start()
        let w = DispatchWorkItem { [weak self] in if case .offer = self?.mode { self?.hide() } }
        hideWork?.cancel()
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: w)
    }

    /// While the better summary is being written.
    func showBusy(_ text: String) {
        hideWork?.cancel()
        mode = .busy(text)
        start()
    }

    func hide() {
        timer?.invalidate(); timer = nil
        shown = false
        panel.orderOut(nil)
    }

    private func start() {
        if timer == nil {
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        refresh()
    }

    private func refresh() {
        // Never on top of a dictation: the talking bar has the screen while you talk.
        if dictating() { if panel.isVisible { panel.orderOut(nil) }; return }
        let now = source()
        layout(now)
        if !panel.isVisible || !shown {
            if !shown { place() }
            shown = true
            panel.orderFrontRegardless()
        }
    }

    // MARK: Layout

    private func layout(_ now: Now?) {
        let h: CGFloat = 40
        var x: CGFloat = 14
        let all: [NSView] = [rec, time, pausedLabel, sep1, meBars, meLabel, othersBars, othersLabel, warn, allow, sep2, pause, stop, message, progress, tick, better, notNow]
        var visible: [NSView] = []
        func put(_ v: NSView, _ w: CGFloat, _ vh: CGFloat, gap: CGFloat = 10) {
            v.frame = NSRect(x: x, y: ((h - vh) / 2).rounded(), width: w, height: vh); x += w + gap; visible.append(v)
        }
        func label(_ l: NSTextField, gap: CGFloat = 10) { l.sizeToFit(); put(l, ceil(l.frame.width), 17, gap: gap) }
        // The small Me and Others names sit on the bars' baseline, not the bar's middle.
        func small(_ l: NSTextField, gap: CGFloat) { label(l, gap: gap); l.frame.origin.y = 10 }
        func button(_ b: NSButton, padding: CGFloat = 20, gap: CGFloat = 8) { b.sizeToFit(); put(b, ceil(b.frame.width) + padding, 26, gap: gap) }

        message.textColor = Self.text
        switch mode {
        case .recording:
            guard let now else { break }
            time.title = Meeting.clockShort(now.recorded)
            rec.layer?.backgroundColor = now.paused ? NSColor.clear.cgColor : Self.red.cgColor
            rec.layer?.borderColor = Self.dim.cgColor
            rec.layer?.borderWidth = now.paused ? 2 : 0
            if now.savingFailed { folded = false }
            if folded {
                rec.frame = NSRect(x: 15.5, y: 22, width: 9, height: 9); visible.append(rec)
                time.font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
                time.sizeToFit(); time.frame = NSRect(x: 0, y: 4, width: 40, height: 14); visible.append(time)
                x = 40
                time.toolTip = "Open the bar"
                break
            }
            if now.savingFailed {
                message.stringValue = Meeting.savingWarning
                message.textColor = Self.red
                label(message, gap: 14)
                button(stop, gap: 8)
                break
            }
            message.textColor = Self.text
            time.font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
            time.toolTip = "Fold the bar into a small square"
            put(rec, 9, 9, gap: 10)
            time.sizeToFit(); put(time, max(38, ceil(time.frame.width)), 18, gap: now.paused ? 8 : 12)
            if now.paused { label(pausedLabel, gap: 12) }
            put(sep1, 1, 20, gap: 12)
            meBars.level = now.paused ? nil : now.me
            put(meBars, Bars.width, 16, gap: 5); small(meLabel, gap: 12)
            othersBars.level = now.paused || now.noSound ? nil : now.others
            put(othersBars, Bars.width, 16, gap: 5); small(othersLabel, gap: 12)
            if now.noSound && !now.paused {
                label(warn, gap: 6); button(allow, padding: 6, gap: 8)
            } else {
                put(sep2, 1, 20, gap: 12)
            }
            pause.attributedTitle = NSAttributedString(string: now.paused ? "Resume" : "Pause",
                                                       attributes: [.foregroundColor: Self.text, .font: NSFont.systemFont(ofSize: 12.5, weight: .medium)])
            pause.toolTip = now.paused ? "Resume recording (⌃⌥P)" : "Pause: nothing is recorded until you resume (⌃⌥P)"
            button(pause)
            button(stop, gap: 8)
        case .writing(let pct, let words):
            message.stringValue = "\(words) \(pct)%"
            label(message, gap: 14)
            put(progress, 120, 2, gap: 16)
            progressFill.frame = NSRect(x: 0, y: 0, width: 120 * CGFloat(min(100, max(0, pct))) / 100, height: 2)
        case .done(let text, let ok):
            if ok { tick.sizeToFit(); put(tick, ceil(tick.frame.width), 18, gap: 8) }
            message.stringValue = text
            label(message, gap: 16)
        case .offer(let helper):
            tick.sizeToFit(); put(tick, ceil(tick.frame.width), 18, gap: 8)
            message.stringValue = "Notes saved"
            label(message, gap: 14)
            better.attributedTitle = NSAttributedString(string: BetterSummary.button(helper),
                                                        attributes: [.foregroundColor: Self.text, .font: NSFont.systemFont(ofSize: 12.5, weight: .medium)])
            better.toolTip = BetterSummary.tip(helper)
            button(better)
            button(notNow, padding: 8, gap: 8)
        case .busy(let text):
            message.stringValue = text
            label(message, gap: 16)
        }
        for v in all { v.isHidden = !visible.contains(v) }
        let width = folded && mode == .recording ? 40 : x - (mode == .recording ? 8 : 0) + 6
        let key = "\(mode)-\(folded)-\(Int(width))"
        if key != lastLayout {
            lastLayout = key
            // Resized around its own middle, so the bar doesn't creep sideways as its words change.
            let f = panel.frame
            let mid = shown ? f.midX : 0
            panel.setContentSize(NSSize(width: width, height: h))
            if shown { panel.setFrameOrigin(NSPoint(x: (mid - width / 2).rounded(), y: f.minY)) }
        }
        meBars.needsDisplay = true; othersBars.needsDisplay = true
    }

    /// Where you last left it, if that is still on a screen; else the bottom middle, just above the talking bar's place.
    private func place() {
        let size = panel.frame.size
        if let s = UserDefaults.standard.string(forKey: Self.positionKey) {
            let p = NSPointFromString(s)
            let rect = NSRect(x: p.x - size.width / 2, y: p.y, width: size.width, height: size.height)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) { panel.setFrameOrigin(rect.origin); return }
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
        guard let f = screen?.frame else { return }
        panel.setFrameOrigin(NSPoint(x: (f.midX - size.width / 2).rounded(), y: f.minY + 172))
    }

    /// Remembers its middle and height after a drag.
    @objc private func moved() {
        guard shown else { return }
        let f = panel.frame
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: f.midX, y: f.minY)), forKey: Self.positionKey)
    }

    // MARK: Actions

    @objc private func toggleFold() { guard mode == .recording else { return }; folded.toggle(); refresh() }
    @objc private func stopTapped() { onStop() }
    @objc private func pauseTapped() { onPause() }
    @objc private func allowTapped() { onAllow() }
    @objc private func betterTapped() { if case .offer(let h) = mode { onBetter(h) } }
    @objc private func notNowTapped() { hide() }

    /// Five small bars that move with the sound; flat and grey when there is none to show.
    final class Bars: NSView {
        static let width: CGFloat = 23
        var level: Float? { didSet { if let level { history.append(level); if history.count > 5 { history.removeFirst() } } } }
        private var history: [Float] = [0, 0, 0, 0, 0]
        override func draw(_ dirty: NSRect) {
            let shape: [CGFloat] = [0.45, 0.8, 1, 0.7, 0.5]
            for i in 0..<5 {
                let x = CGFloat(i) * 5
                if let level {
                    let v = CGFloat(max(level, history[i])) * shape[i]
                    let h = max(3, bounds.height * min(1, v))
                    MeetingBar.red.setFill()
                    NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: 3, height: h), xRadius: 1, yRadius: 1).fill()
                } else {
                    NSColor(srgbRed: 0.42, green: 0.41, blue: 0.38, alpha: 1).setFill()
                    NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: 3, height: 3), xRadius: 1, yRadius: 1).fill()
                }
            }
        }
    }

    /// Draws the bar in each state to PNGs, for checking its shape without a meeting (`--meeting-bar-shot folder`).
    func snapshots(to folder: URL, done: @escaping () -> Void) {
        let states: [(String, Mode, Now?, Bool)] = [
            ("recording", .recording, Now(recorded: 754, paused: false, me: 0.7, others: 0.5, noSound: false), false),
            ("paused", .recording, Now(recorded: 754, paused: true, me: 0, others: 0, noSound: false), false),
            ("no-sound", .recording, Now(recorded: 21, paused: false, me: 0.6, others: 0, noSound: true), false),
            ("folded", .recording, Now(recorded: 754, paused: false, me: 0.6, others: 0.4, noSound: false), true),
            ("writing", .writing(40, "Writing notes…"), nil, false),
            ("saved", .done("Notes saved", true), nil, false),
            ("offer", .offer("claude"), nil, false),
            ("busy", .busy("Asking Claude for a better summary…"), nil, false),
            ("offer-mac", .offer(BetterSummary.onMac), nil, false),
            ("busy-mac", .busy("Writing a better summary on this Mac…"), nil, false),
        ]
        var i = 0
        func next() {
            guard i < states.count else { done(); return }
            let (name, m, now, fold) = states[i]; i += 1
            mode = m; folded = fold; lastLayout = ""
            for _ in 0..<5 { layout(now) }
            panel.setFrameOrigin(NSPoint(x: -4000, y: -4000))
            panel.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [self] in
                box.display()
                // Twice the size, as a Retina screen shows it, like the other README pictures.
                if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(box.bounds.width * 2), pixelsHigh: Int(box.bounds.height * 2),
                                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                              bytesPerRow: 0, bitsPerPixel: 0) {
                    rep.size = box.bounds.size
                    box.cacheDisplay(in: box.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent("meeting-bar-\(name).png"))
                }
                next()
            }
        }
        next()
    }
}
