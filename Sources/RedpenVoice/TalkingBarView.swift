import AppKit
import CoreText
import VoiceCore

/// Native design trial. The small Voice mark expands without replacing recording or recovery callbacks.
@MainActor
final class TalkingBarView: NSView {
    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
    static var surface: NSColor { VoiceAppearance.selection == "colour" ? color(0xC83229) : Ink.color(.paper) }
    static var dock: NSColor { VoiceAppearance.selection == "colour" ? color(0xB62620) : Ink.color(.raised) }
    static var border: NSColor { VoiceAppearance.selection == "colour" ? color(0xFFB4AA) : Ink.color(.border) }
    static var text: NSColor { Ink.color(.text) }
    static var body: NSColor { VoiceAppearance.selection == "colour" ? .white : Ink.color(.mid) }
    static var label: NSColor { VoiceAppearance.selection == "colour" ? .white : Ink.color(.mid) }
    static var red: NSColor { VoiceAppearance.selection == "colour" ? .white : Ink.color(.red) }
    static func font(_ size: CGFloat, medium: Bool = false) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: medium ? .medium : .regular)
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
    var small = false
    var smallNeedsMessage = false
    var showTimer = false
    var dragged = false
    var tucked = false
    var recordingActive: Bool { state == .listening || (state == .needs && canKeepBar) }
    var hasRecordingControls: Bool { state == .listening || state == .writing || (state == .needs && canKeepBar) }
    var compact: Bool { false }
    var shownMessage: String {
        // Count-only progress belongs in the small mark. Actual live words and safety notices remain visible.
        if state == .listening && message.range(of: #"^(\d+ words?|Hands-free · (\d+ words? · )?tap .+ to stop)$"#, options: .regularExpression) != nil { return "" }
        return message
    }
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
    var onReveal: (Bool) -> Void = { _ in }
    private var buttons: [BarButton] = []
    private var dragStart: CGPoint?
    private var dragOrigin = CGPoint.zero
    private var dragSize = CGSize.zero
    private var pointerWasTucked = false
    private var moved = false
    private var gripPressed = false
    private var hoverGrip = false
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var railHeight: CGFloat { tucked ? 44 : (showTimer || state == .writing) && !menuOpen ? 38 : 48 }
    private func choiceFrames(width: CGFloat) -> [CGRect] {
        var x: CGFloat = 16, y: CGFloat = 0
        return choices.map { title in
            let w = min(max(28, width - 32), ceil((title as NSString).size(withAttributes: [.font: Self.font(14)]).width) + 24)
            if x > 16 && x + w > width - 16 { x = 16; y += 36 }
            defer { x += w + 8 }
            return CGRect(x: x, y: y, width: w, height: 28)
        }
    }
    private var choiceHeight: CGFloat { choiceFrames(width: bounds.width).last.map { $0.maxY + 8 } ?? 0 }
    var messageFrame: CGRect {
        CGRect(x: 16, y: 10, width: max(0, bounds.width - 32),
               height: max(0, bounds.height - railHeight - choiceHeight - 16))
    }
    var detailHeight: CGFloat {
        let rect = (shownMessage as NSString).boundingRect(with: NSSize(width: max(28, bounds.width - 32), height: 2000),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: Self.font(15)])
        return (shownMessage.isEmpty ? 0 : ceil(rect.height) + 20) + choiceHeight
    }
    func desiredSize(maxWidth: CGFloat) -> CGSize {
        var size = TrialBarPlacement.size(timer: showTimer, dragged: dragged, expanded: menuOpen && hasRecordingControls, tucked: tucked)
        if state == .writing && !menuOpen { size = CGSize(width: 112, height: 38) }
        if state == .message || state == .needs { size.width = max(size.width, 248) }
        if !shownMessage.isEmpty || !choices.isEmpty {
            let messageWidth = min(480, (shownMessage as NSString).size(withAttributes: [.font: Self.font(15)]).width + 32)
            let choicesWidth = choices.reduce(CGFloat(24)) { width, title in
                width + ceil((title as NSString).size(withAttributes: [.font: Self.font(14)]).width) + 32
            }
            size.width = min(maxWidth, max(size.width, messageWidth, min(480, choicesWidth)))
            let old = frame.size
            setFrameSize(NSSize(width: size.width, height: old.height))
            size.height += detailHeight
            setFrameSize(old)
        }
        size.width = min(maxWidth, size.width)
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
        if menuOpen && hasRecordingControls {
            button("Finish", "", "", "finish", CGRect(x: 7, y: railY + 7, width: 72, height: 32), enabled: canFinish, primary: true)
            buttons.last?.selected = true
            button("Cancel", "", "", "cancel", CGRect(x: bounds.width - 71, y: railY + 7, width: 64, height: 32), enabled: canCancel)
        }
        for (index, rect) in choiceFrames(width: bounds.width).enumerated() {
            button(choices[index], "", "", "choice\(index)", rect.offsetBy(dx: 0, dy: railY - choiceHeight))
            buttons.last?.selected = true
        }
        setAccessibilityElement(true)
        setAccessibilityRole(menuOpen || !choices.isEmpty || state == .message || state == .needs ? .group : .button)
        setAccessibilityLabel(tucked ? "Reveal Voice" : recordingActive ? "Recording. Show Finish and Cancel" : state == .resting ? "Start dictation" : state.rawValue.capitalized)
        setAccessibilityValue(shownMessage.isEmpty ? (showTimer ? "\(seconds) seconds" : "") : shownMessage)
        needsDisplay = true
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        subviews.forEach { $0.needsDisplay = true }
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
    override func mouseEntered(with event: NSEvent) {
        if tucked { onReveal(true) }
    }
    override func mouseExited(with event: NSEvent) {
        hoverGrip = false; needsDisplay = true
        if dragStart == nil && state == .resting { onReveal(false) }
    }
    override func rightMouseDown(with event: NSEvent) {
        onAction("availability")
        let menu = NSMenu()
        menu.autoenablesItems = false
        var rows: [(String, String, Bool)] = []
        if state == .resting { rows.append(("Dictate", "start", true)) }
        else if state == .listening || state == .needs || state == .writing {
            rows += [("Finish", "finish", canFinish), ("Cancel", "cancel", canCancel)]
        }
        rows += [("Paste last", "paste", canPaste), ("Meeting notes", "notes", true),
                 ("Settings", "settings", true), ("Centre again", "centre", true)]
        for row in rows {
            let item = NSMenuItem(title: row.0, action: #selector(contextAction(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = row.1; item.isEnabled = row.2; menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    @objc private func contextAction(_ sender: NSMenuItem) {
        if let action = sender.representedObject as? String { onAction(action) }
    }
    override func mouseDown(with event: NSEvent) {
        beginPointer(at: NSEvent.mouseLocation, local: convert(event.locationInWindow, from: nil))
    }
    // Native events and passive checks use the same click/drag classifier.
    func beginPointer(at point: CGPoint, local: CGPoint) {
        dragStart = point; dragOrigin = window?.frame.origin ?? .zero; dragSize = window?.frame.size ?? bounds.size; moved = false
        pointerWasTucked = tucked
        gripPressed = CGRect(x: 8, y: bounds.height - railHeight, width: 24, height: railHeight).contains(local)
    }
    override func mouseDragged(with event: NSEvent) {
        movePointer(to: NSEvent.mouseLocation)
    }
    func movePointer(to now: CGPoint) {
        guard let start = dragStart else { return }
        let dx = now.x - start.x, dy = now.y - start.y
        if abs(dx) + abs(dy) > 3 { moved = true }
        if moved {
            NSCursor.closedHand.set()
            let size = window?.frame.size ?? dragSize
            onDrag(CGPoint(x: dragOrigin.x + dx + (dragSize.width - size.width) / 2,
                           y: dragOrigin.y + dy + (dragSize.height - size.height) / 2), false)
        }
    }
    override func mouseUp(with event: NSEvent) { endPointer() }
    func endPointer() {
        guard dragStart != nil else { return }
        dragStart = nil
        if moved { onDrag(window?.frame.origin ?? dragOrigin, true) }
        else if pointerWasTucked { onAction("reveal") }
        else if recordingActive { onAction("options") }
        else if state == .resting { onAction("start") }
        // A click on a notice clears it, like Esc. Listening ignores it (dismissal never stops a recording).
        else if state == .message || state == .done || state == .needs { onAction("dismiss") }
        NSCursor.openHand.set()
    }
    override func accessibilityPerformPress() -> Bool {
        if tucked { onAction("reveal") }
        else if state == .resting { onAction("start") }
        else if hasRecordingControls { onAction("options") }
        else { return false }
        return true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onAction("dismiss") }
        else if event.keyCode == 36 || event.keyCode == 49 { onAction(tucked ? "reveal" : state == .resting ? "start" : "options") }
        else { onAction("dismiss") }
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.surface.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        drawMarkSurface()
    }
    private func drawMarkSurface() {
        Self.border.setStroke()
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        outline.lineWidth = 1; outline.stroke()
        if tucked {
            Self.label.setFill(); CGRect(x: 4, y: (bounds.height - 18) / 2, width: 2, height: 18).fill()
            return
        }
        let railY = bounds.height - railHeight, centerY = railY + railHeight / 2
        if !shownMessage.isEmpty {
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byWordWrapping
            (shownMessage as NSString).draw(in: messageFrame,
                withAttributes: [.font: Self.font(15), .foregroundColor: Self.body, .paragraphStyle: paragraph])
        }
        if state == .done {
            Self.drawIcon("check", in: CGRect(x: bounds.midX - 10, y: centerY - 10, width: 20, height: 20), color: Self.text)
            return
        }
        if state == .writing && !menuOpen {
            let progress = NSBezierPath(ovalIn: CGRect(x: 12, y: centerY - 5, width: 10, height: 10))
            progress.lineWidth = 2; Self.label.setStroke(); progress.stroke()
            Self.red.setFill()
            let angle = freeze || reducedMotion ? 0 : phase * 3
            CGRect(x: 15 + 4 * cos(angle), y: centerY - 2 + 4 * sin(angle), width: 3, height: 3).fill()
            ("Writing" as NSString).draw(at: CGPoint(x: 31, y: centerY - 8), withAttributes: [
                .font: Self.font(13), .foregroundColor: Self.text])
            return
        }
        let timed = showTimer && !menuOpen && state != .message && state != .needs
        let markX: CGFloat = menuOpen ? bounds.midX - 11 : timed ? 13 : bounds.midX - 11
        let ink = state == .resting || (state == .message || state == .needs) && !recordingActive ? Self.label : timed ? Self.text : Self.red
        ink.setFill()
        for i in 0..<3 {
            let base: CGFloat = i == 1 ? 20 : 8
            let motion = recordingActive && !freeze && !reducedMotion ? 0.8 + 0.32 * abs(sin(phase * 2 + Double(i))) : 1
            let height = base * motion
            CGRect(x: markX + CGFloat(i) * 9, y: centerY - height / 2, width: 3, height: height).fill()
        }
        if timed || (menuOpen && hasRecordingControls) {
            let clock = "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
            (clock as NSString).draw(at: CGPoint(x: menuOpen ? bounds.midX + 19 : 43, y: centerY - 7), withAttributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: Self.label])
            if timed && state != .resting {
                Self.red.setFill(); CGRect(x: bounds.width - 7, y: centerY - 10, width: 3, height: 20).fill()
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
