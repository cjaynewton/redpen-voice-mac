import AVFoundation
import CoreMedia

/// The microphone, kept warm. Capture runs through AVCaptureSession, which takes a named device (the audio engine
/// ignored the choice and kept reading the system default) and hands back audio already in the engine's format.
/// The last moment of audio sits in a ring, so the syllable said as the key went down is kept. The cost is the
/// orange mic dot staying lit while the app runs.
final class Recorder: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private var session: AVCaptureSession?
    private let queue = DispatchQueue(label: "redpen.voice.mic")
    private var target: AVAudioFormat?
    /// The format buffers are handed over in (the engine's), once the mic has started.
    var format: AVAudioFormat? { target }
    /// True while the capture session is really running (the name stays after a stop).
    var isRunning: Bool { session?.isRunning ?? false }
    private let lock = NSLock()
    private var ring: [AVAudioPCMBuffer] = []
    private var ringFrames: AVAudioFrameCount = 0
    private var preRollFrames: AVAudioFrameCount = 0
    private var live: ((AVAudioPCMBuffer) -> Void)?
    /// The meeting has its own feed. Starting or ending a dictation never detaches the recording.
    private var meetingFeed: ((AVAudioPCMBuffer) -> Void)?
    /// The level while nobody is talking, for the first window's microphone check. Called on the mic queue.
    private var watcher: ((Float) -> Void)?
    func watchLevel(_ f: ((Float) -> Void)?) { lock.lock(); watcher = f; lock.unlock() }
    private var level: ((Float) -> Void)?
    private var firstBuffer = true
    private(set) var inputName = ""
    private(set) var currentUID = ""
    private(set) var pushedFrames: AVAudioFrameCount = 0
    private(set) var peak: Float = 0
    /// Which microphone to read; empty means the system default.
    var deviceUID = ""
    private var channels = 1

    /// Starts capture on the chosen mic and keeps it running. Safe to call again; it restarts.
    func start(format: AVAudioFormat, preRoll seconds: Double = 0.6) throws {
        stopEngine()
        target = format
        preRollFrames = AVAudioFrameCount(seconds * format.sampleRate)
        // An empty choice follows the Mac's own input setting, read fresh from CoreAudio every time.
        let want = deviceUID.isEmpty ? (Mics.defaultInput()?.uid ?? "") : deviceUID
        let device = (want.isEmpty ? nil : AVCaptureDevice(uniqueID: want)) ?? AVCaptureDevice.default(for: .audio)
        guard let device else { throw NSError(domain: "RedpenVoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "No microphone"]) }
        let s = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard s.canAddInput(input) else { throw NSError(domain: "RedpenVoice", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot read \(device.localizedName)"]) }
        s.addInput(input)
        let out = AVCaptureAudioDataOutput()
        let isFloat = format.commonFormat == .pcmFormatFloat32
        // Every channel the device has, kept separate. Only the first two are read (the louder one): on a Focusrite
        // interface channels 3 and 4 are a loopback of the Mac's own sound, which put the video into the transcript.
        var deviceChannels = 1
        if let asbd = device.activeFormat.formatDescription.audioStreamBasicDescription { deviceChannels = max(1, Int(asbd.mChannelsPerFrame)) }
        channels = deviceChannels
        out.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: deviceChannels,
                             AVLinearPCMBitDepthKey: isFloat ? 32 : 16, AVLinearPCMIsFloatKey: isFloat, AVLinearPCMIsBigEndianKey: false,
                             AVLinearPCMIsNonInterleaved: true]
        out.setSampleBufferDelegate(self, queue: queue)
        guard s.canAddOutput(out) else { throw NSError(domain: "RedpenVoice", code: 4, userInfo: [NSLocalizedDescriptionKey: "Cannot capture audio"]) }
        s.addOutput(out)
        firstBuffer = true
        s.startRunning()
        session = s
        inputName = device.localizedName
        currentUID = device.uniqueID
        Log.note("mic: warm on \(inputName), \(deviceChannels) ch -> \(Int(format.sampleRate)) Hz \(isFloat ? "float" : "int16"), running \(s.isRunning)")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let target, let (buf, ch) = Recorder.pcm(sb, format: target, channels: channels) else { return }
        if firstBuffer { firstBuffer = false; Log.note("mic: first buffer \(buf.frameLength) frames, reading channel \(ch + 1) of \(channels)") }
        receive(buf)
    }

    /// Already formatted PCM. The passive test calls this same handoff without opening capture.
    func receive(_ buf: AVAudioPCMBuffer) {
        lock.lock()
        let talking = live, meeting = meetingFeed, watching = watcher, meter = level
        if talking != nil {
            pushedFrames += buf.frameLength
            peak = max(peak, Recorder.peak(buf))
        } else {
            ring.append(buf); ringFrames += buf.frameLength
            while ringFrames > preRollFrames, let first = ring.first { ring.removeFirst(); ringFrames -= first.frameLength }
        }
        lock.unlock()
        meeting?(buf)
        talking?(buf)
        if meter != nil || watching != nil { let v = Recorder.loudness(buf); meter?(v); watching?(v) }
    }

    /// The key went down: hand over the pre-roll, then everything live. Returns the pre-roll's length in frames.
    @discardableResult
    func begin(onBuffer: @escaping (AVAudioPCMBuffer) -> Void, onLevel: @escaping (Float) -> Void) -> AVAudioFrameCount {
        lock.lock()
        let pre = ring; ring.removeAll(); ringFrames = 0
        live = onBuffer
        let preFrames = pre.reduce(0) { $0 + $1.frameLength }
        pushedFrames = preFrames; peak = pre.reduce(0) { max($0, Recorder.peak($1)) }
        level = onLevel
        for b in pre { onBuffer(b) }
        lock.unlock()
        return preFrames
    }

    /// A separate meeting feed, sharing the same warm microphone and its pre-roll.
    @discardableResult
    func beginMeeting(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) -> AVAudioFrameCount {
        lock.withLock {
            meetingFeed = onBuffer
            for buffer in ring { onBuffer(buffer) }
            return ringFrames
        }
    }
    func endMeeting() { lock.withLock { meetingFeed = nil } }

    /// The key came up: stop handing audio over. Capture keeps running for next time.
    func end() {
        lock.withLock { live = nil; level = nil }
    }

    func stopEngine() {
        session?.stopRunning()
        session = nil
        lock.withLock { ring.removeAll(); ringFrames = 0; live = nil; level = nil; meetingFeed = nil }
    }

    /// Copies the louder of the first two captured channels into a PCM buffer of the engine's format.
    private static func pcm(_ sb: CMSampleBuffer, format: AVAudioFormat, channels: Int) -> (AVAudioPCMBuffer, Int)? {
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0, let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        let n = max(1, channels)
        let size = MemoryLayout<AudioBufferList>.size + (n - 1) * MemoryLayout<AudioBuffer>.size
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let ablPtr = raw.assumingMemoryBound(to: AudioBufferList.self)
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: ablPtr, bufferListSize: size,
                                                                              blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block)
        guard status == noErr else { return nil }
        let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
        let bytesPerFrame = format.commonFormat == .pcmFormatInt16 ? 2 : 4
        // Energy of the first two channels; the louder wins.
        func energy(_ b: AudioBuffer) -> Float {
            guard let d = b.mData else { return 0 }
            let count = Int(b.mDataByteSize) / bytesPerFrame
            if bytesPerFrame == 2 { let p = d.assumingMemoryBound(to: Int16.self); var e: Float = 0; for i in 0..<count { let v = Float(p[i]); e += v * v }; return e }
            let p = d.assumingMemoryBound(to: Float.self); var e: Float = 0; for i in 0..<count { e += p[i] * p[i] }; return e
        }
        var pick = 0
        if abl.count > 1, energy(abl[1]) > energy(abl[0]) { pick = 1 }
        guard pick < abl.count, let src = abl[pick].mData else { return nil }
        let bytes = Int(abl[pick].mDataByteSize)
        if format.commonFormat == .pcmFormatInt16, let dst = out.int16ChannelData?[0] { memcpy(dst, src, min(bytes, frames * 2)) }
        else if format.commonFormat == .pcmFormatFloat32, let dst = out.floatChannelData?[0] { memcpy(dst, src, min(bytes, frames * 4)) }
        else { return nil }
        out.frameLength = AVAudioFrameCount(frames)
        return (out, pick)
    }

    private static func samples(_ buf: AVAudioPCMBuffer) -> [Float] {
        let n = Int(buf.frameLength)
        if let d = buf.floatChannelData?[0] { return (0..<n).map { d[$0] } }
        if let d = buf.int16ChannelData?[0] { return (0..<n).map { Float(d[$0]) / 32768 } }
        return []
    }

    static func peak(_ buf: AVAudioPCMBuffer) -> Float { samples(buf).reduce(0) { max($0, abs($1)) } }

    /// Loudness 0 to 1 for the level bar.
    private static func loudness(_ buf: AVAudioPCMBuffer) -> Float {
        let s = samples(buf)
        guard !s.isEmpty else { return 0 }
        let rms = sqrt(s.reduce(0) { $0 + $1 * $1 } / Float(s.count))
        let db = 20 * log10(max(rms, 1e-6))
        return min(1, max(0, (db + 50) / 50))
    }
}
