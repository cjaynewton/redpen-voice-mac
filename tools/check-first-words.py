#!/usr/bin/env python3
"""Passive checks of the actual Session and Recording classes with synthetic audio and stub ASR.

No app, mic, model, media command or network request is started. Run from any directory with
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 tools/check-first-words.py.
The before/after measurement counts known user samples blanked, not real-world ASR accuracy.
"""
from pathlib import Path
import os
import re
import json
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
# Passive source contracts for the real AppDelegate/adapter path, alongside runtime audio/state checks below.
app_source = (ROOT / "Sources/RedpenVoice/main.swift").read_text()
begin = block(app_source, "private func begin()")
activate = block(app_source, "private func activateStart(")
media = block(app_source, "private func startMedia(")
confirmed = block(app_source, "private func whenMediaConfirmed(")
hold_source = (ROOT / "Sources/RedpenVoice/HoldKey.swift").read_text()
hud_source = (ROOT / "Sources/RedpenVoice/HUD.swift").read_text()
recorder_source = (ROOT / "Sources/RedpenVoice/Recorder.swift").read_text()
wiring_checks = [
    ("bar on first accepted down before recorder attach", begin.index('hud.show("", level: true)') < begin.index("recorder.begin(")),
    ("capture attaches before yielding setup", begin.index("recorder.begin(") < begin.index("DispatchQueue.main.async { [weak self] in self?.prepareStart")),
    ("no slow discovery or delayed HUD on start path", all(term not in begin for term in ["Insert.focus", "boxPrint", "playingApps()", "SoundTap.loudness", "recorder.start(", "asyncAfter", "loadNames", "engine.session("])),
    ("HUD orders on initial show", "panel.orderFrontRegardless()" in block(hud_source, "func show(")),
    ("capture promotion needs confirmation and bounded target result", "capture.confirmed, capture.targetDone" in block(app_source, "private func activateIfReady(")),
    ("media action is gated by gesture not timer alone", "keys.mediaAllowed, pendingStart == nil" in confirmed and "whenMediaConfirmed(" in media),
    ("no blanket opening zeroing in app media path", "silence(upTo:" not in media),
    ("quiet Chrome guard survived conflict resolution", "askChromeWhenQuiet" in media and "chromeOnly: !playing" in media),
    ("SoundTap setup off caller", "setup.async { listen(next) }" in (ROOT / "Sources/RedpenVoice/SoundTap.swift").read_text()),
    ("event-time cancel reason reaches app", "onCancel(state.cancelReason)" in hold_source and "cancel(disposableTap: reason != .otherKey)" in app_source),
    ("recorder serializes pre-roll before live buffer", block(recorder_source, "func begin(").index("for b in pre { onBuffer(b) }") < block(recorder_source, "func begin(").index("lock.unlock()")),
    ("default mic moves after the release tail, never during pending capture", "pendingStart == nil" in block(app_source, "private func remicIfDefaultMoved(") and 'remicIfDefaultMoved(reason: "input moved while talking")' in block(app_source, "private func end()")),
    ("input tracking starts on first down and is carried into drafts", "keys.trackDraft(since: capture.beganUptime)" in begin and "input: capture.input" in activate),
    ("late target cannot ignore real typing", "capture.input?.snapshot().typingAt == nil" in app_source),
    ("missing start target cannot claim later box for drafts", "if startBox == nil { drafting?.draftsStopped = true; drafting?.checksStopped = true" in activate),
]
for name, passed in wiring_checks:
    if not passed:
        raise AssertionError(name)
print(f"{len(wiring_checks)} startup source contracts passed (not screen-pixel or hardware proof)", flush=True)

