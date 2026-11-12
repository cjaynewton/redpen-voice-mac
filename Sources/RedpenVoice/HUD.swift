import AppKit
import ApplicationServices
import VoiceCore
import QuartzCore

/// One nonactivating piece for recording, writing, messages and the user's options.
@MainActor
final class HUD {
    var style = "pen" { didSet { box.style = style; if panel.isVisible { layout() } } }
    var micName = ""
    var traceID = 0
    var onStart: () -> Void = {}
    var onFinish: () -> Void = {}
    var onCancel: () -> Void = {}
    var onPaste: () -> Void = {}
    var onNotes: () -> Void = {}
    var onSettings: () -> Void = {}
    var onKeepBarOnScreen: (Bool) -> Void = { _ in }
    var keepBarOnScreen = false {
        didSet {
            box.keepBarOnScreen = keepBarOnScreen
            if oldValue != keepBarOnScreen && box.state == .resting { rest() }
        }
    }
    /// Also tracked by offscreen checks, where ordering a real desktop window is deliberately disabled.
    private var wantsVisible = false
    var onDismissPopup: () -> Bool = { false }
    var menuAvailability: () -> (finish: Bool, cancel: Bool, paste: Bool) = { (true, true, true) }
    var talkKey = "Fn" { didSet { box.talkKey = talkKey } }
    private let panel: TalkingBarPanel
    private let box = TalkingBarView(frame: .zero)
    private var hideAt: DispatchWorkItem?
    private var tick: Timer?
    private var started = Date(), changed = Date(), lastTick = Date()
    private var captionText = ""
    private var typingStopped = false
    var isTypingStopped: Bool { typingStopped }
    private var dictationScreen: NSScreen?
    private var startBox: CGRect?
    private var wordAction: ((Bool) -> Void)?
    private var waitAction: ((Bool) -> Void)?
    private var dismissedQuestion = false
    private var latest: CGFloat = 0, silentFor = 0.0
    private var listeningActive = false
    private var monitors: [Any] = []
    private var screenWatch: NSObjectProtocol?
    private var anchor: CGPoint?
    private let defaults: UserDefaults
    private let observesEvents: Bool
    private var frozen = false
    private static let positionKey = "talkingBarPositionR3"

    /// Key-down must not wait for Accessibility. Refine this pointer choice when the bounded snapshot returns.
    func flushInitialDisplay() {
        panel.displayIfNeeded()
        CATransaction.flush()
    }

    func captureImmediately() {
        let screens = NSScreen.screens
        startBox = nil
        dictationScreen = screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? screens.first
    }

