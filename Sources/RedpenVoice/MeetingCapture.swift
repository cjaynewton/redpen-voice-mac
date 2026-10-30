import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import VoiceCore

/// One track of a meeting, written to disk as it records (D-951): 16 kHz mono 16-bit samples appended to a plain
/// file, so a quit or crash keeps everything up to the last moment and nothing is held whole in memory.
final class TrackWriter: @unchecked Sendable {
    let url: URL
    private let handle: FileHandle
    private let queue: DispatchQueue
    private let lock = NSLock()
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(MeetingManifest.rate), channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var source: AVAudioFormat?
    private var written = 0
    private var loudest: Float = 0
    private var started = false
    private var closed = false
    /// Called once, on the writer's queue, when the first samples arrive.
    var onFirst: ((Date) -> Void)?
    /// The microphone track: a stretch that never arrived (a Bluetooth mic dropping out) is written as silence, by
    /// the time buffers arrive, so later lines keep their true time against the other track.
    private let fillGaps: Bool
    private var firstArrival: Date?
    private var heardSeconds = 0.0
    private var lead = -Double.infinity

    init(url: URL, fillGaps: Bool = false) throws {
        self.url = url
        self.fillGaps = fillGaps
        queue = DispatchQueue(label: "redpen.meeting.\(url.deletingPathExtension().lastPathComponent)")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw NSError(domain: "RedpenVoice", code: 20, userInfo: [NSLocalizedDescriptionKey: "Cannot create \(url.lastPathComponent)"])
        }
        handle = try FileHandle(forWritingTo: url)
    }

    /// Samples on disk so far, and the loudest of them (0 to 1).
    var frames: Int { lock.withLock { written } }
    var peak: Float { lock.withLock { loudest } }

    /// A buffer from the microphone, in whatever format the engine asked the mic for.
    func write(_ buffer: AVAudioPCMBuffer) {
        let arrived = Date()
        queue.async { [self] in append(buffer, arrived: arrived) }
    }

    /// What the Mac played, already mixed to one channel, at the output device's rate.
    func write(mono: [Float], rate: Double) {
        guard !mono.isEmpty, let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(mono.count)) else { return }
        b.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: mono.count) }
        write(b)
    }

    private func append(_ buffer: AVAudioPCMBuffer, arrived: Date) {
        guard !lock.withLock({ closed }), buffer.frameLength > 0 else { return }
        if !started { started = true; onFirst?(arrived.addingTimeInterval(-Double(buffer.frameLength) / buffer.format.sampleRate)) }
        if fillGaps {
            let first = firstArrival ?? arrived
            firstArrival = first
            heardSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
            // How far the audio runs ahead of the clock; steady while buffers flow, and it drops by however long a
            // stretch went missing.
            let now = heardSeconds - arrived.timeIntervalSince(first)
            if now < lead - 1 {
                let missing = lead - now
                appendSilence(missing)
                heardSeconds += missing
                Log.note("meeting: microphone missing for \(String(format: "%.1f", missing))s, kept as silence")
            } else { lead = max(lead, now) }
        }
        let samples = convert(buffer)
        guard !samples.isEmpty else { return }
        var peak: Float = 0
        var ints = [Int16](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            let v = max(-1, min(1, samples[i]))
            peak = max(peak, abs(v))
            ints[i] = Int16(v * 32767).littleEndian
        }
        let data = ints.withUnsafeBufferPointer { Data(buffer: $0) }
        do { try handle.write(contentsOf: data) } catch { Log.note("meeting: write failed on \(url.lastPathComponent), \(MeetingNotes.code(error))"); return }
        lock.withLock { written += samples.count; loudest = max(loudest, peak) }
    }

    /// Silence straight to disk, a second at a time, however long the stretch.
    func appendSilence(_ seconds: Double) {
        var left = Int(seconds * target.sampleRate)
        let second = Data(count: Int(target.sampleRate) * 2)
        while left > 0 {
            let n = min(left, Int(target.sampleRate))
            do { try handle.write(contentsOf: n == Int(target.sampleRate) ? second : Data(count: n * 2)) } catch { return }
            lock.withLock { written += n }
            left -= n
        }
    }

    /// Silence for a stretch of the Mac's sound the tap never delivered, written in order with the rest.
    func writeSilence(_ seconds: Double) { queue.async { [self] in if !lock.withLock({ closed }) { appendSilence(seconds) } } }

    /// To 16 kHz mono float. Same format passes straight through; anything else goes through one converter kept for
    /// the whole track, so the resampling carries on smoothly from one buffer to the next.
    private func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let f = buffer.format
        if f.sampleRate == target.sampleRate, f.channelCount == 1, f.commonFormat == .pcmFormatFloat32, let d = buffer.floatChannelData?[0] {
            return Array(UnsafeBufferPointer(start: d, count: Int(buffer.frameLength)))
        }
        if source != f { source = f; converter = AVAudioConverter(from: f, to: target) }
        guard let converter else { return [] }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * target.sampleRate / f.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if given { outStatus.pointee = .noDataNow; return nil }
            given = true; outStatus.pointee = .haveData; return buffer
        }
        guard status != .error, let d = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: d, count: Int(out.frameLength)))
    }

    /// Waits for what is queued, then closes the file. Safe to call twice.
    func close() {
        queue.sync {
            guard !lock.withLock({ closed }) else { return }
            lock.withLock { closed = true }
            try? handle.synchronize()
            try? handle.close()
        }
    }
}

