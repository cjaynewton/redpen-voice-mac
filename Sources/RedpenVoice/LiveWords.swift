import Foundation
import FluidAudio
import VoiceCore

/// A separate v2 manager. Dictation's selected engine, state, and decoder are never borrowed or changed.
actor LiveWordsEngine {
    static let shared = LiveWordsEngine()
    private var loading: Task<AsrManager, Error>?
    private let gate = Transcriber.Gate()
    nonisolated static var onDisk: Bool { AsrModels.modelsExist(at: AsrModels.defaultCacheDirectory(for: .v2), version: .v2) }

    func load() async throws -> AsrManager {
        if let loading { return try await loading.value }
        let task = Task.detached(priority: .background) {
            // FluidAudio's debug messages can contain words. Drop them at both sinks, even in a debug build.
            AppLogger.minimumLevel = .fault
            AppLogger.mirrorsToConsole = false
            let models = try await AsrModels.downloadAndLoad(version: .v2)
            let manager = AsrManager(config: .init(parallelChunkConcurrency: 1))
            try await manager.loadModels(models)
            return manager
        }
        loading = task
        do { return try await task.value }
        catch { loading = nil; throw error }
    }

    /// Lets the live model go after a meeting, so its memory isn't held until Voice quits. Loaded again next time.
    func unload() { loading = nil }

    func text(_ audio: [Float], control: LiveWordsControl) async throws -> String {
        let manager = try await load()
        try await gate.acquire()
        do {
            while true {
                let epoch = try await control.wait()
                let result = try await Transcriber.parakeetText(manager, audio, log: false)
                try Task.checkCancellation()
                // If a dictation arrived during prediction, let it finish and then reread this same piece.
                if LiveWordsPriority.shared.isCurrent(epoch), !control.paused {
                    await gate.release()
                    return result
                }
            }
        } catch { await gate.release(); throw error }
    }
}

