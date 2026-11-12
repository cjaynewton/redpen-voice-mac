import AppKit
import CoreText
import VoiceCore

/// The approved R3 surface. Only the chosen line uses red. Native buttons keep mouse and accessibility actions.
@MainActor
final class TalkingBarView: NSView {
    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    static let surface = color(0x25272B), dock = color(0x191B1E)
    static let text = color(0xFAFAFA), body = color(0xD1D2D4), label = color(0xC4C6CA)
    // D-1566 explicitly picks the brighter R2 red over LOOK.md's darker red, on the line only.
    static let red = color(0xEF5045)
    static func font(_ size: CGFloat, medium: Bool = false) -> NSFont {
        NSFont(name: medium ? "InstrumentSans-Medium" : "InstrumentSans-Regular", size: size)
            ?? NSFont.systemFont(ofSize: size, weight: medium ? .medium : .regular)
    }
    static func registerFonts() {
        let roots = [Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
                     URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                        .deletingLastPathComponent().appendingPathComponent("Resources/Fonts")]
        for root in roots.compactMap({ $0 }) {
            for name in ["InstrumentSans-Regular", "InstrumentSans-Medium"] {
                let url = root.appendingPathComponent(name + ".ttf")
                if FileManager.default.fileExists(atPath: url.path) { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
            }
            if NSFont(name: "InstrumentSans-Regular", size: 14) != nil { break }
        }
    }

    var state = TalkingBar.State.resting
    var style = "pen"
    var menuOpen = false
    var message = ""
    var success = false
    var seconds = 0
    var words = 0
    var phase = 0.0
    var stateAge = 1.0
    var smooth: CGFloat = 0
    var history = [CGFloat](repeating: 0, count: 90)
    var reducedMotion = false
    var freeze = false
    var choices: [String] = []
    var canFinish = true
    var canCancel = true
    var canPaste = true
    var canKeepBar = false
    var keepBarOnScreen = false
    var talkKey = "Fn"
    var onAction: (String) -> Void = { _ in }
    var onDrag: (CGPoint, Bool) -> Void = { _, _ in }
    private var buttons: [BarButton] = []
    private var dragStart: CGPoint?
    private var dragOrigin = CGPoint.zero
    private var moved = false
    private var hoverGrip = false
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var railHeight: CGFloat { state == .resting || state == .done ? 40 : 52 }
    var menuHeight: CGFloat { menuOpen ? (state == .resting ? 137 : 165) + (canKeepBar ? 28 : 0) : 0 }
    var menuSeparatorY: CGFloat { (state == .resting ? 40 : 68) + (canKeepBar ? 28 : 0) }
    var needsOverflow: Bool {
        state == .needs && (message as NSString).size(withAttributes: [.font: Self.font(15)]).width > bounds.width - (style == "dot" ? 146 : 168)
    }
    var detailHeight: CGFloat {
        guard !message.isEmpty, state != .needs || needsOverflow else { return choices.isEmpty ? 0 : 40 }
        let width = max(80, bounds.width - 32)
        let rect = (message as NSString).boundingRect(with: NSSize(width: width, height: 2000),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: Self.font(15)])
        return ceil(rect.height) + 20 + (choices.isEmpty ? 0 : 36)
    }
    func desiredSize(maxWidth: CGFloat) -> CGSize {
        var size = TalkingBar.size(state, style: style, menu: menuOpen)
        if menuOpen && canKeepBar { size.height += 28 }
        if !message.isEmpty && state != .needs {
            let measured = (message as NSString).size(withAttributes: [.font: Self.font(15)]).width + 32
            size.width = max(size.width, min(maxWidth, min(600, measured)))
        }
        if state == .needs {
            size.width = max(size.width, min(600, (style == "dot" ? 146 : 168) + (message as NSString).size(withAttributes: [.font: Self.font(15)]).width))
        }
        size.width = min(maxWidth, size.width)
        // Measure wrapping at the target width, before the window animates.
        let old = frame.size
        setFrameSize(NSSize(width: size.width, height: old.height))
        size.height += detailHeight
        setFrameSize(old)
        return size
    }

