import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Hold a key to talk, release to write. Watches key changes system-wide (needs Accessibility), so it sees keys like
/// Fn and right Option on their own, which a normal shortcut cannot.
/// Recording starts the instant the key goes down. Fn also does ordinary work (Fn with arrows, Delete, the F-keys),
/// so any other key while it is down cancels the dictation without a sound.
/// Tap the key twice and it keeps listening with your hands free; one more tap finishes.
@MainActor
final class HoldKey {
    struct Key: Equatable { let code: Int; let name: String }

    var keys: [Key] = [HoldKey.fn, HoldKey.rightOption]
    var doubleTap = true
    var onDown: () -> Void = {}
    var onUp: () -> Void = {}
    var onCancel: () -> Void = {}
    /// Hands-free just started (second tap), so the bar can say so.
    var onHandsFree: () -> Void = {}
    /// A tap is a press shorter than this; the second must come within `tapGap` of the first. Generous enough for an
    /// unhurried double tap (Cedric's first tap ran just over the old 0.3 s on Oct 25).
    static let tapLength = 0.4, tapGap = 0.5
    private var monitors: [Any] = []
    private var held: Set<Int> = []
    private var active = false
    private var spoiled = false
    private var pressedAt = Date()
    private var lastTap: Date?
    private var secondTap = false
    private var latched = false
    /// Talking hands-free: no key is held, so typed words can't pick up Fn or Option.
    var handsFree: Bool { latched }
    private var swallowUp = false

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
        let down = keys.contains { k in CGEventSource.keyState(.hidSystemState, key: CGKeyCode(k.code))
            || (Self.modifiers[k.code].map { NSEvent.modifierFlags.contains($0) } ?? false) }
        if latched || ((active || !held.isEmpty) && down) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.restart() }
            return
        }
        // The key is up but its release was never heard (watchers made before Accessibility): finish that dictation.
        if active { active = false; onUp() }
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll(); held.removeAll(); active = false; owner = nil
        start()
    }

    private func isTalkKey(_ code: Int) -> Bool { keys.contains { $0.code == code } }

    private func flagsChanged(_ e: NSEvent) {
        let code = Int(e.keyCode)
        guard isTalkKey(code), let flag = Self.modifiers[code] else {
            if !held.isEmpty { otherKey() }  // another modifier while the talk key is down: a shortcut, not talking
            return
        }
        let down = e.modifierFlags.contains(flag)
        // A release the keyboard itself does not report (the key is still physically down) is an echo of
        // something the app posted, not the finger lifting.
        // The hardware's own state, not the session's: words typed while the key is held are posted without Fn or
        // Option, and the session state can read that as the key coming up.
        if !down, CGEventSource.keyState(.hidSystemState, key: CGKeyCode(code)) { return }
        set(code, down)
    }

    private func key(_ e: NSEvent) {
        // Words Voice types itself while you hold the key are not "another key": they would cancel the dictation.
        if e.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return }
        let code = Int(e.keyCode)
        if isTalkKey(code), Self.modifiers[code] == nil {
            guard !e.isARepeat else { return }
            set(code, e.type == .keyDown)
        } else if e.type == .keyDown {
            otherKey()
        }
    }

    private func set(_ code: Int, _ down: Bool) {
        // One talk key at a time: the key that started a dictation owns it, and the other one (right Option hit by
        // accident while holding Fn) is ignored, so it can't keep the dictation going or start another (Oct 25).
        if let o = owner, code != o { return }
        guard down != held.contains(code) else { return }
        if down { held.insert(code) } else { held.remove(code) }
        if down, owner == nil { owner = code }
        changed(down)
        if held.isEmpty, !active, !latched { owner = nil }
    }
    private var owner: Int?
    /// The key running the dictation now, by name, so the hands-free bar names the one that stops it.
    var ownerName: String? { owner.flatMap { o in keys.first { $0.code == o }?.name } }

    private func changed(_ down: Bool) {
        if down {
            // Hands-free: this press finishes the dictation; its release is ignored.
            if latched { latched = false; active = false; swallowUp = true; onUp(); return }
            guard !active else { return }
            spoiled = false
            active = true
            secondTap = doubleTap && lastTap.map { Date().timeIntervalSince($0) < Self.tapGap } == true
            pressedAt = Date()
            onDown()
        } else if held.isEmpty {
            if swallowUp { swallowUp = false; return }
            guard active else { return }
            if spoiled { active = false; onCancel(); return }
            if doubleTap, Date().timeIntervalSince(pressedAt) < Self.tapLength {
                // A quick tap: the second one keeps listening, the first is dropped quietly and waits for a second.
                if secondTap { latched = true; secondTap = false; lastTap = nil; Log.note("hold key: hands-free on"); onHandsFree(); return }
                active = false; lastTap = Date(); onCancel(); return
            }
            active = false
            onUp()
        }
    }

    /// Any other key while the talk key is held: this press is a shortcut. Cancel what started, say nothing.
    /// Hands-free talking is never cancelled this way, since no talk key is held.
    private func otherKey() {
        guard !held.isEmpty, !spoiled, !latched else { return }
        spoiled = true
        if active { active = false; onCancel() }
    }
}
