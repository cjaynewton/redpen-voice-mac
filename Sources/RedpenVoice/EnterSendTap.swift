import AppKit
import VoiceCore

/// Holds a plain Enter while Voice is armed (D-1008) and sends it later. The only tap in Voice that keeps a key from
/// the app in front, so it is careful: it is armed only while a dictation runs or finishes, the arming runs out by
/// itself when Voice stops renewing it, and every held Enter goes out exactly once.
/// A held Enter is sent from the main thread, where Voice does all its typing, so it never lands in the middle of
/// Voice's own keys. If the main thread stalls, the tap's own queue sends it after the backstop.
final class EnterSendTap: @unchecked Sendable {
    static let shared = EnterSendTap()

    private let lock = NSLock()
    private var rules = EnterSend()
    private var tap: CFMachPort?
    private let queue = DispatchQueue(label: "redpen.voice.enter")
    /// Uptimes of the key-downs it held. The keyboard's own key counter still sees them, so the checks that read it
    /// treat these like talk keys; the event watchers skip them if they see them at all.
    private var heldTimes: [Double] = []
    /// A held Enter kept down: its press to its newest repeat, so the repeats never push the press out of the list.
    private var repeatSpan: (start: Double, end: Double)?
    /// A new held press (main thread): stop the dictation, or say it goes out when the words are in.
    var onHold: (Int) -> Void = { _ in }
    /// A held press went out (main thread), with why.
    var onSent: (Int, String) -> Void = { _, _ in }

    private init() {}

    var available: Bool { tap != nil }

    /// The talk keys' codes. Right Option, Command or Control held to talk doesn't turn Enter into a shortcut.
    func setTalkKeys(_ codes: [Int]) {
        var flags: UInt64 = 0
        for c in codes {
            switch c {
            case 61: flags |= EnterSend.option
            case 54: flags |= EnterSend.command
            case 62: flags |= EnterSend.control
            default: break
            }
        }
        lock.lock(); rules.talkKeys = flags; lock.unlock()
    }

    func arm(for length: Double = EnterSend.armLength) { lock.lock(); rules.arm(now: Self.now, for: length); lock.unlock() }
    func disarm() { lock.lock(); rules.disarm(); lock.unlock() }

    /// Sends a held press on the main thread after `delay` (the words are in, or Voice can't use it). Nothing when it
    /// already went.
    func release(_ id: Int, after delay: Double = 0, why: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in send(id, why: why) { $0.release(id: id) } }
    }

    /// A key-down this tap held, by uptime in seconds, within `tolerance`.
    func held(at time: Double, tolerance: Double = 0.002) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let r = repeatSpan, time >= r.start - tolerance, time <= r.end + tolerance { return true }
        return heldTimes.contains { abs($0 - time) <= tolerance }
    }

    /// Held key-down times since `start`, for the hardware checks.
    func heldTimes(since start: Double) -> [Double] {
        lock.lock(); defer { lock.unlock() }
        var times = heldTimes.filter { $0 >= start - DraftSafety.talkKeyTolerance }
        if let r = repeatSpan, r.end >= start { times.append(r.end) }
        return times
    }

    func start() {
        guard tap == nil else { return }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<EnterSendTap>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                return me.receive(type, event) ? nil : Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.note("enter: can't watch the Enter key, it stays ordinary")
            return
        }
        self.tap = tap
        Thread.detachNewThread { [self] in
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            DispatchQueue.main.async { Log.note("enter: watching the Enter key") }
            CFRunLoopRun()
            withExtendedLifetime(self) {}
        }
    }

    /// True when the key is held. Decides from the rules alone, under the lock: no Accessibility calls here, so the
    /// tap never runs long enough for macOS to switch it off.
    private func receive(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard EnterSend.keyCodes.contains(code) else { return false }
        let own = VoiceEvents.isOwn(pid: event.getIntegerValueField(.eventSourceUnixProcessID),
                                    userData: event.getIntegerValueField(.eventSourceUserData))
        lock.lock()
        let decision = type == .keyDown
            ? rules.keyDown(code: code, flags: event.flags.rawValue, own: own,
                            repeated: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, now: Self.now)
            : rules.keyUp(code: code, own: own)
        if type == .keyDown, decision != .pass {
            let at = Double(event.timestamp) / 1_000_000_000
            if decision == .swallow, let r = repeatSpan { repeatSpan = (r.start, at) }
            else {
                heldTimes.append(at)
                if heldTimes.count > 32 { heldTimes.removeFirst() }
                repeatSpan = (at, at)
            }
        }
        lock.unlock()
        switch decision {
        case .pass: return false
        case .swallow: return true
        case .hold(let id):
            DispatchQueue.main.async { self.onHold(id) }
            // The cap, on the main thread so it waits for any typing Voice is doing; the backstop if that thread stalls.
            DispatchQueue.main.asyncAfter(deadline: .now() + EnterSend.cap) { [self] in
                send(id, why: "the 5 s cap") { $0.capReached(id: id, now: Self.now) }
            }
            queue.asyncAfter(deadline: .now() + EnterSend.cap + EnterSend.backstop) { [self] in
                send(id, why: "the backstop, Voice was busy") { $0.capReached(id: id, now: Self.now) }
            }
            return true
        case .sendNow(let id):
            release(id, why: "a second Enter")
            return true
        }
    }

    /// Posts the held key once, if `take` still finds it waiting.
    private func send(_ id: Int, why: String, take: (inout EnterSend) -> Int?) {
        lock.lock(); let code = take(&rules); lock.unlock()
        guard let code, let pair = VoiceEvents.keyboardPair(key: CGKeyCode(code)) else { return }
        // Marked as Voice's own, so this tap and the other watchers let it through.
        pair.down.post(tap: .cgSessionEventTap); pair.up.post(tap: .cgSessionEventTap)
        if Thread.isMainThread { onSent(id, why) } else { DispatchQueue.main.async { self.onSent(id, why) } }
    }

    private static var now: Double { ProcessInfo.processInfo.systemUptime }
}