stubs = r'''
import AVFoundation
import Speech
import Foundation

enum Log {
    static let lock = NSLock()
    static var notes: [String] = []
    static func note(_ s: String) { lock.withLock { notes.append(s) } }
    static var recorded: [String] { lock.withLock { notes } }
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
enum StartTrace {
    static let lock = NSLock()
    static var firstKept: [Int: Int] = [:]
    static func note(_ event: TalkTimingTrace.Event, gesture: Int, count: Int = 0, value: Int = 0) {
        if event == .firstSampleKept { lock.withLock { firstKept[gesture] = count } }
    }
    static func offset(_ gesture: Int) -> Int? { lock.withLock { firstKept[gesture] } }
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
    static var count = __WIRING_CHECKS__
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
        let beforeKeyVideo = noise(123, 9600)
        FakeASR.reference = video
        for speakers in [false, true] {
            var mic = [Float](repeating: 0, count: 48_000)
            // User starts at key-down, 600 ms into the saved pre-roll, before the 2300 ms cut.
            for i in 9600..<36_800 { mic[i] = user[i] }
            for i in 0..<9600 { mic[i] = beforeKeyVideo[i] * (speakers ? 0.7 : 0.01) }
            if speakers { for i in video.indices { mic[i + 9600] += video[i] * 0.7 } }
            let original = mic
            let old = Transcriber.Session(whisper: WhisperKit())
            push(mic, to: old); old.silence(upTo: 36_800)
            let before = (9600..<36_800).filter { old.recorded[$0] != original[$0] }.count / 16
            old.cancel()
            let s = Transcriber.Session(whisper: WhisperKit())
            s.traceID = speakers ? 2 : 1
            s.drafter = AsrManager(); s.holdForMedia(); push(mic, to: s)
            s.mediaEcho(video, through: 36_800, unreferencedPrefix: 9600); s.mediaSettled()
            while !s.settledForLoops { try await Task.sleep(for: .milliseconds(10)) }
            s.mediaSettled() // Repeated settlement must not reset the trace's applied mask boundary.
            check("trace reports first retained sample after actual cut", StartTrace.offset(s.traceID) == (speakers ? 9600 : 0))
            let after = (9600..<36_800).filter { s.recorded[$0] == 0 && original[$0] != 0 }.count / 16
            check("all opening PCM retained", after == 0 && before == 1700)
            let heard = "Please tell me what happened"
            let expected = heard
            // First draft, its independent check, and a short session ending all hear sample zero.
            check("matching user phrase retained", await s.echoStripped(heard, from: 0) == expected)
            check("matching user phrase retained in check", await s.echoStripped(heard, from: 0) == expected)
            check("later repetition kept", await s.echoStripped("Please tell me what", from: 36_800) == "Please tell me what")
            check("known opening ready for delivery", s.settledForLoops)
            if speakers {
                check("real speaker pre-roll trimmed", s.recorded.prefix(7200).allSatisfy { $0 == 0 })
                check("all pre-key video removed", s.recorded.prefix(9600).allSatisfy { $0 == 0 })
            } else { check("real headphone pre-roll untouched", s.recorded == original) }
            var expectedAudio = original
            if speakers {
                for i in 0..<9600 { expectedAudio[i] = 0 }
                for i in video.indices { expectedAudio[i + 9600] -= video[i] * 0.7 }
            }
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
        for i in 0..<9600 { mic[i] = beforeKeyVideo[i] * 0.7 }
        for i in 0..<16_000 { mic[i + 9600] += video[i] }
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
        s.mediaEcho(video, through: 36_800, unreferencedPrefix: 9600); s.mediaSettled()
        try await Task.sleep(for: .milliseconds(1600))
        check("real first draft cleaned", calls.lock.withLock { calls.drafts.first == "My first words stay" })
        check("real first check cleaned", calls.lock.withLock { calls.checks.first == "My first words stay" })
        let alreadyUsed = s.recorded
        s.silence(upTo: alreadyUsed.count)
        check("late blanket cut cannot rewrite a ready draft", s.recorded == alreadyUsed)
        let lateCleanup = MediaAudio.removing(mic: alreadyUsed, played: video, preRoll: 9600)
        check("late media fit cannot replace a ready draft", !s.acceptMediaResult(lateCleanup, replacing: alreadyUsed.count) && s.recorded == alreadyUsed)
        s.cancel()

        // A measured 25 ms post-key startup gap is blanked; it no longer makes the whole dictation abstain.
        for i in 9600..<10000 { mic[i] = user[i] }
        for i in 0..<16_000 { mic[i + 10000] = user[i + 10000] + video[i] }
        let uncertain = Transcriber.Session(whisper: WhisperKit())
        push(mic, to: uncertain)
        uncertain.mediaEcho(video, unreferencedPrefix: 9600)
        let early = "Yesterday was sunny please tell me what send report"
        check("uncovered prefix kept", await uncertain.echoStripped(early) == early)
        check("startup gap permits typing", uncertain.settledForLoops)
        check("only measured startup gap blanked", uncertain.recorded.prefix(10000).allSatisfy { $0 == 0 }
              && uncertain.recorded[10000..<10480].contains { $0 != 0 })
        uncertain.cancel()
        let oneWord = Transcriber.Session(whisper: WhisperKit())
        push(mic, to: oneWord); oneWord.mediaEcho(video, unreferencedPrefix: 9600)
        check("one-word uncertain prefix keeps every word", await oneWord.echoStripped("Wait please tell me what happened") == "Wait please tell me what happened")
        check("matching user words still permit typing", oneWord.settledForLoops)
        oneWord.cancel()
        let failed = Transcriber.Session(whisper: WhisperKit())
        push(mic, to: failed)
        failed.mediaEcho([Float](repeating: 0, count: 5000))
        check("reference failure keeps words", await failed.echoStripped("My first words stay") == "My first words stay")
        check("reference failure permits typing", failed.settledForLoops)
        check("reference failure keeps original audio", failed.recorded == mic)
        failed.cancel()

        // D-1400 covers every helper reason, including a future reason the delivery layer does not know.
        // Deliberately supply blank candidate output: an unsure result must still retain the original mic.
        FakeASR.text = "User opening words stay"
        let reasons = [__UNSURE_REASONS__]
        var pending: [(String, Transcriber.Session, Calls)] = []
        func start(_ reason: String, _ s: Transcriber.Session) {
            let calls = Calls()
            s.onDraft = { _, text in calls.draft(text) }
            s.onCheck = { _, text in calls.check(text) }
            s.drafter = AsrManager(); s.streamDrafts(); s.stream(Chunker())
            pending.append((reason, s, calls))
        }
        for reason in reasons {
            let s = Transcriber.Session(whisper: WhisperKit())
            s.holdForMedia(); push(mic, to: s)
            var diagnostic = MediaAudio.Diagnostics(); diagnostic.reason = reason
            let result = MediaAudio.Result(samples: [Float](repeating: 0, count: mic.count), certain: false, cleaned: true, match: 0.2, diagnostics: diagnostic)
            check("unsure result accepted \(reason)", s.acceptMediaResult(result, replacing: mic.count))
            check("unsure keeps original \(reason)", s.recorded == mic && s.settledForLoops)
            check("unsure reason logged \(reason)", Log.recorded.contains { $0.contains("unsure, typed anyway") && $0.contains("reason=\(reason),") })
            start(reason, s)
        }
        for reason in ["chromePauseFailed", "unusableVideoReference", "pressEndedBeforeMediaDecision", "mediaCleanerUnavailable", "uncheckedVideo"] {
            let s = Transcriber.Session(whisper: WhisperKit())
            s.holdForMedia(); push(mic, to: s)
            s.mediaUnchecked(reason: reason); s.mediaSettled()
            check("unchecked keeps original \(reason)", s.recorded == mic && s.settledForLoops)
            check("unchecked logged \(reason)", Log.recorded.contains { $0.contains("unsure, typed anyway; reason=\(reason)") })
            start(reason, s)
        }
        let timeout = Transcriber.Session(whisper: WhisperKit())
        timeout.holdForMedia(at: Date().addingTimeInterval(-6)); push(mic, to: timeout)
        check("timeout releases typing", timeout.settledForLoops)
        timeout.mediaEcho(video, through: mic.count + 16000, unreferencedPrefix: 9600)
        timeout.silence(upTo: mic.count)
        check("late decision cannot blank timed-out audio", timeout.recorded == mic)
        start("timeout", timeout)

        let inFlight = Transcriber.Session(whisper: WhisperKit())
        inFlight.holdForMedia(); push(mic, to: inFlight)
        inFlight.mediaEcho(video, through: mic.count + 16000, unreferencedPrefix: 9600)
        inFlight.holdForMedia(at: Date().addingTimeInterval(-6))
        check("timeout releases in-flight preparation", inFlight.settledForLoops)
        check("timeout does not await late cleanup", await inFlight.echoStripped("User opening words stay") == "User opening words stay")
        start("inFlightTimeout", inFlight)

        let cancelled = Transcriber.Session(whisper: WhisperKit())
        cancelled.holdForMedia(); push(mic, to: cancelled)
        let cancelledCalls = Calls()
        cancelled.drafter = AsrManager()
        cancelled.onDraft = { _, text in cancelledCalls.draft(text) }
        cancelled.onCheck = { _, text in cancelledCalls.check(text) }
        cancelled.streamDrafts(); cancelled.stream(Chunker()); cancelled.cancel()
        cancelled.mediaUnchecked(reason: "chromePauseFailed")

        try await Task.sleep(for: .milliseconds(1600))
        for (reason, s, calls) in pending {
            check("draft typed for \(reason)", calls.lock.withLock { calls.drafts.contains("User opening words stay") })
            check("check typed for \(reason)", calls.lock.withLock { calls.checks.contains("User opening words stay") })
            check("final text delivered for \(reason)", try await s.finish().contains("User opening words stay"))
            check("all original audio retained for \(reason)", s.recorded == mic)
        }
        check("cancel still suppresses drafts and checks", cancelledCalls.lock.withLock { cancelledCalls.drafts.isEmpty && cancelledCalls.checks.isEmpty })

        for cancelByKey in [false, true] {
            var gesture = TalkKeyState()
            let pending = TalkCapture<[Float]>(maxFrames: 48_000)
            let target = Transcriber.Session(whisper: WhisperKit())
            let start = noise(444, 4000), gap = noise(445, 4000)
            _ = gesture.event(key: 63, down: true, at: 0)
            pending.append(start, frames: start.count)
            _ = gesture.event(key: 63, down: false, at: 0.1)
            pending.append(gap, frames: gap.count)
            check("pending tap never feeds engine", target.recorded.isEmpty)
            let action = cancelByKey ? gesture.otherKey(at: 0.2) : gesture.expireTap(at: 0.6)
            check("single tap or other-key cancellation is explicit", action == .cancel)
            pending.discard()
            check("cancelled first-tap audio is not delivered", !pending.activate { push($0, to: target) } && target.recorded.isEmpty)
            target.cancel()
        }
        var gesture = TalkKeyState()
        let pendingTap = TalkCapture<[Float]>(maxFrames: 48_000)
        let promoted = Transcriber.Session(whisper: WhisperKit())
        let firstTap = noise(446, 4000), gap = noise(447, 4000), secondTap = noise(448, 4000)
        _ = gesture.event(key: 63, down: true, at: 0)
        pendingTap.append(firstTap, frames: firstTap.count)
        _ = gesture.event(key: 63, down: false, at: 0.1)
        pendingTap.append(gap, frames: gap.count)
        check("double tap resumes original capture", gesture.event(key: 63, down: true, canBegin: false, at: 0.2) == .resume)
        pendingTap.append(secondTap, frames: secondTap.count)
        check("second release confirms same capture", gesture.event(key: 63, down: false, at: 0.3) == .handsFree)
        check("double tap replays first samples once", pendingTap.activate { push($0, to: promoted) } && promoted.recorded == firstTap + gap + secondTap)
        promoted.cancel()

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
    helper = (ROOT / "Sources/VoiceCore/MediaAudio.swift").read_text()
    reasons = sorted(set(re.findall(r'unchanged\("([^"]+)"', helper)) - {"quietPreRollNoMeasuredEcho", "noMeasuredEcho"})
    reasons += ["middleBand", "futureUnknownReason"]
    tests = tests.replace("__WIRING_CHECKS__", str(len(wiring_checks)))
    tests = tests.replace("__UNSURE_REASONS__", ", ".join(json.dumps(reason) for reason in reasons))
    source.write_text(stubs + session + "\n}\n" + recording + tests)
    core = ROOT / "Sources/VoiceCore"
    files = [core / name for name in ["MediaEcho.swift", "MediaAudio.swift", "MediaOpening.swift", "MediaGate.swift", "Chunker.swift",
                                    "Silence.swift", "TalkKeyState.swift", "DictationDelivery.swift", "TalkTimingTrace.swift", "TalkCapture.swift"]]
    subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-swift-version", "5", str(source),
                    *map(str, files), "-o", str(tmp / "check")], cwd=ROOT, check=True)
    subprocess.run([str(tmp / "check")], cwd=ROOT, check=True, env=os.environ)
