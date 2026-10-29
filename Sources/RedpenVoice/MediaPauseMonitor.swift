import AppKit
import VoiceCore

/// Observes only. Never sends play/pause, changes the pause owner, or saves audio.
@MainActor
final class MediaPauseMonitor {
    private var players: [Media.Player] = []
    private var pausedAt = 0.0
    private var generation = 0
    private var active = false
    private var listening = false
    private var reported = false
    private var settled = false
    private var pauseID = UUID()
    private var work: DispatchWorkItem?

    func start(_ players: [Media.Player]) -> UUID {
        self.players = players
        pausedAt = ProcessInfo.processInfo.systemUptime
        reported = false
        settled = false
        pauseID = UUID()
        resume()
        return pauseID
    }

    /// The pause's initial sound must finish settling before it can count as a restart.
    func didSettle(_ id: UUID) {
        guard id == pauseID else { return }
        settled = true
        schedule()
    }

    func stop() {
        active = false
        generation += 1
        work?.cancel(); work = nil
    }

    /// A new recording can take over the same pause while the old resume check is listening.
    func resume() {
        stop()
        guard !players.isEmpty, !reported else { return }
        active = true
        schedule()
    }

    private func schedule() {
        guard active, settled, !reported else { return }
        let token = generation
        let next = DispatchWorkItem { [weak self] in
            guard let self, self.active, self.generation == token else { return }
            self.check(token)
        }
        work = next
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: next)
    }

    private func check(_ token: Int) {
        guard !listening else { schedule(); return }
        // Match the paused processes, using their current CoreAudio objects. Another app's sound is not a restart.
        let pids = Set(players.map(\.pid))
        let current = Media.playingApps().filter { pids.contains($0.pid) }
        guard !current.isEmpty else { schedule(); return }
        listening = true
        let started = SoundTap.loudnessIfIdle(of: current.map(\.object), for: 0.1) { [weak self] peak in
            DispatchQueue.main.async {
                guard let self else { return }
                self.listening = false
                guard self.active, self.generation == token else { return }
                if MediaGate.isPlaying(peak: peak) {
                    self.reported = true
                    let elapsed = ProcessInfo.processInfo.systemUptime - self.pausedAt
                    let front = NSWorkspace.shared.frontmostApplication
                    // DictationIM's installed bundle ID is com.apple.inputmethod.ironwood. Process presence does
                    // not prove it is listening or that it sent play, so the log calls this out explicitly.
                    let dictation = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.inputmethod.ironwood")
                    Log.note("media: playing again while pause held, \(String(format: "%.1f", elapsed))s since pause, apps [\(current.map(\.name).joined(separator: ", "))], loudness \(String(format: "%.4f", peak ?? 0)), frontmost \(front?.localizedName ?? "unknown") (\(front?.bundleIdentifier ?? "unknown")), Apple dictation process DictationIM running \(!dictation.isEmpty), pids [\(dictation.map { String($0.processIdentifier) }.joined(separator: ", "))] (process presence only)")
                } else { self.schedule() }
            }
        }
        if !started { listening = false; schedule() }
    }
}
