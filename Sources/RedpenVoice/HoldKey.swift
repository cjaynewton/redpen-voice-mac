import AppKit
import Carbon.HIToolbox
import CoreGraphics
import VoiceCore

/// Hold a key to talk, release to write. Watches key changes system-wide (needs Accessibility), so it sees keys like
/// Fn and right Option on their own, which a normal shortcut cannot.
/// Recording starts the instant the key goes down. Fn also does ordinary work (Fn with arrows, Delete, the F-keys),
/// so any other key while it is down cancels the dictation without a sound.
/// Tap the key twice and it keeps listening with your hands free; one more tap finishes.
@MainActor
final class HoldKey {
    struct Key: Equatable { let code: Int; let name: String }

    var keys: [Key] = [HoldKey.fn, HoldKey.rightOption] {
        didSet { draftInputMonitor.configure(keys.map(\.code)) }
    }
    var doubleTap = true
    var onDown: () -> Bool = { false }
    var canBegin: () -> Bool = { true }
    var onUp: () -> Void = {}
    var onCancel: () -> Void = {}
    /// Hands-free just started (second tap), so the bar can say so.
    var onHandsFree: () -> Void = {}
    /// A tap is a press shorter than this; the second must come within `tapGap` of the first. Generous enough for an
    /// unhurried double tap (Cedric's first tap ran just over the old 0.3 s on Oct 25).
    static let tapLength = TalkKeyState.tapLength, tapGap = TalkKeyState.tapGap
    private var monitors: [Any] = []
    private var state = TalkKeyState()
    private var releaseTimer: Timer?
    private var inputSequence = 0
    private let draftInputMonitor = DraftInputMonitor()
    func trackDraft(since: Double) -> DraftInput { draftInputMonitor.track(since: since) }
    /// Escape threw the dictation away.
    func discard() { state.discard(at: ProcessInfo.processInfo.systemUptime); updateReleaseTimer() }
    var handsFree: Bool { state.handsFree }
    var lastTalkKeyDownAt: Double? { state.lastTalkKeyDownAt }
    var lastTypingKeyDownAt: Double? { state.lastTypingKeyDownAt }
    var ownerName: String? { state.owner.flatMap { o in keys.first { $0.code == o }?.name } }

    static let fn = Key(code: kVK_Function, name: "Fn")
    static let rightOption = Key(code: kVK_RightOption, name: "right Option")
    /// Keys that change modifier flags, with the flag that says they are down.
    static let modifiers: [Int: NSEvent.ModifierFlags] = [
        kVK_Function: .function, kVK_RightOption: .option, kVK_Option: .option, kVK_RightCommand: .command,
        kVK_Command: .command, kVK_RightControl: .control, kVK_Control: .control, kVK_RightShift: .shift, kVK_Shift: .shift,
    ]
    static let modifierNames: [Int: String] = [
        kVK_Function: "Fn", kVK_RightOption: "right Option", kVK_Option: "left Option", kVK_RightCommand: "right Command",
        kVK_Command: "left Command", kVK_RightControl: "right Control", kVK_Control: "left Control",
        kVK_RightShift: "right Shift", kVK_Shift: "left Shift",
    ]

    /// The choice saved in config: "fnOrOption", "fn", "rightOption", "rightCommand", "rightControl", or
    /// "key:<code>:<name>" for a key picked with Other key.
    static func keys(for choice: String) -> [Key] {
        switch choice {
        case "fn": return [fn]
        case "rightOption": return [rightOption]
        case "rightCommand": return [Key(code: kVK_RightCommand, name: "right Command")]
        case "rightControl": return [Key(code: kVK_RightControl, name: "right Control")]
        default:
            let p = choice.split(separator: ":", maxSplits: 2).map(String.init)
            if p.count == 3, p[0] == "key", let c = Int(p[1]) { return [Key(code: c, name: p[2])] }
            return [fn, rightOption]
        }
    }

