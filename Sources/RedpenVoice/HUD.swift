import AppKit
import ApplicationServices
import VoiceCore

/// A small dark bar near the bottom of the screen while you talk, in the style picked in Settings. Messages use the
/// same bar: a flat grey line beside the words when something went wrong, a green tick when something worked. Never takes focus, so the cursor stays where the words will land.
@MainActor
final class HUD {
    /// "pen" (a red line that moves with your voice), "bars" (bars from the middle), "tape" (your voice scrolling
    /// left), "dot" (a breathing dot) or "classic" (the first bar: a red dot and twelve white bars).
    var style = "pen"
    /// Named when the mic gives nothing for a moment, so a silent interface is caught while you talk.
    var micName = ""
    private let panel: NSPanel
    private let box = NSView()
    private let label = NSTextField(labelWithString: "")
    private let timer = NSTextField(labelWithString: "0:00")
    private let meter = Level(frame: .zero)
    private let dot = NSView(frame: NSRect(x: 14, y: 17, width: 10, height: 10))
    private let doneMark = NSTextField(labelWithString: "✓")
    private var ok = false
    private var hideAt: DispatchWorkItem?
    private var tick: Timer?
    private var started = Date()
    /// The newest words written while you talk, shown beside the line.
    private var captionText = ""
    private var typingStopped = false
    /// Captured on key-down. Layout, captions, writing and completion messages keep this screen.
    private var dictationScreen: NSScreen?
    private let addWord = NSButton(title: "Add", target: nil, action: nil)
    private let notNow = NSButton(title: "Not now", target: nil, action: nil)
    private var wordAction: ((Bool) -> Void)?