    func rebuildControls() {
        buttons.forEach { $0.removeFromSuperview() }; buttons.removeAll()
        func button(_ title: String, _ hint: String, _ icon: String, _ action: String, _ rect: CGRect,
                    enabled: Bool = true, primary: Bool = false) {
            let b = BarButton(frame: rect)
            b.title = title; b.hint = hint; b.icon = icon; b.primary = primary; b.isEnabled = enabled
            b.run = { [weak self] in self?.onAction(action) }
            b.setAccessibilityLabel(title.isEmpty ? (menuOpen ? "Hide options" : "Show options") : title)
            b.setAccessibilityHelp(hint)
            addSubview(b); buttons.append(b)
        }
        let railY = bounds.height - railHeight
        if state != .done {
            button("", "", menuOpen ? "down" : "up", "options",
                   CGRect(x: bounds.width - 40, y: railY + (railHeight - 32) / 2, width: 32, height: 32))
            buttons.last?.selected = menuOpen
        }
        if menuOpen {
            var y: CGFloat = 7
            if state == .resting {
                button("Dictate", "Hold \(talkKey)", "mic", "start", CGRect(x: 7, y: y, width: bounds.width - 14, height: 28), primary: true)
                y += 28
            } else {
                button("Finish", talkKey, "check", "finish", CGRect(x: 7, y: y, width: bounds.width - 14, height: 28), enabled: canFinish, primary: true)
                y += 28
                button("Cancel", "Esc ×2", "x", "cancel", CGRect(x: 7, y: y, width: bounds.width - 14, height: 28), enabled: canCancel)
                y += 28
            }
            if canKeepBar {
                button("Keep bar on screen", keepBarOnScreen ? "On" : "Off", keepBarOnScreen ? "check" : "", "keepBar",
                       CGRect(x: 7, y: y, width: bounds.width - 14, height: 28))
                buttons.last?.setAccessibilityValue(keepBarOnScreen ? "On" : "Off")
                y += 28
            }
            y += 11
            for row in [("Paste last", "⌃⌥V", "paste", "paste"), ("Meeting notes", "", "notes", "notes"), ("Settings", "⌘,", "settings", "settings")] {
                button(row.0, row.1, row.2, row.3, CGRect(x: 7, y: y, width: bounds.width - 14, height: 28), enabled: row.3 != "paste" || canPaste)
                y += 28
            }
        }
        if !choices.isEmpty {
            var x: CGFloat = 16
            for (index, title) in choices.enumerated() {
                let w = ceil((title as NSString).size(withAttributes: [.font: Self.font(14)]).width) + 24
                button(title, "", "", "choice\(index)", CGRect(x: x, y: railY - 34, width: w, height: 28))
                buttons.last?.selected = true
                x += w + 8
            }
        }
        setAccessibilityLabel(state == .needs ? message : state.rawValue.capitalized)
        setAccessibilityValue(message.isEmpty ? (state == .writing ? "\(words) words" : "") : message)
        needsDisplay = true
    }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func resetCursorRects() {
        addCursorRect(CGRect(x: 0, y: bounds.height - railHeight, width: max(0, bounds.width - (state == .done ? 0 : 40)), height: railHeight), cursor: .openHand)
    }
    override func mouseMoved(with event: NSEvent) {
        hoverGrip = CGRect(x: 8, y: bounds.height - railHeight, width: 20, height: railHeight).contains(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) { hoverGrip = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation; dragOrigin = window?.frame.origin ?? .zero; moved = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let now = NSEvent.mouseLocation, dx = now.x - start.x, dy = now.y - start.y
        if abs(dx) + abs(dy) > 3 { moved = true }
        if moved { NSCursor.closedHand.set(); onDrag(CGPoint(x: dragOrigin.x + dx, y: dragOrigin.y + dy), false) }
    }
    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        if moved { onDrag(window?.frame.origin ?? dragOrigin, true) }
        else if state == .resting { onAction("start") }
        NSCursor.openHand.set()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onAction("dismiss") }
        else if event.keyCode == 36 || event.keyCode == 49 { onAction(state == .resting ? "start" : "options") }
        else { onAction("dismiss") }
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.surface.setFill(); bounds.fill()
        NSColor.white.withAlphaComponent(0.06).setFill(); CGRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        let railY = bounds.height - railHeight, center = railY + railHeight / 2
        if menuOpen {
            NSColor.white.withAlphaComponent(0.2).setFill()
            CGRect(x: 0, y: menuHeight - 1, width: bounds.width, height: 1).fill()
            CGRect(x: 16, y: menuSeparatorY, width: bounds.width - 32, height: 1).fill()
        }
        if hoverGrip { Self.dock.setFill(); CGRect(x: 8, y: center - 16, width: 20, height: 32).fill() }
        (hoverGrip ? Self.text : Self.label).setFill()
        for row in 0..<3 { for col in 0..<2 {
            CGRect(x: 13 + CGFloat(col) * 6.7, y: center - 8.5 + CGFloat(row) * 6.8, width: 3.3, height: 3.4).fill()
        } }
        if !message.isEmpty && (state != .needs || needsOverflow) {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
            (message as NSString).draw(in: CGRect(x: 16, y: menuHeight + 9, width: bounds.width - 32,
                height: max(20, detailHeight - (choices.isEmpty ? 16 : 52))),
                withAttributes: [.font: Self.font(15), .foregroundColor: Self.body, .paragraphStyle: paragraph])
        }
        if state == .done {
            let age = freeze || reducedMotion ? 0.3 : stateAge
            let alpha = age < 0.3 ? min(1, age / 0.3) : max(0, 1 - (age - 0.3) / 0.45)
            let scale = 0.8 + 0.2 * min(1, age / 0.3)
            Self.drawIcon("check", in: CGRect(x: 40 + 12 * (1 - scale), y: center - 12 * scale, width: 24 * scale, height: 24 * scale), color: Self.text.withAlphaComponent(alpha))
            return
        }
        var signalX: CGFloat = 40
        if state == .resting || state == .needs {
            Self.drawIcon(state == .needs ? "mic-off" : "mic", in: CGRect(x: 40, y: center - 10, width: 20, height: 20), color: state == .needs ? Self.text : Self.body)
            signalX = 68
        }
        let right = bounds.width - 50
        var signalEnd = right
        if state == .listening {
            let clock = "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
            drawSettled(clock, rect: CGRect(x: right - 42, y: center - 11, width: 42, height: 24), size: 17, align: .right)
            signalEnd = right - 52
        } else if state == .writing {
            let count = NSMutableAttributedString(string: "\(words)", attributes: [.font: Self.font(17, medium: true), .foregroundColor: Self.text])
            count.append(NSAttributedString(string: " words", attributes: [.font: Self.font(17), .foregroundColor: Self.label]))
            let width = ceil(count.size().width)
            drawSettled(count, at: CGPoint(x: right - width, y: center - count.size().height / 2))
            signalEnd = right - width - 10
        } else if state == .needs {
            signalEnd = signalX + (style == "dot" ? 18 : 40)
            let shown = needsOverflow ? "No sound" : message
            let line = NSMutableAttributedString(string: shown, attributes: [.font: Self.font(15), .foregroundColor: Self.label])
            let prefix = (shown as NSString).range(of: "No sound")
            if prefix.location != NSNotFound { line.addAttributes([.font: Self.font(15, medium: true), .foregroundColor: Self.text], range: prefix) }
            drawSettled(line, at: CGPoint(x: signalEnd + 10, y: center - line.size().height / 2))
        }
        drawSignal(CGRect(x: signalX, y: center - 20, width: max(8, signalEnd - signalX), height: 40))
    }
    private func drawSettled(_ value: String, rect: CGRect, size: CGFloat, align: NSTextAlignment = .left) {
        let p = NSMutableParagraphStyle(); p.alignment = align
        let fraction = reducedMotion || freeze ? 1 : max(0, min(1, (stateAge - 0.06) / 0.26))
        (value as NSString).draw(in: rect.offsetBy(dx: -4 * (1 - fraction), dy: 0), withAttributes: [
            .font: Self.font(size), .foregroundColor: Self.text.withAlphaComponent(fraction), .paragraphStyle: p])
    }
    private func drawSettled(_ value: NSAttributedString, at point: CGPoint) {
        let fraction = reducedMotion || freeze ? 1 : max(0, min(1, (stateAge - 0.06) / 0.26))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(fraction)
        value.draw(at: CGPoint(x: point.x - 4 * (1 - fraction), y: point.y))
        NSGraphicsContext.restoreGraphicsState()
    }
    private func drawSignal(_ rect: CGRect) {
        NSGraphicsContext.saveGraphicsState(); rect.clip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if state == .resting && !reducedMotion && !freeze {
            NSGraphicsContext.current?.cgContext.setAlpha(max(0, min(1, (stateAge - 0.06) / 0.26)))
        }
        let quiet = state == .needs || state == .message
        let alpha = quiet && !reducedMotion && !freeze ? 0.81 + 0.19 * sin(phase / 0.9) : 1
        let ink = (quiet ? Self.label : Self.red).withAlphaComponent(alpha)
        ink.setStroke(); ink.setFill()
        let W = rect.width, mid = rect.midY
        let path = NSBezierPath(); path.lineWidth = 3; path.lineCapStyle = .square; path.lineJoinStyle = .round
        let t = freeze || reducedMotion ? 1.7 : phase
        let live = state == .listening
        let amplitude = reducedMotion ? 0.55 : smooth
        if state == .writing {
            let q = reducedMotion || freeze ? 1 : min(1, stateAge / 0.85)
            let drawn = 1 - pow(1 - q, 3)
            CGRect(x: rect.minX, y: rect.minY, width: W * drawn, height: rect.height).clip()
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x / 180 * W, y: rect.minY + y / 36 * 40) }
            path.move(to: point(2, 22)); path.line(to: point(8, 22))
            var x: CGFloat = 8
            for h: CGFloat in [18, 13, 9, 5, 2] {
                // SVG quadratic curve converted exactly to a cubic curve.
                for direction: CGFloat in [-1, 1] {
                    path.curve(to: point(x + 12, 22), controlPoint1: point(x + 4, 22 + direction * h * 2 / 3), controlPoint2: point(x + 8, 22 + direction * h * 2 / 3))
                    x += 12
                }
            }
            path.line(to: point(178, 22)); path.stroke(); return
        }
        if state == .message || style == "pen" || style == "tape" {
            for i in 0...Int(W) {
                let x = CGFloat(i), u = x / W * 180
                var offset: CGFloat = 0
                if live {
                    if style == "tape" {
                        let index = min(history.count - 1, Int(x / W * CGFloat(history.count - 1)))
                        let level = reducedMotion ? 0.55 : history[index]
                        offset = (sin(u * 0.32 + t * 2) * 0.65 + sin(u * 0.15 + t * 1.4) * 0.35) * 13 * level
                    } else {
                        let envelope = 0.15 + 0.85 * pow(max(0, sin(u / 180 * .pi)), 0.8)
                        offset = (sin(u * 0.21 - t * 3) * 0.73 + sin(u * 0.43 + t) * 0.27) * 14 * envelope * amplitude
                    }
                }
                let point = CGPoint(x: rect.minX + x, y: mid + offset)
                i == 0 ? path.move(to: point) : path.line(to: point)
            }
            if !live { path.lineCapStyle = .butt }
            path.stroke()
        } else if style == "dot" {
            let radius: CGFloat = quiet ? 6 : live ? 5.5 + 3.3 * amplitude : 5
            let dot = NSBezierPath(ovalIn: CGRect(x: rect.midX - radius, y: mid - radius, width: radius * 2, height: radius * 2))
            if quiet { dot.lineWidth = 3; dot.stroke() } else { dot.fill() }
        } else {
            let middle = style == "bars", count = max(3, Int((W / (middle ? 9.5 : 9)).rounded()))
            for i in 0..<count {
                let position = CGFloat(i) / CGFloat(count - 1)
                let level = reducedMotion ? 0.55 : history[max(0, history.count - 1 - (middle ? abs(i - count / 2) * 2 : count - 1 - i))]
                let calm: CGFloat = middle ? 9 + 7 * sin(position * .pi) : [8, 12, 9, 14, 10, 8, 13, 9][i % 8]
                let height = quiet ? 9 : live ? max(8, min(30, 8 + level * 22 * (middle ? 0.4 + 0.6 * sin(position * .pi) : 1))) : calm
                CGRect(x: rect.minX + (CGFloat(i) + 0.5) * W / CGFloat(count) - 2,
                       y: middle ? mid - height / 2 : rect.maxY - 6 - height, width: 4, height: height).fill()
            }
        }
    }

    static func drawIcon(_ name: String, in rect: CGRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState(); defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = AffineTransform(translationByX: rect.minX, byY: rect.minY)
        let t = NSAffineTransform(transform: transform); t.concat()
        let scale = NSAffineTransform(); scale.scaleX(by: rect.width / 24, yBy: rect.height / 24); scale.concat()
        let p = NSBezierPath(); p.lineWidth = name == "check" ? 2.2 : 1.8; p.lineCapStyle = .square
        func line(_ points: [(CGFloat, CGFloat)]) {
            for (i, pt) in points.enumerated() { if i == 0 { p.move(to: CGPoint(x: pt.0, y: pt.1)) } else { p.line(to: CGPoint(x: pt.0, y: pt.1)) } }
        }
        switch name {
        case "mic", "mic-off":
            p.appendRoundedRect(CGRect(x: 9, y: 2, width: 6, height: 13), xRadius: 3, yRadius: 3)
            p.move(to: CGPoint(x: 6, y: 10)); p.line(to: CGPoint(x: 6, y: 12))
            p.curve(to: CGPoint(x: 18, y: 12), controlPoint1: CGPoint(x: 6, y: 20), controlPoint2: CGPoint(x: 18, y: 20))
            p.line(to: CGPoint(x: 18, y: 10)); line([(12,18),(12,22)]); line([(8,22),(16,22)])
        case "check": line([(4.8,12),(9.6,16.8),(19.2,6)])
        case "x": line([(6,6),(18,18)]); line([(18,6),(6,18)])
        case "up": line([(6,14.4),(12,8.4),(18,14.4)])
        case "down": line([(6,9.6),(12,15.6),(18,9.6)])
        case "paste": line([(8.4,6),(4.8,6),(4.8,20.4),(19.2,20.4),(19.2,6),(15.6,6)]); p.appendRect(CGRect(x: 8.4, y: 3.6, width: 7.2, height: 4.8)); line([(8.4,12),(15.6,12)]); line([(8.4,15.6),(13.2,15.6)])
        case "notes": p.appendRect(CGRect(x: 4.8, y: 3.6, width: 14.4, height: 16.8)); line([(8.4,8.4),(15.6,8.4)]); line([(8.4,12),(15.6,12)]); line([(8.4,15.6),(12,15.6)])
        case "settings": line([(3.6,7.2),(20.4,7.2)]); line([(3.6,16.8),(20.4,16.8)]); line([(8.4,3.6),(8.4,10.8)]); line([(15.6,13.2),(15.6,20.4)])
        default: break
        }
        color.setStroke(); p.stroke()
        if name == "mic-off" {
            let slash = NSBezierPath(); slash.move(to: CGPoint(x: 4, y: 2)); slash.line(to: CGPoint(x: 21, y: 21))
            slash.lineWidth = 5; surface.setStroke(); slash.stroke()
            slash.lineWidth = 1.8; color.setStroke(); slash.stroke()
        }
    }
}

