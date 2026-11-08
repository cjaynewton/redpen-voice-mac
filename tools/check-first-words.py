#!/usr/bin/env python3
"""Passive checks of the actual Session and Recording classes with synthetic audio and stub ASR.

No app, mic, model, media command or network request is started. Run from any directory with
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 tools/check-first-words.py.
The before/after measurement counts known user samples blanked, not real-world ASR accuracy.
"""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def block(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    i = opening + 1
    while depth:
        depth += (source[i] == "{") - (source[i] == "}")
        i += 1
    return source[start:i]


session = block((ROOT / "Sources/RedpenVoice/Transcriber.swift").read_text(), "final class Session:")
recording = block((ROOT / "Sources/RedpenVoice/SoundTap.swift").read_text(), "final class Recording:")
stubs = r'''
import AVFoundation
import Speech
import Foundation

enum Log {
    static func note(_ s: String) {}
    static func ms(_ t: Double) -> Int { Int(t * 1000) }
    static func int(_ t: Double) -> Int { Int(t) }
}
struct WhisperKit: Sendable {}
struct AsrManager: Sendable {}
actor StreamingUnifiedAsrManager {
    func reset() {}
    func appendAudio(_ b: AVAudioPCMBuffer) {}
    func processBufferedAudio() {}
    func getPartialTranscript() -> String { "" }
    func finish() -> String { "" }
}
final class LiveWordsPriority {
    static let shared = LiveWordsPriority()
    final class Lease { func end() {} }
    func begin() -> Lease { Lease() }
}
enum FakeASR {
    static var reference: [Float] = []
    static var text = ""
    static var failReference = false
    static func read(_ a: [Float]) throws -> String {
        if a == reference {
            if failReference { throw NSError(domain: "synthetic", code: 1) }
            return "please tell me what"
        }
        return a.contains(where: { $0 != 0 }) ? text : ""
    }
}
enum Transcriber {
    static let lastJob = 10.0
    static func prompt(_ hints: String, _ previous: String?) -> String { hints }
    static func whisperText(_ w: WhisperKit, _ a: [Float], prompt: String? = nil) async throws -> String { try FakeASR.read(a) }
    static func parakeetText(_ p: AsrManager, _ a: [Float]) async throws -> String { try FakeASR.read(a) }
    actor Gate { func acquire() {}; func release() {} }
    final class Once {
        let lock = NSLock(); var done = false
        func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }
'''
tests = r'''
final class Calls: @unchecked Sendable {
    let lock = NSLock()
    var drafts: [String] = [], checks: [String] = []
    func draft(_ t: String) { lock.withLock { drafts.append(t) } }
    func check(_ t: String) { lock.withLock { checks.append(t) } }
}
@main struct Run {
    static var count = 0
    static func check(_ name: String, _ ok: Bool) {
        if !ok { print("FAIL \(name)"); fflush(stdout); exit(1) }; count += 1
    }
    static func noise(_ seed: UInt64, _ n: Int) -> [Float] {
        var s = seed
        return (0..<n).map { _ in
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int32(truncatingIfNeeded: s >> 32)) / Float(Int32.max) * 0.1
        }
    }
    static func push(_ a: [Float], to s: Transcriber.Session) {
        let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(a.count))!
        b.frameLength = AVAudioFrameCount(a.count)
        a.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: a.count) }
        s.push(b)
    }
    static func main() async throws {
        let video = noise(12, 16_000)
        let user = noise(92, 48_000)
        FakeASR.reference = video
        for speakers in [false, true] {
            var mic = [Float](repeating: 0, count: 48_000)
            // User starts at key-down, 600 ms into the saved pre-roll, before the 2300 ms cut.
            for i in 9600..<36_800 { mic[i] = user[i] }
            if speakers { for i in video.indices { mic[i + 9600] += video[i] * 0.7 } }
            let original = mic
            let old = Transcriber.Session(whisper: WhisperKit())
            push(mic, to: old); old.silence(upTo: 36_800)
            let before = (9600..<36_800).filter { old.recorded[$0] != original[$0] }.count / 16
            old.cancel()
            let s = Transcriber.Session(whisper: WhisperKit())
            s.drafter = AsrManager(); s.holdForMedia(); push(mic, to: s)
            s.mediaEcho(video, through: 36_800, unreferencedPrefix: 9600); s.mediaSettled()
            while !s.settledForLoops { try await Task.sleep(for: .milliseconds(10)) }
            let after = (9600..<36_800).filter { s.recorded[$0] == 0 && original[$0] != 0 }.count / 16
            check("all opening PCM retained", after == 0 && before == 1700)
            let heard = "Please tell me what happened"
            let expected = heard
            // First draft, its independent check, and a short session ending all hear sample zero.
            check("matching user phrase retained", await s.echoStripped(heard, from: 0) == expected)
            check("matching user phrase retained in check", await s.echoStripped(heard, from: 0) == expected)
            check("later repetition kept", await s.echoStripped("Please tell me what", from: 36_800) == "Please tell me what")
            check("known opening remains deliverable", !s.echoFailed)
            var expectedAudio = original
            if speakers { for i in video.indices { expectedAudio[i + 9600] -= video[i] * 0.7 } }
            let error = zip(s.recorded, expectedAudio).reduce(Float(0)) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) } / Float(original.count)
            check("video waveform removed without cutting user", error < 0.00001)
            FakeASR.text = heard
            check("short ending cleaned", try await s.finish() == expected)
            print("\(speakers ? "speakers" : "headphones"): known user audio blanked before \(before) ms, after \(after) ms")
        }
        // Real draft and check loops. The check must not reinsert words already removed from a draft.
        let s = Transcriber.Session(whisper: WhisperKit())
        s.drafter = AsrManager(); s.holdForMedia()
        var mic = noise(999, 96_000)
        for i in 0..<16_000 { mic[i + 10_000] += video[i] }
        for i in 42_000..<48_000 { mic[i] = 0 }
        for i in 84_000..<96_000 { mic[i] = 0 }
        push(mic, to: s)
        FakeASR.text = "My first words stay"
        let calls = Calls()
        s.onDraft = { _, text in calls.draft(text) }
        s.onCheck = { _, text in calls.check(text) }
        s.streamDrafts(); s.stream(Chunker())
        try await Task.sleep(for: .milliseconds(500))
        check("no draft before media decision", calls.lock.withLock { calls.drafts.isEmpty })
        s.mediaEcho(video, through: 36_800); s.mediaSettled()
        try await Task.sleep(for: .milliseconds(1600))
        check("real first draft cleaned", calls.lock.withLock { calls.drafts.first == "My first words stay" })
        check("real first check cleaned", calls.lock.withLock { calls.checks.first == "My first words stay" })
        s.cancel()

        // Unreferenced pre-roll must not auto-deliver earlier video words, or throw away possible user words.
        let uncertain = Transcriber.Session(whisper: WhisperKit())
        push(mic, to: uncertain)
        uncertain.mediaEcho(video, unreferencedPrefix: 9600)
        let early = "Yesterday was sunny please tell me what send report"
        check("uncovered prefix kept", await uncertain.echoStripped(early) == early)
        check("uncovered prefix blocks typing", uncertain.echoFailed)
        uncertain.cancel()
        let oneWord = Transcriber.Session(whisper: WhisperKit())
        push(mic, to: oneWord); oneWord.mediaEcho(video, unreferencedPrefix: 9600)
        check("one-word uncertain prefix keeps every word", await oneWord.echoStripped("Wait please tell me what happened") == "Wait please tell me what happened")
        check("one-word uncertain prefix blocks typing", oneWord.echoFailed)
        oneWord.cancel()
        let failed = Transcriber.Session(whisper: WhisperKit())
        push(mic, to: failed)
        failed.mediaEcho([Float](repeating: 0, count: 5000))
        check("reference failure keeps words", await failed.echoStripped("My first words stay") == "My first words stay")
        check("reference failure blocks typing", failed.echoFailed)
        failed.cancel()

        // Recording keeps everything between the loudness decision and Chrome's eventual answer.
        let recording = Recording(continuous: true)
        recording.add([Float](repeating: 0.1, count: 4000), rate: 16000)
        recording.add([Float](repeating: 0.2, count: 9200), rate: 16000) // 575 ms answer gap
        check("Chrome answer gap captured", recording.mono16k().count == 13_200)
        await withCheckedContinuation { c in recording.waitForQuiet { _ in c.resume() } }
        check("quiet closes continuous recording", recording.isClosed && !recording.truncated)

        for duration in [0.05, 0.15, 0.299] {
            var key = TalkKeyState()
            _ = key.event(key: 63, down: true, at: 10)
            _ = key.event(key: 63, down: false, at: 10 + duration)
            check("quick tap never owns pause at 300 ms", !key.active && !key.handsFree)
        }
        print("quick tap: pause calls before 0, after 0; no delivered dictation by design")
        print("\(count) Session/Recording integration checks passed (synthetic ASR, no hardware)")
    }
}
'''

with tempfile.TemporaryDirectory(prefix="first-words-", dir=ROOT / ".build") as tmp:
    tmp = Path(tmp)
    source = tmp / "Harness.swift"
    source.write_text(stubs + session + "\n}\n" + recording + tests)
    core = ROOT / "Sources/VoiceCore"
    files = [core / name for name in ["MediaEcho.swift", "MediaAudio.swift", "MediaOpening.swift", "MediaGate.swift", "Chunker.swift",
                                    "Silence.swift", "TalkKeyState.swift", "DictationDelivery.swift"]]
    subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-swift-version", "5", str(source),
                    *map(str, files), "-o", str(tmp / "check")], cwd=ROOT, check=True)
    subprocess.run([str(tmp / "check")], cwd=ROOT, check=True, env=os.environ)