    func captureScreen(textBox: CGRect?) {
        let screens = NSScreen.screens
        guard let primary = screens.first else { dictationScreen = nil; return }
        var windowFrame: CGRect?
        if let app = NSWorkspace.shared.frontmostApplication {
            var window: CFTypeRef?
            if AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedWindowAttribute as CFString, &window) == .success,
               let window, CFGetTypeID(window) == AXUIElementGetTypeID() {
                let element = window as! AXUIElement
                var position: CFTypeRef?, size: CFTypeRef?
                var p = CGPoint.zero, s = CGSize.zero
                if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
                   AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
                   let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID(),
                   AXValueGetValue(position as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) {
                    windowFrame = CGRect(origin: p, size: s)
                }
            }
        }
        let choice = BarScreen.choose(screens: screens.map(\.frame),
                                     textBox: textBox.map { BarScreen.fromAccessibility($0, primaryTop: primary.frame.maxY) },
                                     window: windowFrame.map { BarScreen.fromAccessibility($0, primaryTop: primary.frame.maxY) },
                                     pointer: NSEvent.mouseLocation)
        dictationScreen = choice.map { screens[$0.index] }
        if let choice { Log.note("bar: on screen \(choice.index + 1) (\(choice.reason))") }
    }

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 240, height: 44), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        box.frame = panel.contentView!.bounds
        box.wantsLayer = true
        box.autoresizingMask = [.width, .height]
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor(red: 0.89, green: 0.16, blue: 0.16, alpha: 1).cgColor
        dot.layer?.cornerRadius = 5
        panel.contentView?.addSubview(box)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        timer.font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        timer.textColor = NSColor(srgbRed: 0.71, green: 0.69, blue: 0.66, alpha: 1)
        doneMark.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        doneMark.textColor = NSColor(srgbRed: 0.3, green: 0.77, blue: 0.43, alpha: 1)
        for v in [dot, label, timer, meter, doneMark] as [NSView] { box.addSubview(v) }
        for button in [addWord, notNow] {
            button.font = label.font
            button.contentTintColor = .white
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.backgroundColor = NSColor(white: 1, alpha: 0.14).cgColor
            button.layer?.borderColor = NSColor(white: 1, alpha: 0.35).cgColor
            button.layer?.borderWidth = 1
            button.layer?.cornerRadius = 3
            button.target = self
            button.isHidden = true
            box.addSubview(button)
        }
        addWord.action = #selector(acceptWord)
        notNow.action = #selector(dismissWord)
    }

    /// Bars only while talking; words only when something needs saying.
    func show(_ text: String, level: Bool, ok: Bool = false) {
        typingStopped = false
        clearSuggestion()
        hideAt?.cancel()
        self.ok = ok
        meter.flat = !level
        if !level { meter.reset(style: "pen"); meter.flat = true }
        label.stringValue = text
        label.isHidden = text.isEmpty
        if level { started = Date(); meter.reset(style: style); meter.writing = false; captionText = "" }
        layout(text: text, level: level)
        place()
        panel.orderFrontRegardless()
        tick?.invalidate(); tick = nil
        if level { startTicking() }
    }

    /// After the key comes up: the bar stays, quietly moving, until the words land or a message replaces it.
    func writing() {
        guard !typingStopped else { return }
        guard style != "classic", panel.isVisible else { hide(); return }
        meter.writing = true
        meter.silent = false
        label.isHidden = true
        timer.stringValue = "Writing"
        layout(text: "", level: true)
        place()
        if tick == nil { startTicking() }
    }

    func level(_ v: Float) { meter.push(v) }

    /// Shows the end of what has been written so far while you are still talking.
    func caption(_ text: String) {
        guard !typingStopped else { return }
        captionText = text.count > 46 ? "…" + text.suffix(45) : text
        guard panel.isVisible, !meter.writing, !meter.silent else { return }
        label.stringValue = captionText
        label.isHidden = captionText.isEmpty
        layout(text: captionText, level: true)
        place()
    }

    /// Captions normally update an existing bar. Stopped live typing must also restore a hidden bar.
    func listeningCaption(_ text: String) {
        guard !typingStopped else { return }
        if !panel.isVisible || meter.writing || meter.flat { show("", level: true) }
        caption(text)
    }

    /// Keep a clear, fixed message until completion. Later engine callbacks must not look like live typing.
    func stoppedTyping() {
        guard !typingStopped else { return }
        show(DraftSafety.stoppedMessage, level: false)
        typingStopped = true
    }

    /// Saves the bar as it looks now, at 2x, for checking its shape without a screen recording (--hud-snapshot).
    func snapshot(to url: URL) {
        guard let layer = box.layer else { return }
        let size = box.bounds.size, scale: CGFloat = 2
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.scaleBy(x: scale, y: scale)
        layer.render(in: ctx)
        if let img = ctx.makeImage() { try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: url) }
    }

    func flash(_ text: String, ok: Bool = false, for seconds: Double = 1.2) {
        show(text, level: false, ok: ok)
        let w = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideAt = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    func hide() { typingStopped = false; hideAt?.cancel(); tick?.invalidate(); tick = nil; clearSuggestion(); panel.orderOut(nil) }

    /// Never replaces a warning or the listening/writing bar, and never makes the target app lose focus.
    @discardableResult
    func suggest(_ word: String, action: @escaping (Bool) -> Void) -> Bool {
        guard !panel.isVisible else { return false }
        show("Keep hearing “\(word)”. Add it to your words?", level: false)
        wordAction = action
        meter.isHidden = true
        label.frame.origin.x = 16
        var x = label.frame.maxX + 14
        for button in [addWord, notNow] {
            button.sizeToFit()
            button.frame = NSRect(x: x, y: 7, width: button.frame.width + 18, height: 26)
            button.isHidden = false
            x = button.frame.maxX + 8
        }
        panel.setContentSize(NSSize(width: x + 8, height: 40))
        panel.ignoresMouseEvents = false
        place()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideAt = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
        return true
    }

    func hideSuggestion() { if wordAction != nil { hide() } }

    private func clearSuggestion() {
        wordAction = nil
        addWord.isHidden = true; notNow.isHidden = true
        panel.ignoresMouseEvents = true
    }

    @objc private func acceptWord() { let action = wordAction; hide(); action?(true) }
    @objc private func dismissWord() { let action = wordAction; hide(); action?(false) }

    private func startTicking() {
        let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.frame() } }
        RunLoop.main.add(t, forMode: .common)
        tick = t
    }

    private func frame() {
        meter.step()
        guard !meter.writing else { return }
        let secs = Int(Date().timeIntervalSince(started))
        timer.stringValue = "\(secs / 60):\(String(format: "%02d", secs % 60))"
        // A second and a half of nothing on the mic: say which mic, while there is still time to fix it.
        let silent = meter.silentFor > 1.5 && !micName.isEmpty
        if silent != meter.silent {
            meter.silent = silent
            label.stringValue = silent ? "No sound from \(micName)" : captionText
            label.isHidden = label.stringValue.isEmpty
            layout(text: label.stringValue, level: true)
            place()
        }
    }

    private func layout(text: String, level: Bool) {
        let classic = style == "classic" && level
        box.layer?.backgroundColor = (classic ? NSColor(white: 0.07, alpha: 0.96) : NSColor(srgbRed: 0.08, green: 0.08, blue: 0.075, alpha: 0.97)).cgColor
        box.layer?.borderColor = NSColor(white: 1, alpha: classic ? 0.35 : 0).cgColor
        box.layer?.borderWidth = classic ? 1 : 0
        dot.isHidden = !(level && (style == "classic" || style == "tape"))
        doneMark.isHidden = level || !ok
        // A message: a tick for done, otherwise the pen line lying flat.
        meter.isHidden = level ? false : ok
        timer.isHidden = !(level && ["pen", "tape", "dot"].contains(style))
        let msgWidth: CGFloat = text.isEmpty ? 0 : ceil(label.attributedStringValue.size().width) + 4
        let height: CGFloat = classic ? 44 : 40
        var x: CGFloat = 16
        if !level {
            if ok { doneMark.sizeToFit(); doneMark.frame.origin = NSPoint(x: x, y: (height - doneMark.frame.height) / 2); x = doneMark.frame.maxX + 8 }
            else { meter.frame = NSRect(x: x, y: (height - 26) / 2, width: 110, height: 26); x = meter.frame.maxX + 12 }
        } else {
            if style == "tape" { dot.frame = NSRect(x: 14, y: (height - 8) / 2, width: 8, height: 8); dot.layer?.cornerRadius = 4; x = 30 }
            else if style == "classic" { dot.frame = NSRect(x: 14, y: 17, width: 10, height: 10); dot.layer?.cornerRadius = 5; x = text.isEmpty ? 34 : 106 }
            let meterWidth: CGFloat = ["pen": 150, "bars": 120, "tape": 170, "dot": 26, "classic": 116][style] ?? 150
            meter.frame = NSRect(x: x, y: (height - 26) / 2, width: meterWidth, height: 26)
            x = meter.frame.maxX + 10
        }
        if !timer.isHidden { timer.frame = NSRect(x: x, y: (height - 16) / 2, width: 52, height: 16); timer.sizeToFit(); x = timer.frame.maxX + 12 }
        if !text.isEmpty {
            label.frame = NSRect(x: x, y: (height - 18) / 2, width: msgWidth, height: 18)
            x += msgWidth
        }
        var width = x + (classic ? 14 : 16)
        if classic { width = text.isEmpty ? 160 : 240 }
        panel.setContentSize(NSSize(width: width, height: height))
        // Square-ish corners in every style and state, never a pill (D-813).
        box.layer?.cornerRadius = 3
    }

    // Above where chat apps put their typing box, at the same offset on the screen captured on key-down.
    private func place() {
        let mouse = NSEvent.mouseLocation
        if let s = connectedDictationScreen() ?? NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main {
            let f = s.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY + 120))
        }
    }

    /// The captured display as it is connected now, by its display number. Messages can come minutes after the
    /// key went down ("Saved for ..." waits up to 10 minutes): a display unplugged or rearranged since then must not
    /// put the bar off screen, where nobody sees it.
    private func connectedDictationScreen() -> NSScreen? {
        guard let captured = dictationScreen else { return nil }
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let id = captured.deviceDescription[key] as? NSNumber else { dictationScreen = nil; return nil }
        let now = NSScreen.screens.first { ($0.deviceDescription[key] as? NSNumber) == id }
        dictationScreen = now
        return now
    }

    /// The moving part of the bar. Levels arrive from the mic; `step` runs thirty times a second for motion.
    final class Level: NSView {
        var style = "pen"
        var writing = false
        var silent = false
        /// Lying flat and grey: the bar is showing a message, not listening.
        var flat = false
        private(set) var silentFor: Double = 0
        private var history = [Float](repeating: 0, count: 90)
        private var latest: Float = 0
        private var smooth: CGFloat = 0
        private var t: Double = 0
        private let red = NSColor(srgbRed: 1, green: 0.353, blue: 0.29, alpha: 1)
        private let white = NSColor(srgbRed: 0.953, green: 0.945, blue: 0.925, alpha: 0.92)
        private let faint = NSColor(srgbRed: 0.953, green: 0.945, blue: 0.925, alpha: 0.28)

        func reset(style: String) { self.style = style; history = .init(repeating: 0, count: 90); latest = 0; smooth = 0; t = 0; silentFor = 0; silent = false }
        func push(_ v: Float) { latest = v }

        func step() {
            t += 1.0 / 30
            let v = writing ? 0 : latest
            smooth += (CGFloat(v) - smooth) * 0.35
            history.removeFirst(); history.append(Float(smooth))
            silentFor = v < 0.02 ? silentFor + 1.0 / 30 : 0
            needsDisplay = true
        }

        override func draw(_ r: NSRect) {
            let W = bounds.width, H = bounds.height, m = H / 2
            if flat {
                let p = NSBezierPath(); p.lineWidth = 2; p.lineCapStyle = .round
                NSColor(srgbRed: 0.42, green: 0.41, blue: 0.38, alpha: 1).setStroke()
                p.move(to: NSPoint(x: 2, y: m)); p.line(to: NSPoint(x: W - 2, y: m)); p.stroke()
                return
            }
            switch style {
            case "pen":
                let p = NSBezierPath(); p.lineWidth = 2; p.lineCapStyle = .round; p.lineJoinStyle = .round
                if writing {
                    faint.setStroke(); p.move(to: NSPoint(x: 2, y: m)); p.line(to: NSPoint(x: W - 2, y: m)); p.stroke()
                    let x0 = 2 + CGFloat((t * 1.4).truncatingRemainder(dividingBy: 1)) * (W - 30)
                    let d = NSBezierPath(); d.lineWidth = 2; d.lineCapStyle = .round
                    red.setStroke(); d.move(to: NSPoint(x: x0, y: m)); d.line(to: NSPoint(x: x0 + 26, y: m)); d.stroke()
                    return
                }
                (silent ? faint : red).setStroke()
                for i in stride(from: 0, through: Int(W), by: 2) {
                    let x = CGFloat(i)
                    let a = smooth * (m - 3) * (0.55 + 0.45 * sin(x * 0.09 + t * 3)) * sin(.pi * x / W)
                    let pt = NSPoint(x: x, y: m + sin(x * 0.23 - t * 14) * a)
                    i == 0 ? p.move(to: pt) : p.line(to: pt)
                }
                p.stroke()
            case "bars":
                let n = 15, bw: CGFloat = 4, gap = (W - CGFloat(n) * bw) / CGFloat(n - 1)
                (silent ? faint : white).setFill()
                for i in 0..<n {
                    let back = abs(i - 7) * 2
                    let k = CGFloat(history[history.count - 1 - back])
                    let h = writing ? 3 + 3 * max(0, sin(t * 8 - Double(i) * 0.6))
                                    : max(3, k * (H - 4) * (1 - CGFloat(abs(i - 7)) / 10))
                    NSBezierPath(roundedRect: NSRect(x: CGFloat(i) * (bw + gap), y: m - h / 2, width: bw, height: h), xRadius: 2, yRadius: 2).fill()
                }
            case "tape":
                let stepW: CGFloat = 2
                let shown = history.suffix(Int(W / stepW))
                (silent ? faint : white).setFill()
                for (i, k) in shown.enumerated() {
                    let h = writing ? 2 : max(1.5, CGFloat(k) * (H - 4))
                    NSRect(x: W - CGFloat(shown.count - i) * stepW, y: m - h / 2, width: 1.5, height: h).fill()
                }
                if writing { red.setFill(); NSRect(x: CGFloat((t * 1.2).truncatingRemainder(dividingBy: 1)) * W, y: m - 1, width: 18, height: 2).fill() }
            case "dot":
                let rad = writing ? 5 + 2 * CGFloat(sin(t * 6)) : silent ? 4 : 5 + smooth * 7
                (silent ? NSColor(srgbRed: 0.53, green: 0.51, blue: 0.48, alpha: 1) : red.withAlphaComponent(writing ? 0.7 : 1)).setFill()
                NSBezierPath(ovalIn: NSRect(x: m - rad, y: m - rad, width: rad * 2, height: rad * 2)).fill()
            default:
                // The first bar: twelve white bars, newest on the right.
                NSColor.white.withAlphaComponent(0.9).setFill()
                let w: CGFloat = 6, gap: CGFloat = 4.5
                for (i, k) in history.suffix(12).enumerated() {
                    let h = max(3, CGFloat(k) * H * 0.85)
                    NSBezierPath(roundedRect: NSRect(x: CGFloat(i) * (w + gap), y: (H - h) / 2, width: w, height: h), xRadius: 1, yRadius: 1).fill()
                }
            }
        }
    }
}
