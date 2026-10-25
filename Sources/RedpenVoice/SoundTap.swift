import AudioToolbox
import CoreAudio
import Foundation

/// Listens to what some apps are playing out loud for a moment and reports how loud it was, 0 to 1.
/// Used only to decide whether to press pause: apps like Chrome and Boom 3D hold the speakers open while silent,
/// so "the speakers are on" is not the same as "something is playing". Needs the one-time system audio permission;
/// without it the tap hears silence and nothing is paused.
enum SoundTap {
    /// `processes`: listen to these apps only (CoreAudio process objects), so an alert sound or another app's beep
    /// never counts as a video playing.
    static func loudness(of processes: [AudioObjectID], for seconds: Double, done: @escaping @Sendable (Float?) -> Void) {
        guard !processes.isEmpty else { done(nil); return }
        guard running.claim() else { done(nil); return }
        let done: @Sendable (Float?) -> Void = { v in running.release(); done(v) }
        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { done(nil); return }
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Redpen Voice listen",
            kAudioAggregateDeviceUIDKey: "redpen-voice-tap-" + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        var dev = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(agg as CFDictionary, &dev) == noErr else {
            AudioHardwareDestroyProcessTap(tap); done(nil); return
        }
        let box = Peak()
        var proc: AudioDeviceIOProcID?
        let q = DispatchQueue(label: "redpen.voice.tap")
        let ok = AudioDeviceCreateIOProcIDWithBlock(&proc, dev, q) { _, input, _, _, _ in
            for b in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
                var m: Float = 0
                for i in 0..<n { m = max(m, abs(p[i])) }
                box.value = max(box.value, m)
                box.frames += n
            }
        } == noErr
        guard ok, let proc, AudioDeviceStart(dev, proc) == noErr else {
            if let proc { AudioDeviceDestroyIOProcID(dev, proc) }
            AudioHardwareDestroyAggregateDevice(dev); AudioHardwareDestroyProcessTap(tap); done(nil); return
        }
        // Shut down from a different queue than the one the audio arrives on. Stopping the device from its own
        // audio queue deadlocked CoreAudio and froze the whole app (Oct 22 2026).
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
            AudioDeviceStop(dev, proc)
            AudioDeviceDestroyIOProcID(dev, proc)
            AudioHardwareDestroyAggregateDevice(dev)
            AudioHardwareDestroyProcessTap(tap)
            done(box.frames > 0 ? box.value : nil)
        }
    }

    private final class Peak: @unchecked Sendable { var value: Float = 0; var frames = 0 }

    /// Only one listen at a time, so two quick presses never stack taps.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock(); private var on = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if on { return false }; on = true; return true }
        func release() { lock.lock(); on = false; lock.unlock() }
    }
    private static let running = Flag()
}
