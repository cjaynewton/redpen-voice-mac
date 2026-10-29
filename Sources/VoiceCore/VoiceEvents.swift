import AppKit
import Foundation

/// All Voice input has an isolated source and an explicit identity. Constructing these never posts input.
public enum VoiceEvents {
    public static let marker: Int64 = 0x5250_564F_4943_4501

    public static func isOwn(pid: Int64, userData: Int64) -> Bool {
        pid == Int64(ProcessInfo.processInfo.processIdentifier) || userData == marker
    }

    public static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(ProcessInfo.processInfo.processIdentifier))
        event.setIntegerValueField(.eventSourceUserData, value: marker)
    }

    public static func keyboardPair(key: CGKeyCode, flags: CGEventFlags = []) -> (down: CGEvent, up: CGEvent)? {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return nil }
        down.flags = flags
        // In particular, Command-V must not leave Command set after V comes up.
        up.flags = []
        mark(down); mark(up)
        return (down, up)
    }

    public static func playPausePair() -> (down: CGEvent, up: CGEvent)? {
        guard let source = CGEventSource(stateID: .privateState) else { return nil }
        func event(down: Bool) -> CGEvent? {
            let data = (16 << 16) | ((down ? 0xA : 0xB) << 8) // NX_KEYTYPE_PLAY
            guard let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [],
                                                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0,
                                                context: nil, subtype: 8, data1: data, data2: -1)?.cgEvent else { return nil }
            event.setSource(source)
            event.flags = []
            mark(event)
            return event
        }
        guard let down = event(down: true), let up = event(down: false) else { return nil }
        return (down, up)
    }
}