    func refineCapture(textBox: CGRect?, window: CGRect?) {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return }
        startBox = textBox.map { BarScreen.fromAccessibility($0, primaryTop: primary.frame.maxY) }
        let choice = BarScreen.choose(screens: screens.map(\.frame), textBox: startBox,
                                     window: window.map { BarScreen.fromAccessibility($0, primaryTop: primary.frame.maxY) },
                                     pointer: NSEvent.mouseLocation)
        dictationScreen = choice.map { screens[$0.index] }
        if panel.isVisible { place() }
    }

    func captureScreen(textBox: CGRect?) {
        let screens = NSScreen.screens
        startBox = nil
        guard let primary = screens.first else { dictationScreen = nil; return }
        startBox = textBox.map { BarScreen.fromAccessibility($0, primaryTop: primary.frame.maxY) }
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

    init(defaults: UserDefaults = .standard, observesEvents: Bool = true) {
        self.defaults = defaults; self.observesEvents = observesEvents
        panel = TalkingBarPanel(contentRect: NSRect(x: 0, y: 0, width: 182, height: 40),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        TalkingBarView.registerFonts()
        panel.level = .statusBar; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = true; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        box.frame = panel.contentView!.bounds; box.autoresizingMask = [.width, .height]
        panel.contentView = box
        if let saved = defaults.array(forKey: Self.positionKey) as? [Double], saved.count == 2,
           saved.allSatisfy({ $0.isFinite }) { anchor = CGPoint(x: saved[0], y: saved[1]) }
        box.onAction = { [weak self] in self?.perform($0) }
        box.onDrag = { [weak self] point, ended in
            guard let self else { return }
            self.box.menuOpen = false
            self.anchor = point
            self.layout(animated: false)
            self.anchor = self.panel.frame.origin
            if ended { self.persistPosition() }
        }
        if observesEvents {
            let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
                MainActor.assumeIsolated { self?.outside(e) }
            }) { monitors.append(m) }
            if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
                var swallowed = false
                MainActor.assumeIsolated {
                    // Mouse input delivered locally belongs to Voice, including its other windows and menus.
                    if e.type == .keyDown, e.window !== self?.panel { self?.outside(e) }
                    else if e.type == .keyDown, e.keyCode == 53 { self?.dismissExtras(); swallowed = true }
                }
                return swallowed ? nil : e
            }) { monitors.append(m) }
            screenWatch = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.layout(animated: false)
                        self.anchor = self.panel.frame.origin; self.persistPosition()
                    }
                }
        }
    }

    /// Idle is hidden by default. The optional resting tab never counts as a pending warning/question.
    func rest() {
        hideAt?.cancel(); hideAt = nil; tick?.invalidate(); tick = nil
        listeningActive = false
        typingStopped = false; captionText = ""; wordAction = nil; waitAction = nil; dismissedQuestion = false
        box.message = ""; box.choices = []; box.menuOpen = false; box.success = false
        if keepBarOnScreen { transition(.resting) }
        else {
            box.state = .resting; box.stateAge = 0
            wantsVisible = false; panel.orderOut(nil)
        }
    }

    func show(_ text: String, level: Bool, ok: Bool = false) {
        if observesEvents { StartTrace.note(.barRequested, gesture: traceID) }
        hideAt?.cancel(); hideAt = nil
        typingStopped = false; wordAction = nil; waitAction = nil; dismissedQuestion = false
        box.choices = []; box.menuOpen = false; box.success = ok; box.message = text
        listeningActive = level
        if level {
            started = Date(); captionText = text; box.words = 0; box.seconds = 0
            latest = 0; box.smooth = 0; silentFor = 0; box.history = .init(repeating: 0, count: 90)
        }
        transition(level ? .listening : text.hasPrefix("No sound from ") ? .needs : ok ? .done : .message)
        if observesEvents { StartTrace.note(.barOrdered, gesture: traceID, value: panel.isVisible ? 1 : 0) }
    }

    func writing(_ note: String = "") {
        listeningActive = false
        wordAction = nil; waitAction = nil; dismissedQuestion = false; box.choices = []
        hideAt?.cancel(); box.menuOpen = false
        box.message = note == TalkingWords.writingAfterStop ? "" : note; box.success = false
        transition(.writing)
    }
    func level(_ v: Float) { latest = v.isFinite ? min(1, max(0, CGFloat(v))) : 0 }

    func caption(_ text: String) {
        guard !typingStopped else { return }
        captionText = TalkingWords.tail(text)
        // Existing count messages carry their actual count; raw captions are counted before their tail is cut.
        if let range = text.range(of: #"\b[0-9]+ words?\b"#, options: .regularExpression),
           let count = Int(text[range].split(separator: " ").first ?? "") { box.words = count }
        else if !text.hasPrefix("Hands-free") { box.words = TalkingWords.words(text) }
        guard box.state == .listening else { return }
        box.message = captionText; layout()
    }
    func listeningCaption(_ text: String) {
        guard !typingStopped else { return }
        listen(); caption(text)
    }
    func stoppedTyping(_ line: String) {
        if !typingStopped { listen() }
        typingStopped = true; captionText = ""
        if let range = line.range(of: #"\b[0-9]+ words?\b"#, options: .regularExpression),
           let count = Int(line[range].split(separator: " ").first ?? "") { box.words = count }
        guard box.state == .listening else { return }
        box.message = ""; layout()
    }

    /// Resume the existing listening bar without resetting its timer or drawing.
    func resumeTyping(_ line: String) {
        typingStopped = false
        listeningCaption(line)
    }
    private func listen() {
        if box.state != .listening && box.state != .needs { show("", level: true) }
    }

    func flash(_ text: String, ok: Bool = false, for seconds: Double = 1.2) {
        show(text, level: false, ok: ok)
        schedule(after: seconds) { $0.rest() }
    }
    /// Existing successful writing completions call hide(). Keep the tick in the same piece, then return to rest.
    func hide() {
        if box.state == .writing {
            box.message = ""; box.choices = []; box.menuOpen = false
            transition(.done); schedule(after: 0.75) { $0.rest() }
        } else { rest() }
    }
    @discardableResult
    func suggest(_ word: String, action: @escaping (Bool) -> Void) -> Bool {
        guard box.state == .resting, !box.menuOpen else { return false }
        show("Keep hearing “\(word)”. Add it to your words?", level: false)
        wordAction = action; box.choices = ["Add", "Not now"]; layout()
        schedule(after: 12) { $0.rest() }
        return true
    }
    func hideSuggestion() { if wordAction != nil { rest() } }
    func ask(_ text: String, yes: String, no: String, action: @escaping (Bool) -> Void) {
        show(text, level: false); waitAction = action; box.choices = [yes, no]; layout()
    }
    func stopAsking() { if waitAction != nil || dismissedQuestion { rest() } }
    var isShowing: Bool { dismissedQuestion || (panel.isVisible && box.state != .resting) }

    /// Dismissal never answers a recovery question, cancels recording, or consumes another app's typing.
    @discardableResult
    func dismissExtras() -> Bool {
        let popupClosed = onDismissPopup()
        if box.menuOpen { box.menuOpen = false; layout(); return true }
        if box.state == .message || (box.state == .needs && !listeningActive) {
            let waiting = waitAction != nil
            rest(); dismissedQuestion = waiting
            return true
        }
        return popupClosed
    }
    private func outside(_ event: NSEvent) {
        if event.type != .keyDown,
           OwnWindowClicks.shared.contains(event.type == .leftMouseDown ? .left : event.type == .rightMouseDown ? .right : .other,
                                           at: event.timestamp) { return }
        if let cg = event.cgEvent, VoiceEvents.isOwn(pid: cg.getIntegerValueField(.eventSourceUnixProcessID),
            userData: cg.getIntegerValueField(.eventSourceUserData)) { return }
        if event.type == .keyDown {
            // Escape has a dedicated route through HoldKey so closing options cannot count toward Esc twice.
            if event.keyCode == 53 { return }
            dismissExtras()
        } else if !panel.frame.contains(NSEvent.mouseLocation) { dismissExtras() }
    }
    private func perform(_ action: String) {
        if action == "options" {
            let available = menuAvailability()
            box.canFinish = available.finish; box.canCancel = available.cancel; box.canPaste = available.paste
            box.menuOpen.toggle(); layout(); return
        }
        if action == "dismiss" { dismissExtras(); return }
        if action == "keepBar", listeningActive {
            keepBarOnScreen.toggle(); onKeepBarOnScreen(keepBarOnScreen)
            layout(); return
        }
        box.menuOpen = false
        if action.hasPrefix("choice") {
            let callback = wordAction ?? waitAction
            rest(); callback?(action == "choice0"); return
        }
        layout()
        switch action {
        case "start": onStart()
        case "finish": if box.canFinish { onFinish() }
        case "cancel": if box.canCancel { onCancel() }
        case "paste": if box.canPaste { onPaste() }
        case "notes": onNotes()
        case "settings": onSettings()
        default: break
        }
    }
    private func transition(_ state: TalkingBar.State) {
        box.state = state; changed = Date(); box.stateAge = 0
        wantsVisible = true
        box.style = style; box.reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        layout(); if observesEvents { panel.orderFrontRegardless() }
        tick?.invalidate(); tick = nil
        if state != .message && (state != .resting || !box.reducedMotion) {
            lastTick = Date()
            let t = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.frame() }
            }
            RunLoop.main.add(t, forMode: .common); tick = t
        }
    }
    private func frame() {
        guard !frozen else { return }
        let now = Date(), delta = min(0.2, now.timeIntervalSince(lastTick)); lastTick = now
        box.stateAge = now.timeIntervalSince(changed); box.phase += delta
        box.reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        box.smooth += (latest - box.smooth) * 0.35
        box.history.removeFirst(); box.history.append(box.smooth)
        if listeningActive && (box.state == .listening || box.state == .needs) {
            box.seconds = max(0, Int(now.timeIntervalSince(started)))
            silentFor = latest < 0.02 ? silentFor + delta : 0
            let silent = silentFor > 1.5 && !micName.isEmpty
            if silent && box.state == .listening {
                changed = now; box.stateAge = 0
                box.state = .needs; box.message = "No sound from \(micName)"; layout()
            } else if !silent && box.state == .needs && !box.success {
                changed = now; box.stateAge = 0
                box.state = .listening; box.message = captionText; layout()
            }
        }
        box.needsDisplay = true
        if box.state == .resting && box.stateAge >= 0.32 { tick?.invalidate(); tick = nil }
    }
    private func schedule(after seconds: Double, action: @escaping (HUD) -> Void) {
        hideAt?.cancel()
        let work = DispatchWorkItem { [weak self] in if let self { action(self) } }
        hideAt = work; DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    private func persistPosition() {
        guard let anchor else { return }
        defaults.set([Double(anchor.x), Double(anchor.y)], forKey: Self.positionKey)
    }
    private func layout(animated: Bool = true) {
        let screens = NSScreen.screens
        let screen = screens.first(where: { $0.frame.contains(anchor ?? panel.frame.origin) })
            ?? dictationScreen.flatMap { old in screens.first { $0 == old } } ?? screens.first
        let maxWidth = max(182, (screen?.visibleFrame.width ?? 800) - 16)
        box.canKeepBar = listeningActive
        let size = box.desiredSize(maxWidth: maxWidth)
        let origin = anchor ?? screen.map { BarScreen.origin(visible: $0.visibleFrame, size: size, avoiding: startBox) } ?? .zero
        let fitted = TalkingBar.fitted(origin: origin, size: size, screens: screens.map(\.visibleFrame))
        if anchor == nil { anchor = fitted.origin }
        let animate = animated && panel.isVisible && !box.reducedMotion && !frozen
        panel.setFrame(fitted, display: true, animate: animate)
        box.rebuildControls()
        panel.invalidateShadow()
    }
    private func place() { layout() }

    /// Renders the real native view at 2x without capturing the user's desktop or starting capture services.
    func snapshot(to url: URL, hidden: Bool = false) {
        box.displayIfNeeded()
        let size = box.bounds.size, scale: CGFloat = 2
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return }
        NSGraphicsContext.saveGraphicsState()
        let cg = context.cgContext
        cg.clear(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
        cg.translateBy(x: 0, y: size.height * scale); cg.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        if !hidden { box.draw(box.bounds) }
        for view in box.subviews where !hidden {
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform(); transform.translateX(by: view.frame.minX, yBy: view.frame.minY); transform.concat()
            view.draw(view.bounds); NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.restoreGraphicsState()
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Isolated native checks and all approved states. No AppDelegate, microphone, typing or installed preferences.
    static func captureStates(to directory: URL) -> Int32 {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { print("Could not create screenshot directory: \(error)"); return 1 }
        let suite = "RedpenVoice.TalkingBarTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let hud = HUD(defaults: defaults, observesEvents: false)
        hud.frozen = true; hud.box.freeze = true
        var passed = 0, failed = 0
        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failed += 1; print("FAIL \(name)") }
        }
        check("Instrument Sans bundled", NSFont(name: "InstrumentSans-Regular", size: 17) != nil)
        check("Medium font bundled", NSFont(name: "InstrumentSans-Medium", size: 17) != nil)
        check("bar accepts first click without focus", hud.box.acceptsFirstMouse(for: nil))
        check("bar cannot take text focus", !hud.panel.canBecomeKey && !hud.panel.canBecomeMain)
        hud.onDismissPopup = { true }
        check("Esc on an external popup is handled", hud.dismissExtras())
        hud.onDismissPopup = { false }
        let control = HoldKey()
        var callbacks: [String] = []
        control.canBegin = { true }; control.onDown = { callbacks.append("start"); return true }
        control.onConfirm = { callbacks.append("confirm") }; control.onHandsFree = { callbacks.append("handsFree") }
        control.startFromBar(); control.startFromBar()
        check("mouse entry shares callbacks exactly once", callbacks == ["start", "confirm", "handsFree"] && control.handsFree)
        control.stopFromEnter(); check("Finish clears mouse hands-free", !control.handsFree)
        let rejected = HoldKey(); rejected.onDown = { false }
        rejected.onConfirm = { callbacks.append("unexpected confirm") }
        rejected.startFromBar()
        check("failed start cannot stay latched", !rejected.handsFree && callbacks.count == 3)
        let blocked = HoldKey(); blocked.canBegin = { false }; blocked.onDown = { callbacks.append("unexpected start"); return true }
        blocked.startFromBar(); check("busy app cannot start from rail", !blocked.handsFree && callbacks.count == 3)
        var records: [[String: Any]] = []
        func capture(_ name: String) {
            hud.layout(animated: false)
            let path = directory.appendingPathComponent(name + ".png")
            hud.snapshot(to: path)
            let size = hud.panel.frame.size
            let image = NSBitmapImageRep(data: (try? Data(contentsOf: path)) ?? Data())
            check(name + " PNG size", image?.pixelsWide == Int(size.width * 2) && image?.pixelsHigh == Int(size.height * 2))
            check(name + " controls fit", hud.box.subviews.allSatisfy { hud.box.bounds.contains($0.frame) })
            if hud.box.menuOpen {
                let separator = CGRect(x: 16, y: hud.box.menuSeparatorY, width: size.width - 32, height: 1)
                check(name + " divider clears every menu row", hud.box.subviews.allSatisfy { !$0.frame.intersects(separator) })
            }
            if let image {
                let corner = image.colorAt(x: 0, y: image.pixelsHigh - 1)
                check(name + " square opaque corners", (corner?.alphaComponent ?? 0) > 0.99)
                // Compare encoded PNG component values. Converting colorAt's calibrated wrapper again
                // applies a second transfer curve even though this bitmap is already tagged sRGB.
                let surface = image.colorAt(x: 1, y: 4)
                check(name + " lighter grey surface", abs((surface?.redComponent ?? 0) - 37.0 / 255) < 0.01
                    && abs((surface?.greenComponent ?? 0) - 39.0 / 255) < 0.01
                    && abs((surface?.blueComponent ?? 0) - 43.0 / 255) < 0.01)
                var outsideRed = false
                let railTop = image.pixelsHigh - Int(hud.box.railHeight * 2)
                for y in stride(from: 0, to: image.pixelsHigh, by: 2) {
                    for x in stride(from: 0, to: image.pixelsWide, by: 2) where x < 80 || x >= image.pixelsWide - 100 || y < railTop {
                        if let color = image.colorAt(x: x, y: y),
                           color.redComponent > 0.5, color.redComponent > color.greenComponent * 1.5,
                           color.redComponent > color.blueComponent * 1.5 { outsideRed = true }
                    }
                }
                check(name + " red only in signal area", !outsideRed)
            }
            records.append(["file": path.lastPathComponent, "width": size.width, "height": size.height, "scale": 2])
        }
        func captureHidden(_ name: String) {
            hud.layout(animated: false)
            let path = directory.appendingPathComponent(name + ".png")
            hud.snapshot(to: path, hidden: !hud.wantsVisible)
            let image = NSBitmapImageRep(data: (try? Data(contentsOf: path)) ?? Data())
            check(name + " has no bar", !hud.wantsVisible && !hud.panel.isVisible && hud.tick == nil)
            check(name + " transparent capture", image?.colorAt(x: 5, y: 5)?.alphaComponent == 0)
            records.append(["file": path.lastPathComponent, "visible": hud.wantsVisible, "scale": 2])
        }
        hud.rest(); captureHidden("r3-default-idle-hidden")
        check("idle option defaults off", !hud.keepBarOnScreen && Config().keepBarOnScreen != true)
        var savedConfig = Config(); savedConfig.keepBarOnScreen = true
        let savedData = try! JSONEncoder().encode(savedConfig)
        let configCopy = try! JSONDecoder().decode(Config.self, from: savedData)
        check("idle option survives config round trip", configCopy.keepBarOnScreen == true)
        var legacy = try! JSONSerialization.jsonObject(with: savedData) as! [String: Any]
        legacy.removeValue(forKey: "keepBarOnScreen")
        let legacyCopy = try! JSONDecoder().decode(Config.self, from: JSONSerialization.data(withJSONObject: legacy))
        check("old config defaults to hidden", legacyCopy.keepBarOnScreen == nil)
        hud.keepBarOnScreen = true
        for style in ["pen", "bars", "tape", "dot", "classic"] {
            hud.style = style
            for state in [TalkingBar.State.resting, .listening, .writing, .needs, .done] {
                hud.rest()
                hud.box.state = state; hud.box.stateAge = 0.3; hud.box.phase = 1.7
                hud.box.seconds = 22; hud.box.words = 52; hud.box.smooth = 0.82
                hud.box.history = (0..<90).map { 0.55 + 0.4 * sin(Double($0) * 0.7) }
                if state == .needs { hud.box.message = "No sound from Scarlett" }
                capture("r3-\(style)-\(state.rawValue)")
                let expected = TalkingBar.size(state, style: style)
                check("\(style) \(state.rawValue) approved dimensions", hud.panel.frame.size == expected)
            }
        }
        hud.style = "pen"; hud.rest(); hud.perform("options"); capture("r3-menu-resting")
        check("rest menu 236x177", hud.panel.frame.size == CGSize(width: 236, height: 177))
        check("rest menu rows", hud.box.subviews.compactMap { ($0 as? NSButton)?.title }.filter { !$0.isEmpty } == ["Dictate", "Paste last", "Meeting notes", "Settings"])
        hud.show("", level: true); hud.box.seconds = 22; hud.box.smooth = 0.82
        hud.perform("options"); capture("r3-menu-listening")
        check("live menu 314x245", hud.panel.frame.size == CGSize(width: 314, height: 245))
        check("live menu rows", hud.box.subviews.compactMap { ($0 as? NSButton)?.title }.filter { !$0.isEmpty } == ["Finish", "Cancel", "Keep bar on screen", "Paste last", "Meeting notes", "Settings"])
        var keepChoices: [Bool] = []
        hud.onKeepBarOnScreen = { keepChoices.append($0) }
        (hud.box.subviews.first { ($0 as? NSButton)?.title == "Keep bar on screen" } as? NSButton)?.performClick(nil)
        check("keep row turns off without stopping listening", !hud.keepBarOnScreen && hud.listeningActive && keepChoices == [false])
        capture("r3-menu-listening-default-off")
        hud.perform("keepBar")
        check("keep row turns on", hud.keepBarOnScreen && keepChoices == [false, true])
        hud.rest(); check("opt-in retains resting tab", hud.wantsVisible && hud.box.state == .resting)
        hud.show("", level: true); hud.perform("options")
        hud.perform("keepBar")
        var finished = 0, started = 0, pasted = 0, notes = 0, settings = 0, cancelled = 0
        hud.onFinish = { finished += 1 }; hud.onStart = { started += 1 }; hud.onPaste = { pasted += 1 }
        hud.onNotes = { notes += 1 }; hud.onSettings = { settings += 1 }; hud.onCancel = { cancelled += 1 }
        (hud.box.subviews.first { ($0 as? NSButton)?.title == "Finish" } as? NSButton)?.performClick(nil)
        check("native Finish callback once", finished == 1 && !hud.box.menuOpen)
        hud.rest(); hud.perform("options")
        (hud.box.subviews.first { ($0 as? NSButton)?.title == "Dictate" } as? NSButton)?.performClick(nil)
        check("native Dictate callback once", started == 1 && !hud.box.menuOpen)
        for action in ["paste", "notes", "settings", "cancel"] { hud.perform(action) }
        check("existing action callbacks", pasted == 1 && notes == 1 && settings == 1 && cancelled == 1)
        hud.show("", level: true); hud.perform("options"); hud.dismissExtras()
        check("Esc closes menu without cancelling", !hud.box.menuOpen && hud.box.state == .listening && cancelled == 1)
        let cgEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        cgEvent.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        cgEvent.setIntegerValueField(.eventSourceUserData, value: 0)
        let event = NSEvent(cgEvent: cgEvent)!
        hud.perform("options"); hud.outside(event)
        check("typing closes menu", !hud.box.menuOpen && hud.box.state == .listening)
        hud.caption("52 words"); hud.writing()
        check("real caption count retained", hud.box.words == 52 && hud.box.state == .writing)
        hud.hide(); check("writing completion becomes Done", hud.box.state == .done)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        check("Done hides after 750ms", hud.box.state == .resting && !hud.wantsVisible && !hud.panel.isVisible)
        captureHidden("r3-done-hidden")
        hud.writing(); hud.hide(); hud.show("New progress", level: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        check("old completion cannot hide newer progress", hud.box.state == .message && hud.box.message == "New progress")
        hud.rest(); check("rest does not block suggestions", !hud.isShowing)
        hud.flash("Saved", for: 0.01)
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        captureHidden("r3-flash-hidden")
        hud.show("Press ⌃⌥V to paste your words", level: false)
        check("paste notice stays until dismissed", hud.wantsVisible && hud.box.state == .message)
        hud.dismissExtras(); captureHidden("r3-paste-dismissed-hidden")
        var answer: Bool?
        hud.ask("These words are waiting. Copy them or throw them away?", yes: "Copy", no: "Throw away") { answer = $0 }
        capture("r3-recovery-question")
        hud.dismissExtras()
        check("dismiss never answers or reopens recovery", answer == nil && hud.dismissedQuestion && hud.isShowing)
        hud.stopAsking(); check("stopped recovery clears dismissal", !hud.isShowing)
        hud.ask("These words are waiting.", yes: "Copy", no: "Throw away") { answer = $0 }
        hud.perform("choice0"); check("recovery button preserves callback", answer == true)
        check("suggestion offered at rest", hud.suggest("Scarlett") { answer = $0 })
        capture("r3-word-suggestion"); hud.perform("choice1"); check("suggestion Not now callback", answer == false)
        let warning = "Didn't confirm all the words. Press ⌃⌥V to paste the checked text"
        hud.flash(warning, for: 30); capture("r3-warning")
        check("flash keeps full message", hud.box.message == warning)
        hud.outside(event); check("typing dismisses flash", hud.box.state == .resting)
        hud.show("Transcribing… 42%", level: false); capture("r3-progress")
        check("progress kept", hud.box.message == "Transcribing… 42%")
        hud.show("", level: true); hud.caption("Here are the actual words that were dictated into this test.")
        capture("r3-caption")
        check("raw caption counted before tail", hud.box.words == 11)
        let reason = "Typing stopped (you clicked). 52 words so far, all go in at the end."
        hud.stoppedTyping(reason); hud.caption("must not replace the reason"); capture("r3-stopped-typing")
        check("typing-stop has count but no sentence", hud.box.message.isEmpty && hud.box.words == 52 && hud.isTypingStopped && hud.box.detailHeight == 0)
        hud.writing("All your words go in now"); capture("r3-writing-note")
        check("writing after stop has no sentence", hud.box.message.isEmpty && hud.box.words == 52)
        hud.show("No sound from Scarlett", level: false); hud.frozen = false; hud.frame(); hud.frozen = true
        check("no-sound flash stays a message", hud.box.state == .needs && !hud.listeningActive)
        hud.show("", level: true); hud.micName = "Scarlett"; hud.silentFor = 2
        hud.frozen = false; hud.frame(); hud.frozen = true
        check("silence produces Needs you", hud.box.state == .needs && hud.box.message == "No sound from Scarlett")
        hud.level(0.5); hud.frozen = false; hud.frame(); hud.frozen = true
        check("audio recovers listening", hud.box.state == .listening)
        hud.show("No sound from " + String(repeating: "Long named audio interface ", count: 15), level: false)
        capture("r3-long-mic-name")
        check("long mic name wraps above rail", hud.box.needsOverflow && hud.box.detailHeight > 40)
        hud.writing(); hud.box.words = 52; hud.box.freeze = false; hud.box.reducedMotion = true; hud.box.stateAge = 0
        capture("r3-reduced-motion-writing")
        hud.box.freeze = true; hud.box.reducedMotion = false
        let beforeClick = started
        hud.keepBarOnScreen = true; hud.rest()
        let click = NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 16, y: 20), modifierFlags: [],
            timestamp: 1, windowNumber: hud.panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        hud.box.mouseDown(with: click); hud.box.mouseUp(with: click)
        check("resting rail click starts once", started == beforeClick + 1)
        hud.perform("options")
        let arrow = hud.box.subviews.first { ($0 as? NSButton)?.title == "" } as? NSButton
        check("arrow owns its hit target", hud.box.hitTest(hud.box.convert(CGPoint(x: hud.box.bounds.width - 20, y: hud.box.bounds.height - 20), to: hud.box.superview)) === arrow)
        arrow?.performClick(nil)
        check("arrow closes menu without starting", !hud.box.menuOpen && started == beforeClick + 1)
        hud.rest(); hud.menuAvailability = { (false, false, false) }; hud.perform("options")
        let pasteButton = hud.box.subviews.first { ($0 as? NSButton)?.title == "Paste last" } as? NSButton
        check("unavailable paste is disabled", pasteButton?.isEnabled == false)
        hud.perform("paste"); check("unavailable paste does not run", pasted == 1)
        hud.menuAvailability = { (true, true, true) }
        hud.rest(); let restingOrigin = hud.panel.frame.origin
        hud.perform("options")
        check("menu bottom stays fixed", hud.panel.frame.minY == restingOrigin.y)
        hud.box.onDrag(CGPoint(x: restingOrigin.x + 35, y: restingOrigin.y + 25), true)
        check("drag closes menu", !hud.box.menuOpen)
        let saved = hud.panel.frame.origin
        hud.keepBarOnScreen = false; hud.rest()
        check("hiding preserves saved position", hud.anchor == saved && !hud.wantsVisible)
        hud.show("", level: true)
        check("hidden bar returns immediately listening at saved position", hud.wantsVisible && hud.box.state == .listening && hud.panel.frame.origin == saved)
        let reopened = HUD(defaults: defaults, observesEvents: false); reopened.frozen = true; reopened.rest()
        check("new instance starts hidden", !reopened.wantsVisible && !reopened.panel.isVisible)
        reopened.show("", level: true)
        check("position restored across instances", reopened.panel.frame.origin == saved)
        // Exercise real orderOut with a review-only panel; no AppDelegate or capture services run.
        reopened.panel.orderFrontRegardless()
        check("test panel is ordered", reopened.panel.isVisible)
        reopened.rest()
        check("default idle actually orders panel out", !reopened.panel.isVisible)
        reopened.keepBarOnScreen = true; reopened.writing(); reopened.hide()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        check("opt-in Done returns to resting tab", reopened.wantsVisible && reopened.box.state == .resting)
        reopened.shutdown(); hud.shutdown(); defaults.removePersistentDomain(forName: suite)
        let result: [String: Any] = ["passed": passed, "failed": failed, "captures": records,
            "scope": "Native offscreen rendering and synthetic interactions. No recording, insertion, media or installation."]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("verification.json"))
        }
        print("Talking bar native checks: \(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }

    func shutdown() {
        hideAt?.cancel(); tick?.invalidate(); tick = nil; wantsVisible = false; panel.orderOut(nil)
        monitors.forEach(NSEvent.removeMonitor); monitors.removeAll()
        if let screenWatch { NotificationCenter.default.removeObserver(screenWatch) }; screenWatch = nil
    }
}

private final class TalkingBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.28 }
}
