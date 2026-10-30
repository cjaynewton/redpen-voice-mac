import AppKit
import VoiceCore

/// Listen only. Its own run loop keeps receiving input while Insert is busy on the main thread.
/// Gesture callbacks still run exclusively through HoldKey's existing NSEvent path.
final class DraftInputMonitor: @unchecked Sendable {
    private struct WeakInput { weak var value: DraftInput? }
    private let lock = NSLock()
    private var inputs: [WeakInput] = []
    private var talkCodes: Set<Int> = []
    private var tap: CFMachPort?

    func configure(_ codes: [Int]) {
        lock.lock(); defer { lock.unlock() }
        talkCodes = Set(codes)
    }

    func track(since: Double) -> DraftInput {
        let input = DraftInput(since: since)
        lock.lock(); defer { lock.unlock() }
        inputs.removeAll { $0.value == nil }
        inputs.append(WeakInput(value: input))
        return input
    }

    func record(talkKey: Bool, at time: Double) {
        lock.lock(); defer { lock.unlock() }
        inputs.removeAll { $0.value == nil }
        for input in inputs { input.value?.record(talkKey: talkKey, at: time) }
    }

    func start() {
        guard tap == nil else { return }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) |
                   (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<DraftInputMonitor>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else { monitor.receive(type, event) }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.note("draft input: passive listener unavailable; unmatched keys stop drafts after 250ms")
            return
        }
        self.tap = tap
        // HoldKey lives for the app's lifetime; the listener retains its owner for the same lifetime.
        Thread.detachNewThread { [self] in
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            DispatchQueue.main.async { Log.note("draft input: passive listener ready") }
            CFRunLoopRun()
            withExtendedLifetime(self) {}
        }
    }

    private func receive(_ type: CGEventType, _ event: CGEvent) {
        guard !VoiceEvents.isOwn(pid: event.getIntegerValueField(.eventSourceUnixProcessID),
                                 userData: event.getIntegerValueField(.eventSourceUserData)) else { return }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        lock.lock(); let talk = talkCodes.contains(code); lock.unlock()
        if type == .flagsChanged {
            // The event's flags carry direction even if the physical key is already up when handled.
            let flags: [Int: CGEventFlags] = [63: .maskSecondaryFn, 61: .maskAlternate, 58: .maskAlternate,
                54: .maskCommand, 55: .maskCommand, 62: .maskControl, 59: .maskControl,
                60: .maskShift, 56: .maskShift]
            guard talk, let flag = flags[code], event.flags.contains(flag) else { return }
        } else if type != .keyDown { return }
        record(talkKey: talk, at: Double(event.timestamp) / 1_000_000_000)
    }
}
