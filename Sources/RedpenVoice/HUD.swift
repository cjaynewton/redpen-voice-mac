import AppKit
import ApplicationServices
import VoiceCore
import QuartzCore

/// One nonactivating piece for recording, writing, messages and the user's options.
@MainActor
final class HUD {
    var style = "pen" { didSet { box.style = style; if panel.isVisible { layout() } } }
    var onSmallTalkingBar: (Bool) -> Void = { _ in }
    var smallTalkingBar = false { didSet { box.small = smallTalkingBar; layout(animated: false) } }
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
    /// Told whenever the bar goes back to idle, however it got there (Esc, a click, a timeout, a finish).
    var onRested: () -> Void = {}
    private var stuckSince: Date?
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
    private var placements = TrialBarPlacement()
    private var dragging = false
    private var edgeRevealed = false
    private var preferenceWatches: [NSObjectProtocol] = []
    private let defaults: UserDefaults
    private let observesEvents: Bool
    private var frozen = false
    private var showTimer: Bool { defaults.bool(forKey: "VoiceTrial.showTimer") }
    private var tuckAtEdge: Bool { (defaults.object(forKey: "VoiceTrial.tuckAtEdge") as? Bool) ?? true }
    private func displayID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    private var currentScreen: NSScreen? {
        let screens = NSScreen.screens
        return dictationScreen.flatMap { old in screens.first { displayID($0) == displayID(old) } }
            ?? screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? screens.first
    }
    private var docked: Bool {
        currentScreen.map { placements.position(on: displayID($0))?.edge != nil } ?? false
    }

