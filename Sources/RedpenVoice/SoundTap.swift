import AudioToolbox
import CoreAudio
import Foundation
import VoiceCore

/// Listens to what some apps are playing out loud for a moment and reports how loud it was, 0 to 1.
/// Used only to decide whether to press pause: apps like Chrome and Boom 3D hold the speakers open while silent,
/// so "the speakers are on" is not the same as "something is playing". Needs the one-time system audio permission;
/// without it the tap hears silence and nothing is paused.
enum SoundTap {
    /// `processes`: listen to these apps only (CoreAudio process objects), so an alert sound or another app's beep
    /// never counts as a video playing.
    /// What the tapped apps played, kept when `record` is given: their words are taken off the start of a dictation
    /// instead of blanking the start (D-817).
    final class Recording: @unchecked Sendable {
        private let lock = NSLock()
        private var parts: [(rate: Double, samples: [Float])] = []
        let continuous: Bool
        private var closed = false
        private var recent: Float = 0
        private var expired = false
        var truncated: Bool { lock.lock(); defer { lock.unlock() }; return expired }
        init(continuous: Bool = false) { self.continuous = continuous }
        func add(_ samples: [Float], rate: Double) {
            lock.lock(); defer { lock.unlock() }
            parts.append((rate, samples))
            recent = max(recent, samples.map(abs).max() ?? 0)
        }
        func stop() { lock.lock(); closed = true; lock.unlock() }
        var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
        func expire() { lock.lock(); expired = !closed; closed = true; lock.unlock() }
        /// Uses the same still-running tap, so there is no unrecorded gap while Chrome answers pause.
        func waitForQuiet(tries: Int = 8, done: @escaping @Sendable (Date) -> Void) {
            lock.lock(); recent = 0; lock.unlock()
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.1) { [self] in
                lock.lock(); let peak = recent; lock.unlock()
                if isClosed || !MediaGate.isPlaying(peak: peak) { stop(); done(Date()) }
                else if tries <= 0 { expire(); done(Date()) }
                else { waitForQuiet(tries: tries - 1, done: done) }
            }
        }
        /// Loudest sample heard, 0 to 1.
        var peak: Float { lock.lock(); defer { lock.unlock() }; return parts.map { $0.samples.map(abs).max() ?? 0 }.max() ?? 0 }
        /// Everything heard, as 16 kHz mono for the speech engines.
        func mono16k() -> [Float] {
            lock.lock(); let all = parts; lock.unlock()
            var out: [Float] = []
            var position = 0.0, previousRate = 0.0
            for p in all where p.rate > 0 {
                if p.rate != previousRate { position = 0; previousRate = p.rate }
                let step = p.rate / 16000
                while Int(position) < p.samples.count { out.append(p.samples[Int(position)]); position += step }
                position -= Double(p.samples.count)
            }
            return out
        }
    }

    static func loudness(of processes: [AudioObjectID], for seconds: Double, record: Recording? = nil, done: @escaping @Sendable (Float?) -> Void) {
        guard !processes.isEmpty else { Log.note("media listen: no media processes"); done(nil); return }
        let request = Listen(processes: processes, seconds: seconds, record: record, done: done)
        if let next = listens.submit(request) { setup.async { listen(next) } }
        else { Log.note("media listen: busy, queued \(seconds)s listen") }
    }

    private struct Listen: Sendable {
        let processes: [AudioObjectID]
        let seconds: Double
        let record: Recording?
        let done: @Sendable (Float?) -> Void
    }
    private static let listens = MediaListenQueue<Listen>()
    private static let setup = DispatchQueue(label: "redpen.voice.tap-setup", qos: .userInitiated)

    /// A diagnostic sample never queues behind or stacks on another listen. False means try next time.
    static func loudnessIfIdle(of processes: [AudioObjectID], for seconds: Double, done: @escaping @Sendable (Float?) -> Void) -> Bool {
        guard !processes.isEmpty,
              let next = listens.submitIfIdle(Listen(processes: processes, seconds: seconds, record: nil, done: done)) else { return false }
        setup.async { listen(next) }
        return true
    }

    private static func listen(_ request: Listen) {
        let processes = request.processes, seconds = request.seconds, record = request.record
        let release: @Sendable () -> Void = {
            let next = listens.finish()
            if let next { setup.async { listen(next) } }
        }
        let done: @Sendable (Float?) -> Void = { v in release(); request.done(v) }
        let desc = CATapDescription(stereoMixdownOfProcesses: processes)
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(desc, &tap)
        guard tapStatus == noErr else {
            Log.note("media listen: tap failed creating process tap, status \(tapStatus)"); done(nil); return
        }
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Redpen Voice listen",
            kAudioAggregateDeviceUIDKey: "redpen-voice-tap-" + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        var dev = AudioObjectID(kAudioObjectUnknown)
        let deviceStatus = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &dev)
        guard deviceStatus == noErr else {
            Log.note("media listen: tap failed creating aggregate device, status \(deviceStatus)")
            AudioHardwareDestroyProcessTap(tap); done(nil); return
        }
        let box = Peak()
        var rate = 48000.0
        var rateSize = UInt32(MemoryLayout<Double>.size)
        var rateAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(dev, &rateAddr, 0, nil, &rateSize, &rate)
        let deviceRate = rate
        var proc: AudioDeviceIOProcID?
        let q = DispatchQueue(label: "redpen.voice.tap")
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&proc, dev, q) { _, input, _, _, _ in
            var mono: [Float] = []
            var parts = 0
            for b in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
                var m: Float = 0
                for i in 0..<n { m = max(m, abs(p[i])) }
                box.add(peak: m, frames: n)
                // Every channel, whether they come together in one buffer or one buffer each, mixed to one.
                if record != nil {
                    let ch = max(1, Int(b.mNumberChannels)), frames = n / ch
                    if mono.isEmpty { mono = [Float](repeating: 0, count: frames) }
                    for f in 0..<min(frames, mono.count) { var sum: Float = 0; for c in 0..<ch { sum += p[f * ch + c] }; mono[f] += sum / Float(ch) }
                    parts += 1
                }
            }
            if let record, parts > 0 { record.add(parts == 1 ? mono : mono.map { $0 / Float(parts) }, rate: deviceRate) }
        }
        var startStatus = procStatus
        if procStatus == noErr, let proc { startStatus = AudioDeviceStart(dev, proc) }
        guard procStatus == noErr, let proc, startStatus == noErr else {
            Log.note("media listen: tap failed starting audio, IO proc status \(procStatus), start status \(startStatus), proc present \(proc != nil)")
            if let proc { AudioDeviceDestroyIOProcID(dev, proc) }
            AudioHardwareDestroyAggregateDevice(dev); AudioHardwareDestroyProcessTap(tap); done(nil); return
        }
        // Shut down from a different queue than the one the audio arrives on. Stopping the device from its own
        // audio queue deadlocked CoreAudio and froze the whole app (Oct 22 2026).
        let stop: @Sendable () -> Void = { [dev, tap] in
            AudioDeviceStop(dev, proc)
            AudioDeviceDestroyIOProcID(dev, proc)
            AudioHardwareDestroyAggregateDevice(dev)
            AudioHardwareDestroyProcessTap(tap)
            release()
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
            let peak = box.snapshot
            if peak.frames == 0 { Log.note("media listen: no audio frames (the app is paused or silent, or audio capture isn't allowed)") }
            if let record, record.continuous {
                request.done(peak.frames > 0 ? peak.value : nil)
                // The media decision owns this tap until quiet, cancellation, or the bounded deadline.
                finishRecording(record, deadline: Date().addingTimeInterval(4), stop: stop)
            } else { stop(); request.done(peak.frames > 0 ? peak.value : nil) }
        }
    }

    private static func finishRecording(_ record: Recording, deadline: Date, stop: @escaping @Sendable () -> Void) {
        if record.isClosed { stop(); return }
        if Date() >= deadline { record.expire(); stop(); return }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.05) {
            finishRecording(record, deadline: deadline, stop: stop)
        }
    }

    private final class Peak: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Float = 0
        private var frames = 0
        func add(peak: Float, frames n: Int) { lock.lock(); value = max(value, peak); frames += n; lock.unlock() }
        var snapshot: (value: Float, frames: Int) { lock.lock(); defer { lock.unlock() }; return (value, frames) }
    }
}
