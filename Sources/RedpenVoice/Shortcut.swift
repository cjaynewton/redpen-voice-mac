import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts that work whichever app is in front: Control-Option-V pastes the last dictation,
/// Control-Option-Z takes it back. Same family as Redpen's Control-Option keys. Carbon's hot keys need no extra
/// permission and never see other keystrokes.
@MainActor
final class Shortcut {
    nonisolated(unsafe) private static var actions: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var installed = false
    private var ref: EventHotKeyRef?

    /// Lets go of the key, so a shortcut that's switched off stops taking it from other apps.
    deinit { if let ref { UnregisterEventHotKey(ref) } }

    init(id: UInt32, keyCode: Int, modifiers: Int = controlKey | optionKey, name: String,
         action: @escaping () -> Void) {
        Shortcut.actions[id] = action
        if !Shortcut.installed {
            Shortcut.installed = true
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            // The dispatcher target sees hot keys whichever app is in front; the application target can miss them.
            InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hk)
                let id = hk.id
                DispatchQueue.main.async { Shortcut.actions[id]?() }
                return noErr
            }, 1, &spec, nil, nil)
        }
        let hid = EventHotKeyID(signature: OSType(0x5244_5056), id: id)  // "RDPV", not Redpen's "RDPN"
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hid, GetEventDispatcherTarget(), 0, &ref)
        Log.note(status == noErr ? "shortcut \(name) ready" : "shortcut \(name) failed (\(status)), another app may own it")
    }
}
