#!/usr/bin/env python3
"""Synthetic I/O probes using production code, without launching Voice or any provider."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='voice-after-call-io-') as tmp:
    folder = Path(tmp)
    capture = (repo / 'Sources/RedpenVoice/MeetingCapture.swift').read_text().split('/// Everything the Mac plays')[0]
    stubs = '''
enum Log { static func note(_ text: String) {} }
enum MeetingNotes { static func code(_ error: Error) -> String { "test" } }
'''
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
print("\(passed) I/O checks passed")
'''
    main = folder / 'main.swift'
    main.write_text(capture + stubs + checks)
    release = repo / '.build/out/Products/Release'
    objects = [release / 'VoiceCore.o']
    subprocess.run(['xcrun', 'swiftc', '-target', 'arm64-apple-macos26.0', '-I', str(release), str(main), *map(str, objects), '-o', str(folder / 'checks')], check=True)
    subprocess.run([str(folder / 'checks'), str(folder)], check=True)