/// Everything the Mac plays, from every app but Redpen Voice itself, through a Core Audio process tap: the "Others"
/// track. Needs the system audio permission; without it the tap hears silence.
final class SystemTap {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "redpen.meeting.tap")
    private var rateListener: AudioObjectPropertyListenerBlock?

    /// The tap's rate and where its audio should have reached by the host clock, read on the tap's queue.
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var r: Double
        private var startHost: UInt64?
        /// Seconds of audio delivered so far.
        private var heard = 0.0
        init(rate: Double) { r = rate }
        var rate: Double { lock.withLock { r } }
        func set(rate: Double) { lock.withLock { r = rate } }
        /// Frames missing before a buffer arriving at `time`, worth filling only past half a second. Counts the buffer.
        func gap(at time: AudioTimeStamp, frames n: Int) -> Int? {
            lock.withLock {
                defer { heard += Double(n) / r }
                guard time.mFlags.contains(.hostTimeValid) else { return nil }
                guard let s = startHost else { startHost = time.mHostTime; return nil }
                var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
                let elapsed = Double(time.mHostTime &- s) * Double(tb.numer) / Double(tb.denom) / 1e9
                let missing = elapsed - heard
                guard missing > 0.5 else { return nil }
                heard += missing
                return Int(missing * r)
            }
        }
    }

    /// Redpen Voice's own Core Audio process, left out of the tap. Unknown when it has never touched audio.
    private static func ownProcess() -> AudioObjectID {
        var pid = ProcessInfo.processInfo.processIdentifier
        var obj = AudioObjectID(kAudioObjectUnknown), size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &obj)
        return obj
    }

    func start(into writer: TrackWriter) throws {
        let me = Self.ownProcess()
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: me == kAudioObjectUnknown ? [] : [me])
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = .unmuted
        func fail(_ what: String, _ status: OSStatus) -> NSError {
            Log.note("meeting: tap failed \(what), status \(status)")
            return NSError(domain: "RedpenVoice", code: 21, userInfo: [NSLocalizedDescriptionKey: "Can't hear the Mac's sound (\(what))"])
        }
        var status = AudioHardwareCreateProcessTap(desc, &tap)
        guard status == noErr else { throw fail("creating the tap", status) }
        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Redpen Voice meeting",
            kAudioAggregateDeviceUIDKey: "redpen-voice-meeting-" + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        status = AudioHardwareCreateAggregateDevice(agg as CFDictionary, &device)
        guard status == noErr else { AudioHardwareDestroyProcessTap(tap); tap = AudioObjectID(kAudioObjectUnknown); throw fail("creating the device", status) }
        var rate = 48000.0, rateSize = UInt32(MemoryLayout<Double>.size)
        var rateAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(device, &rateAddr, 0, nil, &rateSize, &rate)
        // The rate can change mid-call (headphones connected); the track is resampled at whatever it is now.
        let clock = Clock(rate: rate)
        let dev = device
        rateListener = { _, _ in
            var r = 0.0, size = UInt32(MemoryLayout<Double>.size)
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &r) == noErr, r > 0 { clock.set(rate: r); Log.note("meeting: Mac sound now \(Int(r)) Hz") }
        }
        AudioObjectAddPropertyListenerBlock(device, &rateAddr, queue, rateListener!)
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { _, input, time, _, _ in
            // Every channel, whether they come together in one buffer or one buffer each, mixed to one.
            var mono: [Float] = []
            var parts = 0
            for b in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                guard let p = b.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = Int(b.mDataByteSize) / MemoryLayout<Float>.size
                let ch = max(1, Int(b.mNumberChannels)), frames = n / ch
                if mono.isEmpty { mono = [Float](repeating: 0, count: frames) }
                for f in 0..<min(frames, mono.count) { var sum: Float = 0; for c in 0..<ch { sum += p[f * ch + c] }; mono[f] += sum / Float(ch) }
                parts += 1
            }
            guard parts > 0 else { return }
            // A stretch the tap never delivered (the output device changing) is written as silence, so every line
            // after it keeps its true time.
            let rate = clock.rate
            if let gap = clock.gap(at: time.pointee, frames: mono.count), gap > 0 {
                writer.writeSilence(Double(gap) / rate)
                Log.note("meeting: Mac sound missing for \(String(format: "%.1f", Double(gap) / rate))s, kept as silence")
            }
            writer.write(mono: parts == 1 ? mono : mono.map { $0 / Float(parts) }, rate: rate)
        }
        if status == noErr, let proc { status = AudioDeviceStart(device, proc) }
        guard status == noErr, proc != nil else { stop(); throw fail("starting", status) }
        Log.note("meeting: tap on, \(Int(rate)) Hz, own process \(me == kAudioObjectUnknown ? "not found" : "left out")")
    }

    /// Stops and removes the tap. Called off the tap's own queue: stopping a device from its own audio queue froze
    /// the app once (Oct 22 2026, SoundTap).
    func stop() {
        if let rateListener {
            var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(device, &a, queue, rateListener)
        }
        rateListener = nil
        if let proc { AudioDeviceStop(device, proc); AudioDeviceDestroyIOProcID(device, proc) }
        proc = nil
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device) }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap) }
        device = AudioObjectID(kAudioObjectUnknown); tap = AudioObjectID(kAudioObjectUnknown)
    }
}