@MainActor
private final class BarButton: NSButton {
    var hint = "", icon = ""
    var primary = false, selected = false
    var run: () -> Void = {}
    private var hovered = false
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame); isBordered = false; target = self; action = #selector(activate)
        setButtonType(.momentaryChange)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func activate() { run() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        if selected || (isEnabled && (hovered || isHighlighted)) { TalkingBarView.dock.setFill(); bounds.fill() }
        let ink = isEnabled ? (primary ? TalkingBarView.text : TalkingBarView.body) : TalkingBarView.label.withAlphaComponent(0.45)
        if title.isEmpty {
            TalkingBarView.drawIcon(icon, in: CGRect(x: (bounds.width - 18) / 2, y: (bounds.height - 18) / 2, width: 18, height: 18), color: TalkingBarView.text)
        } else {
            if !icon.isEmpty { TalkingBarView.drawIcon(icon, in: CGRect(x: 9, y: (bounds.height - 16) / 2, width: 16, height: 16), color: ink) }
            let font = TalkingBarView.font(14, medium: primary)
            let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: ink])
            text.draw(at: CGPoint(x: icon.isEmpty ? 12 : 34, y: (bounds.height - text.size().height) / 2))
            let hint = NSAttributedString(string: hint, attributes: [.font: TalkingBarView.font(14), .foregroundColor: isEnabled ? TalkingBarView.label : ink])
            hint.draw(at: CGPoint(x: bounds.width - hint.size().width - 9, y: (bounds.height - hint.size().height) / 2))
        }
        if window?.firstResponder === self { TalkingBarView.label.setStroke(); let p = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1)); p.lineWidth = 1; p.stroke() }
    }
}
