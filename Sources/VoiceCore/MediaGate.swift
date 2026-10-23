import Foundation

/// Whether to press the system play/pause key when recording starts. Only when something is actually playing:
/// a blind press on a quiet Mac starts Apple Music, a bug another dictation app shipped.
public enum MediaGate {
    public static func shouldPause(enabled: Bool, outputRunning: Bool) -> Bool { enabled && outputRunning }
    /// Sound louder than this, heard for a fifth of a second, means something is really playing (about -54 dB).
    public static let audible: Float = 0.002
    public static func isPlaying(peak: Float?) -> Bool { (peak ?? 0) > audible }
    /// Resume only what we paused.
    public static func shouldResume(paused: Bool) -> Bool { paused }

    /// Apps that pass every sound through themselves, so they look busy even when nothing plays.
    public static let routers = ["boom 3d", "boom3d", "soundsource", "eqmac", "audio hijack", "krisp", "loopback",
                                 "background music", "coreaudiod", "finetune"]

    public static func isRouter(_ name: String) -> Bool {
        let n = name.lowercased()
        return routers.contains { n.contains($0) }
    }
}
