#!/usr/bin/env python3
"""Synthetic I/O probes using production code, without launching Voice or any provider."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='voice-after-call-io-') as tmp:
    folder = Path(tmp)
    capture = (repo / 'Sources/RedpenVoice/MeetingCapture.swift').read_text().split('/// Everything the Mac plays')[0]
    notes = (repo / 'Sources/RedpenVoice/MeetingNotes.swift').read_text()
    def method(marker):
        start = notes.index('    static func ' + marker)
        line = notes[start:notes.index('\n', start)]
        end = start + len(line) if line.count('{') == line.count('}') and '{' in line else notes.index('\n    }', start) + len('\n    }')
        return notes[start:end]
    stubs = 'enum Log { static var messages: [String] = []; static func note(_ text: String) { messages.append(text) } }\nenum MeetingNotes {\n' + '\n'.join(method(name) for name in ['code(', 'savePrivately(', 'privateFolder(', 'read(', 'exportAudio(']) + '\n}\n'

    checks = r'''
var passed = 0
func check(_ ok: Bool, _ name: String) { precondition(ok, name); passed += 1 }
let root = URL(fileURLWithPath: CommandLine.arguments[1])
func closedHandle(_ name: String) throws -> FileHandle {
    let u = root.appendingPathComponent(name)
    FileManager.default.createFile(atPath: u.path, contents: nil)
    let h = try FileHandle(forWritingTo: u); try h.close(); return h
}
let healthy = try TrackWriter(url: root.appendingPathComponent("healthy.pcm"))
healthy.write(mono: [Float](repeating: 0.25, count: 1600), rate: 16000); healthy.close()
check(healthy.frames == 1600 && healthy.saving.stopped == nil, "healthy write and flush")
let bad = try TrackWriter(url: root.appendingPathComponent("bad.pcm"), fileHandle: closedHandle("closed"))
bad.write(mono: [0.25, 0.5], rate: 16000); bad.close()
check(bad.frames == 0 && bad.saving.stopped != nil, "closed handle append failure")
let first = bad.saving.stopped
bad.appendSilence(1)
check(bad.frames == 0 && bad.saving.stopped == first, "failure remains latched")
let silence = try TrackWriter(url: root.appendingPathComponent("silence.pcm"), fileHandle: closedHandle("closed2"))
silence.appendSilence(0.1)
check(silence.saving.stopped != nil && silence.frames == 0, "silence failure")
silence.close()
let flush = try TrackWriter(url: root.appendingPathComponent("flush.pcm"), fileHandle: closedHandle("closed3"))
flush.close()
check(flush.saving.stopped != nil, "final flush failure")
let shared = MeetingSaving()
shared.fail(at: Date())
let other = try TrackWriter(url: root.appendingPathComponent("other.pcm"), saving: shared)
other.write(mono: [0.5], rate: 16000); other.close()
check(other.frames == 0, "both tracks stop on failure")
let aac = root.appendingPathComponent("export.m4a")
try MeetingNotes.exportAudio(healthy.url, to: aac)
check((try? MeetingFiles.requireMode(0o600, at: aac)) != nil, "AAC private destination")
let privateAudio = try MeetingFiles.scratch(in: root)
let caf = privateAudio.appendingPathComponent("audio.caf")
let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
do {
    let output = try AVAudioFile(forWriting: caf, settings: format.settings)
    check((try? MeetingFiles.requireMode(0o700, at: privateAudio)) != nil, "CAF private while open")
    _ = output
}
do { try MeetingNotes.savePrivately("synthetic", to: root.appendingPathComponent("missing/notes.md")) }
catch {}
check(Log.messages.contains { $0.hasPrefix("meeting: private notes save failed,") }, "private save failure logged")
func wave(_ frames: Int, hz: Double = 440) -> [Float] {
    (0..<frames).map { Float(sin(2 * .pi * hz * Double($0) / 16000)) * 0.4 }
}
func raw(_ name: String, _ samples: [Float]) throws -> URL {
    let url = root.appendingPathComponent(name + ".pcm")
    let ints = samples.map { Int16($0 * 32767).littleEndian }
    try MeetingFiles.save(ints.withUnsafeBufferPointer { Data(buffer: $0) }, to: url)
    return url
}
func decoded(_ track: URL, _ name: String, offset: Double = 0, limit: Double? = nil) throws -> [Float] {
    let url = root.appendingPathComponent(name + ".m4a")
    try MeetingNotes.exportAudio(track, to: url, offset: offset, limit: limit)
    let f = try AVAudioFile(forReading: url)
    let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length))!
    try f.read(into: b)
    return Array(UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)))
}
func rms(_ samples: [Float], at: Double) -> Float {
    let start = Int(at * 16000), end = min(samples.count, start + 800)
    guard start < end else { return 0 }
    return (samples[start..<end].reduce(0) { $0 + $1 * $1 } / Float(end - start)).squareRoot()
}
let tone = try raw("tone", wave(16000))
let late = try decoded(tone, "late", offset: 60)
check(abs(Double(late.count) / 16000 - 61) < 0.08, "late Others duration")
check(rms(late, at: 59.8) < 0.001 && rms(late, at: 60.1) > 0.1, "late Others starts at meeting minute one")
let preroll = try raw("preroll", wave(9600, hz: 220) + wave(16000, hz: 880))
let trimmed = try decoded(preroll, "trimmed", offset: -0.6)
check(abs(Double(trimmed.count) / 16000 - 1) < 0.08 && rms(trimmed, at: 0.1) > 0.1, "microphone preroll trimmed")
let ordinary = try decoded(tone, "ordinary")
check(abs(Double(ordinary.count) / 16000 - 1) < 0.08 && rms(ordinary, at: 0.1) > 0.1, "zero offset control")
let silent = try raw("empty", [])
let silenceOnly = try decoded(silent, "silent", offset: 0.5)
check(silenceOnly.count >= 8000 && silenceOnly.allSatisfy { abs($0) < 0.001 }, "silent delayed track")
let gap = try raw("gap", wave(8000) + [Float](repeating: 0, count: 8000) + wave(8000))
let gapped = try decoded(gap, "gapped")
check(rms(gapped, at: 0.7) < 0.001 && rms(gapped, at: 1.1) > 0.1, "device gap stays on clock")
let limited = try decoded(tone, "limited", offset: 1, limit: 0.25)
check(abs(Double(limited.count) / 16000 - 1.25) < 0.08, "saving cutoff includes timeline padding")
print("\(passed) I/O checks passed")
'''
    main = folder / 'main.swift'
    main.write_text(capture + stubs + checks)
    release = repo / '.build/out/Products/Release'
    objects = [release / 'VoiceCore.o']
    subprocess.run(['xcrun', 'swiftc', '-target', 'arm64-apple-macos26.0', '-I', str(release), str(main), *map(str, objects), '-o', str(folder / 'checks')], check=True)
    subprocess.run([str(folder / 'checks'), str(folder)], check=True)
