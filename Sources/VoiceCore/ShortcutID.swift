import Foundation

/// The Carbon hot-key ids Voice registers. Shortcut keeps one action per id, so two shortcuts sharing an id
/// silently take each other's action. An enum keeps every id distinct: the compiler rejects a duplicate raw value.
public enum ShortcutID: UInt32, CaseIterable, Sendable {
    /// Control-Option-V: paste the last dictation.
    case pasteLast = 1
    /// Control-Option-Z: take the last dictation back.
    case takeBack = 2
    /// Control-Option-S: swap in the other engine's hearing of a marked word.
    case swapRisky = 3
    /// Escape, only while a dictation is running: throw it away.
    case escape = 4
}