/// A meeting being recorded: its folder of work in Application Support (not synced, not in the meetings folder until
/// the notes are written), the two tracks and the manifest that lets the next launch finish it.
@MainActor
final class MeetingRecording {
    let folder: URL
    let started: Date
    private(set) var manifest: MeetingManifest
    private let me: TrackWriter
    private let others: TrackWriter
    private let tap = SystemTap()
    private let recorder: Recorder

    init(recorder: Recorder, started: Date = Date()) throws {
        self.recorder = recorder
        self.started = started
        let fm = FileManager.default
        try fm.createDirectory(at: MeetingNotes.workDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = Meeting.uniqueBase(Meeting.baseName(started)) { fm.fileExists(atPath: MeetingNotes.workDir.appendingPathComponent($0).path) }
        folder = MeetingNotes.workDir.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        manifest = MeetingManifest(started: started)
        me = try TrackWriter(url: folder.appendingPathComponent(MeetingManifest.meFile), fillGaps: true)
        others = try TrackWriter(url: folder.appendingPathComponent(MeetingManifest.othersFile))
        try MeetingNotes.save(manifest, in: folder)
    }

    /// Starts both tracks. The microphone must already be warm; the tap may fail (no permission), and then the
    /// meeting still records you.
    func start() -> Bool {
        others.onFirst = { [weak self] at in
            DispatchQueue.main.async { guard let self else { return }; self.manifest.othersOffset = at.timeIntervalSince(self.started); self.saveManifest() }
        }
        var tapOK = true
        do { try tap.start(into: others) } catch { tapOK = false }
        // The pre-roll comes first and is older than the moment the mic is handed over: its time is worked out from
        // its length, after however long the tap took to start.
        let rate = recorder.format?.sampleRate ?? Double(MeetingManifest.rate)
        let handed = Date()
        let pre = Double(recorder.begin(onBuffer: { [me] in me.write($0) }, onLevel: { _ in })) / rate
        manifest.meOffset = handed.timeIntervalSince(started) - pre
        saveManifest()
        Log.note("meeting: recording, mic \(recorder.inputName), pre-roll \(String(format: "%.2f", pre))s, Mac sound \(tapOK ? "on" : "off")")
        return tapOK
    }

    private func saveManifest() { try? MeetingNotes.save(manifest, in: folder) }

    /// Stops both tracks, flushes them to disk and marks the meeting stopped. Returns the folder to write notes from.
    func stop() -> URL {
        recorder.end()
        tap.stop()
        me.close(); others.close()
        manifest.stopped = Date()
        saveManifest()
        let rate = Double(MeetingManifest.rate)
        Log.note("meeting: stopped, me \(String(format: "%.0f", Double(me.frames) / rate))s peak \(String(format: "%.3f", me.peak)), others \(String(format: "%.0f", Double(others.frames) / rate))s peak \(String(format: "%.3f", others.peak))")
        return folder
    }

    var seconds: Double { Date().timeIntervalSince(started) }
    /// Nothing at all heard from the Mac so far: most likely the system audio permission is off.
    var macSilent: Bool { others.peak == 0 }
}