    func start() {
        draftInputMonitor.configure(self.keys.map(\.code))
        draftInputMonitor.start()
        let flags: (NSEvent) -> Void = { [weak self] e in self?.flagsChanged(e) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { e in flags(e); return e }) { monitors.append(l) }
        let keys: (NSEvent) -> Void = { [weak self] e in self?.key(e) }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp], handler: keys) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp], handler: { e in keys(e); return e }) { monitors.append(l) }
        Log.note("hold key watching (\(self.keys.map(\.name).joined(separator: ", ")), double tap \(doubleTap))")
    }

    /// Sets the watchers up again. Watchers made before Accessibility was allowed can stay deaf after it is.
    func restart() {
        // Hands-free, or the key really still down: setting up again would lose the press, so it waits.
        // Whether any talk key is physically down now, modifier or not, read from the keyboard's own state.
        // The hardware's own state: Voice's typed keys don't change it.
        let down = keys.contains { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0.code)) }
        if state.handsFree || ((state.active || state.held) && down) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.restart() }
            return
        }
        if let owner = state.owner, state.held {
            apply(state.event(key: owner, down: false, at: ProcessInfo.processInfo.systemUptime))
        }
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        start()
    }

    private func isTalkKey(_ code: Int) -> Bool { keys.contains { $0.code == code } }

    private func isOwn(_ e: NSEvent) -> Bool {
        guard let cg = e.cgEvent else { return false }
        return VoiceEvents.isOwn(pid: cg.getIntegerValueField(.eventSourceUnixProcessID),
                                 userData: cg.getIntegerValueField(.eventSourceUserData))
    }

    private func flagsChanged(_ e: NSEvent) {
        let code = Int(e.keyCode)
        guard isTalkKey(code), let flag = Self.modifiers[code] else {
            if !isOwn(e) { apply(state.otherKey()) }
            return
        }
        receive(e, down: e.modifierFlags.contains(flag))
    }

    private func key(_ e: NSEvent) {
        let code = Int(e.keyCode)
        if isTalkKey(code) {
            if Self.modifiers[code] == nil { receive(e, down: e.type == .keyDown) }
            else if e.type == .keyDown, !isOwn(e) {
                state.noteKeyDown(talkKey: true, at: e.timestamp)
                draftInputMonitor.record(talkKey: true, at: e.timestamp)
            }
        } else if e.type == .keyDown, !isOwn(e) {
            draftInputMonitor.record(talkKey: false, at: e.timestamp)
            apply(state.otherKey(at: e.timestamp))
        }
    }

    // Temporary diagnostics end a week after this repair. Only talk keys, never letters or dictated words.
    private static let rawLogUntil = ISO8601DateFormatter().date(from: "2026-11-05T12:00:00Z")!

    private func receive(_ e: NSEvent, down: Bool) {
        let code = Int(e.keyCode)
        let hardware = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code))
        let own = isOwn(e)
        let repeated = e.type == .keyDown && e.isARepeat
        if Date() < Self.rawLogUntil {
            let pid = e.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) ?? -1
            Log.note("talk raw: key \(code), \(down ? "down" : "up"), hardware \(hardware), confirmed \(down == hardware), pid \(pid), own \(own), repeat \(repeated), event \(String(format: "%.6f", e.timestamp)), uptime \(String(format: "%.6f", ProcessInfo.processInfo.systemUptime))")
        }
        guard !own else { return }
        if down {
            state.noteKeyDown(talkKey: true, at: e.timestamp)
            draftInputMonitor.record(talkKey: true, at: e.timestamp)
        }
        guard !repeated else { return }
        inputSequence += 1
        let sequence = inputSequence
        state.doubleTap = doubleTap
        let action = state.event(key: code, down: down, ownEvent: own,
                                 canBegin: canBegin(), at: e.timestamp)
        apply(action)
        if down, !hardware {
            // A real queued up carries the exact tap duration, even if the next press is already held.
            // If that up was missed, this already-released down still completes as a quick tap.
            let eventAt = e.timestamp
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, self.inputSequence == sequence,
                      !CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code)) else { return }
                self.apply(self.state.recoverReleasedDown(key: code, eventAt: eventAt))
            }
        }
    }

    private func checkRelease() {
        guard let owner = state.owner, state.held, !state.handsFree else { return }
        let hardware = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(owner))
        let action = state.checkRelease(key: owner, hardwareDown: hardware, at: ProcessInfo.processInfo.systemUptime)
        if action == .end { Log.note("hold key: release was missed, ended from the key's real state") }
        apply(action)
    }

    private func updateReleaseTimer() {
        guard state.held, !state.handsFree else {
            releaseTimer?.invalidate(); releaseTimer = nil
            return
        }
        guard releaseTimer == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkRelease() }
        }
        timer.tolerance = 0.02
        releaseTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func apply(_ action: TalkKeyState.Action?) {
        defer { updateReleaseTimer() }
        switch action {
        case .begin: if !onDown() { state.rejectBegin() }
        case .end: onUp()
        case .cancel: onCancel()
        case .handsFree: Log.note("hold key: hands-free on"); onHandsFree()
        case nil: break
        }
    }
}
