import Foundation

/// Whether to press the system play/pause key when recording starts. Only when something is actually playing:
/// a blind press on a quiet Mac starts Apple Music, a bug another dictation app shipped.
public enum MediaGate {
    public static func shouldPause(enabled: Bool, outputRunning: Bool) -> Bool { enabled && outputRunning }
    /// Sound louder than this, heard for a fifth of a second, means something is really playing (about -54 dB).
    public static let audible: Float = 0.002
    public static func isPlaying(peak: Float?) -> Bool { (peak ?? 0) > audible }
    /// Heard nothing, but Chrome holds the speakers open: a video can sit in a quiet moment for that quarter second
    /// (Nov 9 2026), so Chrome is asked directly. Chrome holds the speakers open when paused too, so its answer, not
    /// the open speakers, decides.
    public static func askChromeWhenQuiet(peak: Float?, chromePlaying: Bool) -> Bool { !isPlaying(peak: peak) && chromePlaying }
    /// Resume only what we paused, only once no new recording has taken over the pause, and never when something
    /// is already playing: the play/pause key is a switch, so pressing it then would pause that sound, or start a
    /// second video beside it when the Mac has picked another player.
    public static func shouldResume(paused: Bool, recordingAgain: Bool = false, playingNow: Bool = false) -> Bool {
        paused && !recordingAgain && !playingNow
    }

    /// Apps that pass every sound through themselves, so they look busy even when nothing plays.
    public static let routers = ["boom 3d", "boom3d", "soundsource", "eqmac", "audio hijack", "krisp", "loopback",
                                 "background music", "coreaudiod", "finetune"]

    /// Sound that is never a video or a song: system alerts, Siri's listener, other dictation apps' beeps. Pressing
    /// play/pause because one of these made a noise starts whatever video the Mac last had paused.
    public static let notMedia = ["systemsoundserverd", "corespeechd", "monologue", "wispr flow", "superwhisper", "voiceink"]

    /// True for apps whose sound can be a video or a song, so their loudness decides the pause.
    public static func isMedia(_ name: String) -> Bool {
        let n = name.lowercased()
        return !isRouter(name) && !notMedia.contains { n.contains($0) }
    }

    public static func isRouter(_ name: String) -> Bool {
        let n = name.lowercased()
        return routers.contains { n.contains($0) }
    }
}
