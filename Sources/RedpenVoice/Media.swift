import AppKit
import CoreAudio
import VoiceCore

/// Pauses whatever is playing while you talk, and only then. The check asks CoreAudio which apps are sending sound
/// out right now, one app at a time, and ignores sound routers like Boom 3D that keep the speakers on all day.
/// A Mac with nothing playing never gets a play/pause press, so a paused video never starts by surprise.
enum Media {
    /// Names of the apps sending sound out right now, routers and this app left out.
    static func playingApps() -> [String] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        var names: [String] = []
        for id in ids {
            var out = UInt32(0), pid = pid_t(0)
            var sz = UInt32(MemoryLayout<UInt32>.size)
            addr.mSelector = kAudioProcessPropertyIsRunningOutput
            guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &out) == noErr, out != 0 else { continue }
            sz = UInt32(MemoryLayout<pid_t>.size)
            addr.mSelector = kAudioProcessPropertyPID
            guard AudioObjectGetPropertyData(id, &addr, 0, nil, &sz, &pid) == noErr, pid != me else { continue }
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? processName(pid)
            if !MediaGate.isRouter(name) { names.append(name) }
        }
        return names
    }

    static func outputRunning() -> Bool { !playingApps().isEmpty }

    private static func processName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 1024)
        return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? (String(cString: buf) as NSString).lastPathComponent : "pid \(pid)"
    }

    /// The same key press as the play/pause key on the keyboard.
    /// Posted with the modifier keys as they are right now. A press posted with "no modifiers" reads to the system as
    /// the talk key being released, which ended every dictation the instant it started.
    static func pressPlayPause() {
        let key = 16  // NX_KEYTYPE_PLAY
        let held = CGEventSource.flagsState(.combinedSessionState)
        for down in [true, false] {
            let data1 = (key << 16) | ((down ? 0xA : 0xB) << 8)
            guard let e = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1),
                  let cg = e.cgEvent else { continue }
            cg.flags = held
            cg.post(tap: .cghidEventTap)
        }
    }
}
