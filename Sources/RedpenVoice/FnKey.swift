import Foundation

/// What the Mac does with the Fn (globe) key by itself. Anything but "Do Nothing" fires along with Redpen Voice when
/// you hold Fn to talk: Apple's own dictation starts, the emoji picker opens, or the keyboard language changes.
enum FnKey {
    /// 0 Do Nothing, 1 Change Input Source, 2 Show Emoji & Symbols, 3 Start Dictation (Keyboard settings).
    static var usage: Int { UserDefaults(suiteName: "com.apple.HIToolbox")?.integer(forKey: "AppleFnUsageType") ?? 0 }

    /// What goes wrong, in a few words, or nil when Fn is set to Do Nothing.
    static var problem: String? {
        switch usage {
        case 1: return "Fn also changes your keyboard language"
        case 2: return "Fn also opens the emoji picker"
        case 3: return "Fn also starts Apple's dictation"
        default: return nil
        }
    }
}