final class LiveWordsControl: @unchecked Sendable {
    private let lock = NSLock()
    private var pause = false, stop = false
    var paused: Bool { lock.withLock { pause } }
    func setPaused(_ value: Bool) { lock.withLock { pause = value } }
    func cancel() { lock.withLock { stop = true } }
    func wait() async throws -> Int {
        while true {
            try Task.checkCancellation()
            let state = lock.withLock { (pause, stop) }
            if state.1 { throw CancellationError() }
            if !state.0, let epoch = LiveWordsPriority.shared.idleEpoch { return epoch }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

struct LiveWordsAudio: Sendable {
    var samples: [Float]
    var offset: Double = 0
    var ended = false
}

/// The production and file-test path. Read at most 0.1 s per track per turn, keep only each current line's audio,
/// and reread it every 1.5 s. While dictating or paused, leave the backlog in the existing recording, not in RAM.
enum LiveWordsRunner {
    static func run(control: LiveWordsControl, starts: [LiveWordsTrack: Int],
                    next: (LiveWordsTrack, Int) async throws -> LiveWordsAudio,
                    onLine: (LiveWordsLine) async -> Void,
                    onBuffer: (Int) -> Void = { _ in }) async throws {
        _ = try await control.wait()
        _ = try await LiveWordsEngine.shared.load()
        var segmenters = Dictionary(uniqueKeysWithValues: LiveWordsTrack.allCases.map {
            ($0, LiveWordsSegmenter(startSample: starts[$0] ?? 0))
        })
        var ended: Set<LiveWordsTrack> = [], failures = 0
        while ended.count < LiveWordsTrack.allCases.count {
            _ = try await control.wait()
            var received = false
            for track in LiveWordsTrack.allCases where !ended.contains(track) {
                _ = try await control.wait()
                // A read that fails (the file mid-write) is tried again next turn, not the end of live words.
                let input: LiveWordsAudio
                do { input = try await next(track, 1_600) }
                catch is CancellationError { throw CancellationError() }
                catch { failures += 1; if failures == 1 || failures % 20 == 0 { Log.note("live words: \(failures) pieces skipped") }; continue }
                received = received || !input.samples.isEmpty
                var pieces = segmenters[track]!.push(input.samples)
                if input.ended {
                    if let last = segmenters[track]!.finish() { pieces.append(last) }
                    ended.insert(track)
                } else if let preview = segmenters[track]!.preview() { pieces.append(preview) }
                onBuffer(segmenters.values.reduce(0) { $0 + $1.bufferedSamples } + pieces.reduce(0) { $0 + $1.audio.count })
                for piece in pieces {
                    // One piece the engine can't read is skipped, not the rest of the meeting (review, Nov 6 2026).
                    let text: String
                    do { text = try await LiveWordsEngine.shared.text(piece.audio, control: control) }
                    catch is CancellationError { throw CancellationError() }
                    catch { failures += 1; if failures == 1 || failures % 20 == 0 { Log.note("live words: \(failures) pieces skipped") }; continue }
                    _ = try await control.wait()
                    await onLine(LiveWordsLine(track: track, id: piece.id, start: input.offset + piece.start,
                                              end: input.offset + piece.speechEnd, text: text, final: piece.final))
                }
            }
            if !received { try await Task.sleep(for: .milliseconds(40)) }
        }
    }
}

/// Read-only views of the same PCM files the track writers append. Only fully saved frames are read. A late first
/// buffer can still supply its correct offset. These handles are owned by one detached worker, never the main actor.
final class LiveWordsPCMSource {
    struct Track: Sendable { var url: URL; var frames: Int; var offset: Double? }
    private var handles: [LiveWordsTrack: FileHandle] = [:]
    private var positions: [LiveWordsTrack: Int]
    private let snapshot: @MainActor () -> [LiveWordsTrack: Track]
    init(starts: [LiveWordsTrack: Int], snapshot: @escaping @MainActor () -> [LiveWordsTrack: Track]) {
        positions = starts; self.snapshot = snapshot
    }
    deinit { for handle in handles.values { try? handle.close() } }

    func next(_ track: LiveWordsTrack, maximum: Int) async throws -> LiveWordsAudio {
        guard let value = await snapshot()[track], let offset = value.offset else { return LiveWordsAudio(samples: []) }
        let position = positions[track] ?? 0
        let n = min(maximum, max(0, value.frames - position))
        guard n > 0 else { return LiveWordsAudio(samples: [], offset: offset) }
        let handle: FileHandle
        if let open = handles[track] { handle = open }
        else {
            handle = try FileHandle(forReadingFrom: value.url)
            try handle.seek(toOffset: UInt64(position * 2))
            handles[track] = handle
        }
        let data = try handle.read(upToCount: n * 2) ?? Data()
        guard data.count == n * 2 else { throw CocoaError(.fileReadCorruptFile) }
        let audio = data.withUnsafeBytes { bytes in
            (0..<n).map { Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768 }
        }
        positions[track] = position + n
        return LiveWordsAudio(samples: audio, offset: offset)
    }
}

/// One meeting's ephemeral session. Stop/close invalidates every callback before clearing both Swift and WebKit.
@MainActor
final class LiveWords {
    private let window = LiveWordsWindow()
    private var work: Task<Void, Never>?
    private var control: LiveWordsControl?
    private var clock: Timer?
    private var generation = 0
    private var lines = LiveWordsLines()
    private var status = ""
    private weak var recording: MeetingRecording?
    var onClose: () -> Void = {}

    func start(_ recording: MeetingRecording) {
        stop()
        self.recording = recording
        let mine = generation
        let control = LiveWordsControl(); self.control = control
        control.setPaused(recording.isPaused)
        status = LiveWordsEngine.onDisk ? "Loading the fast engine…" : "Downloading the fast engine (about 600 MB)…"
        window.onClose = { [weak self] in self?.stop(); self?.onClose() }
        window.show()
        refresh()
        clock = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        let starts = recording.liveWordsTracks.mapValues(\.frames)
        let source = LiveWordsPCMSource(starts: starts) { [weak recording] in recording?.liveWordsTracks ?? [:] }
        work = Task.detached(priority: .background) { [weak self] in
            do {
                _ = try await control.wait()
                _ = try await LiveWordsEngine.shared.load()
                await self?.ready(mine)
                try await LiveWordsRunner.run(control: control, starts: starts, next: { try await source.next($0, maximum: $1) }, onLine: {
                    await self?.receive($0, generation: mine)
                })
            } catch is CancellationError { }
            catch { await self?.failed(mine) }
        }
    }

    func pause(_ paused: Bool) { control?.setPaused(paused); refresh() }

    func stop() {
        generation += 1
        // The live model goes a minute after the last meeting with live words, unless another one starts.
        if work != nil {
            let after = generation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard let self, self.generation == after, self.work == nil else { return }
                await LiveWordsEngine.shared.unload()
            }
        }
        control?.cancel(); control = nil
        work?.cancel(); work = nil
        clock?.invalidate(); clock = nil
        lines.clear(); status = ""; recording = nil
        window.clearAndClose()
    }

    private func ready(_ mine: Int) {
        guard generation == mine else { return }
        status = "Listening…"; refresh()
    }
    private func receive(_ line: LiveWordsLine, generation mine: Int) async {
        // Pause/key-down can win the hop back to the main actor after inference. Keep this one result until it
        // can appear, rather than dropping a finished line or letting it through during the pause.
        while mine == generation, let recording {
            guard !Task.isCancelled else { return }
            if !recording.isPaused, LiveWordsPriority.shared.idleEpoch != nil {
                lines.put(line); refresh(); return
            }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
    }
    private func failed(_ mine: Int) {
        guard mine == generation else { return }
        status = "Live words couldn't start. Turn them off and on to try again."
        Log.note("live words: worker failed")
        refresh()
    }
    private func refresh() {
        guard let recording else { return }
        control?.setPaused(recording.isPaused)
        let message = recording.savingStopped != nil ? Meeting.savingWarning : recording.isPaused ? "Paused"
            : LiveWordsPriority.shared.idleEpoch == nil ? "Waiting while you dictate…" : status
        window.update(lines.lines, elapsed: recording.seconds, status: message, paused: recording.isPaused,
                      onCall: !recording.macSilent)
        if recording.savingStopped != nil { control?.cancel(); work?.cancel() }
    }
}