    /// Key-down must not wait for Accessibility. The initial screen stays fixed until the next dictation.
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
        // A late AX result cannot move a visible dictation, writing progress or recovery notice.
        if !wantsVisible || box.state == .resting {
            dictationScreen = choice.map { screens[$0.index] }
            if panel.isVisible { place() }
        }

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
        box.onAction = { [weak self] in self?.perform($0) }
        box.onReveal = { [weak self] reveal in
            guard let self else { return }
            self.edgeRevealed = reveal; self.layout(animated: false)
        }
        box.onDrag = { [weak self] point, ended in
            guard let self else { return }
            self.box.menuOpen = false
            let center = CGPoint(x: point.x + self.panel.frame.width / 2, y: point.y + self.panel.frame.height / 2)
            let screens = NSScreen.screens
            guard let screen = screens.first(where: { $0.frame.contains(center) }) ?? self.currentScreen else { return }
            self.dictationScreen = screen
            self.dragging = !ended; self.edgeRevealed = true
            self.placements.save(center: center, on: self.displayID(screen), visible: screen.visibleFrame,
                                 dock: ended)
            if ended { self.edgeRevealed = false }
            self.layout(animated: false)
        }
        for name in ["VoiceTrialBarPreferencesChanged", "VoiceAppearanceChanged", "VoiceTrialBarCentreAgain"] {
            preferenceWatches.append(NotificationCenter.default.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if note.name.rawValue == "VoiceTrialBarCentreAgain", let screen = self.currentScreen {
                        self.placements.reset(self.displayID(screen)); self.edgeRevealed = false
                    }
                    if self.box.state == .resting { self.updateIdleVisibility() }
                    self.layout(animated: false)
                }
            })
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
                        let screens = NSScreen.screens
                        self.placements.retain(displays: Set(screens.map { self.displayID($0) }))
                        if let screen = self.dictationScreen, !screens.contains(where: { self.displayID($0) == self.displayID(screen) }) {
                            self.dictationScreen = screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? screens.first
                            self.edgeRevealed = false
                        }
                        self.layout(animated: false)
                        if self.box.state == .resting { self.updateIdleVisibility() }
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
        edgeRevealed = false
        if keepBarOnScreen || (docked && tuckAtEdge) { transition(.resting) }
        else {
            box.state = .resting; box.stateAge = 0
            wantsVisible = false; panel.orderOut(nil)
        }
        stuckSince = nil
        onRested()
    }

    private func updateIdleVisibility() {
        guard box.state == .resting else { return }
        wantsVisible = keepBarOnScreen || (docked && tuckAtEdge)
        if wantsVisible { layout(animated: false); if observesEvents { panel.orderFrontRegardless() } }
        else { panel.orderOut(nil) }
    }

    /// A notice (kept for paste, didn't land) clears by itself, so it never hangs around. Paste last keeps the words.
    /// Questions and word suggestions keep their own rules.
    func expireNotice(after seconds: Double) {
        schedule(after: seconds) { hud in
            guard hud.box.state == .message, hud.waitAction == nil, hud.wordAction == nil else { return }
            Log.note("bar: notice cleared by itself after \(Int(seconds)) s")
            hud.rest()
        }
    }

    /// Safety net: a listening or writing bar with nothing running behind it goes away after a few seconds.
    /// Returns true when it hid the bar.
    @discardableResult
    func restIfStuck(idle: Bool, now: Date = Date(), after limit: TimeInterval = 3) -> Bool {
        let live = box.state == .listening || box.state == .writing || (box.state == .needs && listeningActive)
        guard idle, wantsVisible, live else { stuckSince = nil; return false }
        guard let since = stuckSince else { stuckSince = now; return false }
        guard now.timeIntervalSince(since) >= limit else { return false }
        Log.note("bar: \(box.state.rawValue) left up with nothing running, hid it")
        rest()
        return true
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
        box.message = note; box.success = false
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
        typingStopped = true; captionText = line
        if let range = line.range(of: #"\b[0-9]+ words?\b"#, options: .regularExpression),
           let count = Int(line[range].split(separator: " ").first ?? "") { box.words = count }
        guard box.state == .listening else { return }
        box.message = line; layout()
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
        if action == "reveal" {
            edgeRevealed = true; layout(animated: false); return
        }
        if action == "centre" {
            if let screen = currentScreen { placements.reset(displayID(screen)) }
            edgeRevealed = false; layout(); updateIdleVisibility(); return
        }
        if action == "size" {
            box.menuOpen = false; smallTalkingBar.toggle(); onSmallTalkingBar(smallTalkingBar); return
        }
        if ["options", "availability", "finish", "cancel", "paste"].contains(action) {
            let available = menuAvailability()
            box.canFinish = available.finish; box.canCancel = available.cancel; box.canPaste = available.paste
            if action == "availability" { return }
            if action == "options" { box.menuOpen.toggle(); layout(); return }
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
    private func layout(animated: Bool = true) {
        guard let screen = currentScreen else { return }
        let id = displayID(screen)
        box.smallNeedsMessage = !listeningActive
        box.canKeepBar = listeningActive
        box.showTimer = showTimer
        box.dragged = placements.position(on: id) != nil || dragging
        box.tucked = box.state == .resting && docked && tuckAtEdge && !edgeRevealed && !dragging
        box.setAccessibilityHelp(box.tucked ? "Voice is tucked here. Click or hover to reveal it." : "Drag to move. Click the mark for recording controls. Right-click for more options.")
        let size = box.desiredSize(maxWidth: max(48, screen.visibleFrame.width - 16))
        let fitted = placements.frame(on: id, visible: screen.visibleFrame, size: size)
        let animate = animated && panel.isVisible && !box.reducedMotion && !frozen && !dragging
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

    /// Offscreen trial rendering. No AppDelegate, capture, insertion, live preferences or window ordering.
    static func captureStates(to directory: URL) -> Int32 {
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { print("Could not create screenshot directory: \(error)"); return 1 }
        let suite = "RedpenVoice.NativeTrial." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let hud = HUD(defaults: defaults, observesEvents: false)
        hud.frozen = true; hud.box.freeze = true
        var passed = 0, failed = 0, captures: [[String: Any]] = []
        func check(_ name: String, _ condition: Bool) {
            if condition { passed += 1 } else { failed += 1; print("FAIL \(name)") }
        }
        func capture(_ name: String) {
            hud.layout(animated: false)
            let url = directory.appendingPathComponent(name + ".png")
            hud.snapshot(to: url, hidden: !hud.wantsVisible)
            check(name + " controls fit", hud.box.subviews.allSatisfy { hud.box.bounds.contains($0.frame) })
            let controls = hud.box.subviews
            check(name + " controls do not overlap", controls.enumerated().allSatisfy { index, view in
                controls.dropFirst(index + 1).allSatisfy { !view.frame.intersects($0.frame) }
            })
            if !hud.box.shownMessage.isEmpty {
                let measured = (hud.box.shownMessage as NSString).boundingRect(with: CGSize(width: hud.box.messageFrame.width, height: 2000),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: TalkingBarView.font(15)])
                check(name + " full warning text fits", ceil(measured.height) <= hud.box.messageFrame.height)
                check(name + " text clears all controls", controls.allSatisfy { !hud.box.messageFrame.intersects($0.frame) })
            }
            captures.append(["file": url.lastPathComponent, "width": hud.panel.frame.width,
                             "height": hud.panel.frame.height, "visible": hud.wantsVisible])
        }
        hud.rest(); check("idle hidden by default", !hud.wantsVisible && !hud.panel.isVisible)
        check("panel cannot steal text focus", !hud.panel.canBecomeKey && !hud.panel.canBecomeMain)
        hud.show("", level: true); capture("trial-bottom-listening")
        check("initial B is 48x48", hud.panel.frame.size == CGSize(width: 48, height: 48))
        if let screen = hud.currentScreen {
            check("B above bottom centre", hud.panel.frame.midX == screen.visibleFrame.midX && hud.panel.frame.minY == screen.visibleFrame.minY + TrialBarPlacement.bottomInset)
        }
        hud.box.reducedMotion = false
        hud.box.smooth = 0; hud.box.history = .init(repeating: 0, count: 90)
        let quietMark = hud.box.markHeights
        capture("trial-voice-quiet")
        hud.box.smooth = 0.75; hud.box.history = .init(repeating: 0.6, count: 90)
        let speakingMark = hud.box.markHeights
        check("mark follows microphone level", zip(quietMark, speakingMark).allSatisfy { $0 < $1 })
        check("mark remains inside compact bar", speakingMark.allSatisfy { $0.isFinite && $0 > 0 && $0 <= 26 })
        capture("trial-voice-speaking")
        hud.box.phase += 10
        check("mark does not fake a timer pulse", hud.box.markHeights == speakingMark)
        hud.box.reducedMotion = true
        let reducedMark = hud.box.markHeights
        hud.box.smooth = 0; hud.box.history = .init(repeating: 0, count: 90)
        check("reduce motion keeps mark steady", hud.box.markHeights == reducedMark)
        hud.box.reducedMotion = false
        hud.box.smooth = .nan; hud.box.history = .init(repeating: .infinity, count: 90)
        check("invalid audio cannot corrupt mark geometry", hud.box.markHeights == quietMark)
        hud.box.smooth = 0; hud.box.history = .init(repeating: 0, count: 90)
        let initialFrame = hud.panel.frame
        hud.refineCapture(textBox: CGRect(x: 5000, y: 0, width: 100, height: 100), window: nil)
        check("late focus refinement keeps recording steady", hud.panel.frame == initialFrame)
        var finished = 0, cancelled = 0, started = 0, pasted = 0, notes = 0, settings = 0
        hud.onFinish = { finished += 1 }; hud.onCancel = { cancelled += 1 }; hud.onStart = { started += 1 }
        hud.onPaste = { pasted += 1 }; hud.onNotes = { notes += 1 }; hud.onSettings = { settings += 1 }
        hud.perform("options"); capture("trial-finish-cancel")
        check("controls expand together", hud.panel.frame.size == CGSize(width: 264, height: 48))
        check("Finish and Cancel labelled", hud.box.subviews.compactMap { ($0 as? NSButton)?.title } == ["Finish", "Cancel"])
        (hud.box.subviews.first { ($0 as? NSButton)?.title == "Finish" } as? NSButton)?.performClick(nil)
        check("Finish once through real callback", finished == 1 && !hud.box.menuOpen)
        hud.perform("cancel"); hud.perform("paste"); hud.perform("notes"); hud.perform("settings")
        check("existing callbacks preserved", cancelled == 1 && pasted == 1 && notes == 1 && settings == 1)
        hud.perform("options"); hud.dismissExtras()
        check("dismiss controls does not cancel", hud.box.state == .listening && cancelled == 1)
        defaults.set(true, forKey: "VoiceTrial.showTimer"); hud.layout(animated: false); capture("trial-timer")
        check("timer C is 96x38", hud.panel.frame.size == CGSize(width: 96, height: 38))
        defaults.set(false, forKey: "VoiceTrial.showTimer")
        hud.caption("These are the actual words shown on the bar."); capture("trial-live-caption")
        check("live words preserved", hud.box.shownMessage.contains("actual words"))
        hud.stoppedTyping("Typing stopped (you clicked). 52 words so far, all go in at the end.")
        capture("trial-stopped-typing")
        check("stopped typing explains recovery", hud.box.shownMessage.contains("you clicked") && hud.listeningActive)
        hud.writing("All your words go in now"); capture("trial-writing-detail")
        check("writing details preserved", hud.box.shownMessage == "All your words go in now")
        hud.show("No sound from Scarlett", level: false); capture("trial-no-sound")
        check("no-sound warning preserved", hud.box.shownMessage == "No sound from Scarlett")
        check("terminal warning has no unrelated recording buttons", hud.box.subviews.isEmpty)
        hud.show("", level: true)
        hud.box.state = .needs; hud.box.message = "No sound from Scarlett. Check the microphone connection."
        hud.perform("options"); capture("trial-live-no-sound-controls")
        check("live warning exposes labelled controls", hud.box.subviews.compactMap { ($0 as? NSButton)?.title } == ["Finish", "Cancel"])
        (hud.box.subviews.first { ($0 as? NSButton)?.title == "Finish" } as? NSButton)?.performClick(nil)
        check("live warning Finish retains real callback", finished == 2 && hud.listeningActive)
        hud.perform("options")
        (hud.box.subviews.first { ($0 as? NSButton)?.title == "Cancel" } as? NSButton)?.performClick(nil)
        check("live warning Cancel retains real callback", cancelled == 2)
        let warningDismissed = hud.dismissExtras()
        check("live warning dismissal cannot cancel recording", !warningDismissed && hud.box.state == .needs && cancelled == 2)
        var answer: Bool?
        hud.ask("Your words are kept. Copy them?", yes: "Copy", no: "Throw away") { answer = $0 }
        capture("trial-recovery")
        check("recovery buttons fit", hud.box.choices == ["Copy", "Throw away"] && hud.box.subviews.count >= 2)
        hud.dismissExtras(); check("dismiss never answers recovery", answer == nil && hud.dismissedQuestion)
        hud.ask("Copy words?", yes: "Copy", no: "Keep") { answer = $0 }
        (hud.box.subviews.first { ($0 as? NSButton)?.title == "Copy" } as? NSButton)?.performClick(nil)
        check("native Copy invokes original recovery callback", answer == true)
        hud.ask("Your words are kept.", yes: "Copy", no: "Throw away") { answer = $0 }
        (hud.box.subviews.first { ($0 as? NSButton)?.title == "Throw away" } as? NSButton)?.performClick(nil)
        check("native Throw away invokes original recovery callback", answer == false)
        let narrow = TalkingBarView(frame: .zero)
        narrow.state = .message
        narrow.message = String(repeating: "Your words are kept. ", count: 8)
        narrow.choices = ["Copy all of my words", "Keep the words for later"]
        let narrowSize = narrow.desiredSize(maxWidth: 248)
        narrow.frame = CGRect(origin: .zero, size: narrowSize); narrow.rebuildControls()
        check("narrow recovery choices stay within surface", narrow.subviews.count == 2 && narrow.subviews.allSatisfy { narrow.bounds.contains($0.frame) })
        check("narrow recovery choices wrap without overlap", !narrow.subviews[0].frame.intersects(narrow.subviews[1].frame))
        check("narrow recovery text clears choices", narrow.subviews.allSatisfy { !narrow.messageFrame.intersects($0.frame) })
        if VoiceAppearance.selection == "colour" {
            check("colour warning body text is white", TalkingBarView.body == NSColor.white)
            check("colour warning label text is white", TalkingBarView.label == NSColor.white)
        }
        hud.show("", level: true)
        if let screen = hud.currentScreen {
            hud.placements.save(center: CGPoint(x: screen.visibleFrame.minX + 20, y: screen.visibleFrame.midY),
                                on: hud.displayID(screen), visible: screen.visibleFrame, dock: true)
            hud.rest(); capture("trial-edge-tab")
            check("docked idle retrievable with keep off", hud.wantsVisible && hud.box.tucked && hud.panel.frame.width == 12)
            hud.perform("reveal"); capture("trial-edge-revealed")
            check("tab reveal is functional", !hud.box.tucked && hud.panel.frame.width == 64)
            hud.show("", level: true); capture("trial-edge-recording")
            check("recording never tucked", !hud.box.tucked && hud.panel.frame.width == 64)
            hud.perform("centre"); capture("trial-centre-again")
            check("centre clears only current placement", hud.placements.position(on: hud.displayID(screen)) == nil && hud.panel.frame.width == 48)
        }
        hud.keepBarOnScreen = true; hud.rest(); hud.perform("start")
        check("idle click original start", started == 1)
        hud.writing(); hud.hide(); check("completion preserved", hud.box.state == .done)
        hud.rest(); hud.shutdown(); defaults.removePersistentDomain(forName: suite)
        let result: [String: Any] = ["passed": passed, "failed": failed, "captures": captures,
            "scope": "Offscreen native trial. No physical multi-display, recording, insertion, media or installation proof."]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("verification.json"))
        }
        print("Native trial HUD checks: \(passed) passed, \(failed) failed")
        return failed == 0 ? 0 : 1
    }

    func shutdown() {
        hideAt?.cancel(); tick?.invalidate(); tick = nil; wantsVisible = false; panel.orderOut(nil)
        monitors.forEach(NSEvent.removeMonitor); monitors.removeAll()
        if let screenWatch { NotificationCenter.default.removeObserver(screenWatch) }; screenWatch = nil
        preferenceWatches.forEach(NotificationCenter.default.removeObserver); preferenceWatches.removeAll()
    }
}

private final class TalkingBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval { 0.28 }
}
