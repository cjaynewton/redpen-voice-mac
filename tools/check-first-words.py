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


transcriber_source = (ROOT / "Sources/RedpenVoice/Transcriber.swift").read_text()
session = block(transcriber_source, "final class Session:")
gate = block(transcriber_source, "actor Gate {")
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
target_source = (ROOT / "Sources/RedpenVoice/StartTarget.swift").read_text()
resolve_target = block(app_source, "private func resolveStartTarget(")
fallback_target = block(app_source, "private func fallbackStartTarget(")
prepare = block(app_source, "private func prepareStart(")
cancel = block(app_source, "private func cancel(")
wiring_checks = [
    ("bar on first accepted down before recorder attach", begin.index('hud.show("", level: true)') < begin.index("recorder.begin(")),
    ("capture attaches before yielding setup", begin.index("recorder.begin(") < begin.index("DispatchQueue.main.async { [weak self] in self?.prepareStart")),
    ("no target/media discovery or delayed HUD on start path", all(term not in begin for term in ["Insert.focus", "boxPrint", "playingApps()", "SoundTap.loudness", "asyncAfter", "loadNames", "engine.session("])),
    ("HUD orders on initial show", "panel.orderFrontRegardless()" in block(hud_source, "func show(")),
    ("capture promotion needs confirmation and bounded target result", "capture.confirmed, capture.targetDone" in block(app_source, "private func activateIfReady(")),
    ("media action is gated by gesture not timer alone", "keys.mediaAllowed, pendingStart == nil" in confirmed and "whenMediaConfirmed(" in media),
    ("no blanket opening zeroing in app media path", "silence(upTo:" not in media),
    ("quiet Chrome guard survived conflict resolution", "askChromeWhenQuiet" in media and "chromeOnly: !playing" in media),
    ("SoundTap setup off caller", "setup.async { listen(next) }" in (ROOT / "Sources/RedpenVoice/SoundTap.swift").read_text()),
    ("pending tap disposable on every cancel reason", "onCancel(state.cancelReason)" in hold_source and "cancel(disposableTap: pending?.confirmed == false || reason != .otherKey)" in cancel),
    ("old ending waits for entire pending tap window", "onPendingTap(until)" in hold_source and "keys.onPendingTap =" in app_source and "deliveries.deferTap(until:" in app_source and "deliveries.confirm()" in block(app_source, "private func confirmStart()")),
    ("recorder serializes pre-roll before live buffer", block(recorder_source, "func begin(").index("for b in pre { onBuffer(b) }") < block(recorder_source, "func begin(").index("lock.unlock()")),
    ("default mic moves after the release tail, never during pending capture", "pendingStart == nil" in block(app_source, "private func remicIfDefaultMoved(") and 'remicIfDefaultMoved(reason: "input moved while talking")' in block(app_source, "private func end()")),
    ("input tracking starts on first down and is carried into drafts", "keys.trackDraft(since: capture.beganUptime)" in begin and "input: capture.input" in activate),
    ("late target cannot ignore real typing", "capture.input?.snapshot().typingAt == nil" in block(app_source, "private func startTargetUnchanged(")),
    ("missing start target cannot claim later box for drafts", "if startBox == nil { drafting?.draftsStopped = true; drafting?.checksStopped = true" in activate),
    ("cold recorder starts on accepted down before attaching capture", begin.index("if !recorder.isRunning") < begin.index("recorder.start(format: format)") < begin.index("recorder.begin(")),
    ("cold bar flushed before starting hardware", begin.index("hud.flushInitialDisplay()") < begin.index("recorder.start(format: format)")),
    ("activation never starts cold mic late", "recorder.start(" not in activate and "recorder.begin(" not in activate),
    ("accepted down cancels resume before deferred setup", begin.index("resumeWork?.cancel(); resumeWork = nil") < begin.index("recorder.begin(") and "resumeWork" not in media),
    ("accepted down invalidates old resume callback", "if pausedMedia { pausedMedia = true }" in begin),
    ("tap cancel permits held media to resume", "resumeMedia()" in cancel and "pendingStart = nil" in cancel),
    ("pending Escape discard also releases media hold", "resumeMedia()" in block(block(app_source, "private func discard()"), "if let capture = pendingStart")),
    ("pending capture blocks resume timer and callback", all("pendingStart != nil" in block(app_source, marker) for marker in ["private func resumeMedia()", "private func resumeNow()"])),
    ("target discovery has full budget and retries", "StartTargetWait.cap" in target_source and "read(stamp, deadline: deadline)" in target_source and "repeat {" in target_source and "0.025" not in target_source),
    ("slow AX calls get policy timeout", "min(StartTargetWait.callTimeout, left)" in target_source),
    ("target cap runs synchronous fallback only after policy decision", "case .fallback:" in resolve_target and "accepted = fallbackStartTarget(capture)" in resolve_target and "StartTargetWait.cap" in prepare),
    ("fallback retains old focus capture with identity rechecks", all(term in fallback_target for term in ["Insert.focus().kind == .text", "Insert.focusedElement()", "Self.boxPrint(element, withText: true)", "CFEqual(current, element)", "CFEqual(currentWindow, window)"]) and fallback_target.count("startTargetUnchanged(capture)") == 2),
    ("unverified target keeps complete ending for explicit paste", "let targetUncertain = startTargetUncertain" in app_source and "var kept = targetUncertain" in app_source and "unverified start target, kept for Paste last" in app_source),
    ("unverified target blocks legacy live typing", "guard !startTargetUncertain else" in block(app_source, "private func piece(")),
    ("slow and capped counts and elapsed time logged", all(term in resolve_target for term in ["elapsed_ms=", "slow_count=", "capped_count=", "accepted="])),
    ("first draft trace carries no text length", "StartTrace.note(.firstDraftReady, gesture: traceID)" in session and "firstDraftReady, gesture: traceID, count:" not in session),
    ("non-text key downs and modifier changes invalidate target", 'draftInputMonitor.record(talkKey: false, at: e.timestamp)' in block(hold_source, "private func key(") and 'draftInputMonitor.record(talkKey: false, at: e.timestamp)' in block(hold_source, "private func flagsChanged(") and "guard talk, modifierCodes" not in (ROOT / "Sources/RedpenVoice/DraftInputMonitor.swift").read_text()),
]
insert_source = (ROOT / "Sources/RedpenVoice/Insert.swift").read_text()
replace_source = block(insert_source, "static func replaceDraft(")
finish_source = block(session, "func finish()")
wiring_checks += [
    ("prefix adapter types only planned suffix", "type(edit.replacement, while: safe)" in replace_source and "type(replacement," not in replace_source),
    ("prefix adapter keeps full-box and cursor evidence", all(term in replace_source for term in ["DraftReplacement(expectedBox: expectedBox, actual: value, cursor: cursor", "guard still()", "confirm(edit.expected, in: element, while: safe)"])),
    ("prefix adapter never retries uncertain edit", replace_source.count("backspace(") == 1 and replace_source.count("type(edit.replacement,") == 1),
    ("new press revokes old checked-tail cache after capture attaches", "finishingDrafting?.owner.invalidateTail()" in begin and begin.index("recorder.begin(") < begin.index("finishingDrafting?.owner.invalidateTail()")),
    ("Escape cancels cache and tasks", "clearDraftTailLocked()" in block(session, "func cancel()") and "session?.cancel()" in block(app_source, "private func discard()")),
    ("ending waits for capture before finish", block(app_source, "private func end()").index("self.recorder.end()") < block(app_source, "private func end()").index("s.finish()")),
    ("Enter waits for checked finish and confirmed delivery", block(app_source, "private func end()").index("s.finish()") < block(app_source, "private func end()").index("self.finishEnter(gen: gen, wordsIn: inserted && !(long && s.endingLost))")),
    ("tail work never publishes draft or check", all(term not in block(session, "private func prepareDraftTail(") for term in ["onDraft?", "onCheck?", "pieces.append("])),
    ("speculation lower priority and no ordinary-loop await", ".utility" in block(session, "private func prepareDraftTail(") and "await task.value" not in block(session, "private func prepareDraftTail(")),
    ("ordinary checks cancel speculation before inference", "lock.withLock { clearDraftTailLocked() }" in block(session, "func stream(_ chunker:")),
    ("cleanup clears cached audio identity", "clearDraftTailLocked()" in block(session, "fileprivate func acceptMediaResult(") and "audioGeneration += 1" in block(session, "func silence(")),
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
    static let lock = NSLock()
    static var calls = 0
    static var delay = 0
    static var ignoreCancellation = false
    static var count: Int { lock.withLock { calls } }
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
    static var lastJob = 10.0
    static func prompt(_ hints: String, _ previous: String?) -> String { hints }
    static func whisperText(_ w: WhisperKit, _ a: [Float], prompt: String? = nil,
                            speculative: Bool = false, preempt: (@Sendable () -> Void)? = nil) async throws -> String {
        try await gate.acquire(speculative: speculative, preempt: preempt)
        do {
            try Task.checkCancellation()
            FakeASR.lock.withLock { FakeASR.calls += 1 }
            if FakeASR.delay > 0 {
                if FakeASR.ignoreCancellation { try? await Task.sleep(for: .milliseconds(FakeASR.delay)) }
                else { try await Task.sleep(for: .milliseconds(FakeASR.delay)) }
            }
            if !FakeASR.ignoreCancellation { try Task.checkCancellation() }
            let text = try FakeASR.read(a)
            await gate.release()
            return text
        } catch { await gate.release(); throw error }
    }
    static func parakeetText(_ p: AsrManager, _ a: [Float]) async throws -> String { try FakeASR.read(a) }
    __PRODUCTION_GATE__
    static let gate = Gate()
    final class Once {
        let lock = NSLock(); var done = false
        func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }
'''
# Exercise the actual Insert.replaceDraft adapter with an inert editor, never AX or keyboard events.
replacement_adapter = block(insert_source, "static func replaceDraft(")
insert_stubs = r'''

typealias AXUIElement = NSObject
enum Insert {
    static let element = NSObject()
    static var box = ""
    static var deleted = 0, typed = "", attempts = 0
    static var canConfirm = true
    static var lastEdit: (element: AXUIElement, before: String, range: NSRange, replacement: String)?
    static func reset(_ value: String) { box = value; deleted = 0; typed = ""; attempts = 0; canConfirm = true }
    static func value(_ e: AXUIElement) -> String? { box }
    static func selectedRange(_ e: AXUIElement) -> NSRange? { NSRange(location: box.utf16.count, length: 0) }
    static func focusedElement() -> (AXUIElement, Int)? { (element, 1) }
    static func forgetLast() {}
    static func backspace(_ count: Int, while still: () -> Bool) -> Int {
        attempts += 1
        var n = 0
        while n < count && still() { box.removeLast(); deleted += 1; n += 1 }
        return n
    }
    static func type(_ text: String, while still: () -> Bool) -> Bool {
        guard still() else { return false }; typed += text; box += text; return true
    }
    static func confirm(_ expected: String, in e: AXUIElement, while still: () -> Bool) -> Bool {
        still() && canConfirm && BoxText.same(expected, box)
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
    static func until(_ test: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !test(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return test()
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

        for (draft, final, kept, deleted, typed) in [
            ("Already checked.", "Already checked.", "Already checked.", 0, ""),
            ("Same words", "Same words.", "Same words", 0, "."),
            ("Keep wrong ending", "Keep right ending", "Keep ", 12, "right ending"),
            ("👍🏽 Cafe\u{301} yes", "👍🏽 Cafe\u{301} no", "👍🏽 Cafe\u{301} ", 3, "no"),
            ("one  two", "one two.", "one ", 4, "two.")
        ] {
            Insert.reset(draft)
            let ok = Insert.replaceDraft(draft, with: final, expectedBox: draft, in: Insert.element, while: { true })
            check("actual prefix adapter confirms whole result", ok && Insert.box == final)
            check("actual prefix adapter posts only changed suffix", Insert.deleted == deleted && Insert.typed == typed && final.hasPrefix(kept))
        }
        Insert.reset("Changed box")
        check("actual adapter refuses changed full box", !Insert.replaceDraft("draft", with: "checked", expectedBox: "draft", in: Insert.element, while: { true }) && Insert.attempts == 0)
        Insert.reset("Keep wrong words")
        check("actual adapter stops partial edit without retry", !Insert.replaceDraft("Keep wrong words", with: "Keep checked words", expectedBox: Insert.box, in: Insert.element, while: { Insert.deleted < 1 }) && Insert.deleted == 1 && Insert.attempts == 1 && Insert.typed.isEmpty)
        Insert.reset("Keep words")
        Insert.canConfirm = false
        check("actual adapter needs confirmation and never retries", !Insert.replaceDraft("Keep words", with: "Keep words.", expectedBox: Insert.box, in: Insert.element, while: { true }) && Insert.attempts == 1 && Insert.typed == ".")

        // Synthetic ending regressions. Short speech stays below the ordinary four-second check.
        Transcriber.lastJob = 0
        let tailAudio = noise(992, 8000) + [Float](repeating: 0, count: 8000)
        func ready(_ session: Transcriber.Session) async throws -> Bool {
            let logStart = Log.recorded.count
            session.drafter = AsrManager()
            push(tailAudio, to: session)
            session.streamDrafts(); session.stream(Chunker())
            return try await until { Log.recorded.dropFirst(logStart).contains { $0.hasPrefix("ending tail ready:") } }
        }
        FakeASR.text = "Checked synthetic tail."
        FakeASR.delay = 40
        let cached = Transcriber.Session(whisper: WhisperKit())
        check("draft tail ready before stop", try await ready(cached))
        let beforeFinish = FakeASR.count
        push([Float](repeating: 0, count: 1600), to: cached) // capture tail
        let cachedResult = try await cached.finish()
        check("checked cache reused through quiet capture tail", cachedResult == "Checked synthetic tail." && FakeASR.count == beforeFinish)
        check("cache reuse logged numerically", Log.recorded.contains { $0.hasPrefix("ending tail: reused=1 ") })
        let cachedAudio = cached.recorded
        cached.silence(upTo: cachedAudio.count)
        check("late cleanup cannot rewrite cached audio", cached.recorded == cachedAudio)
        cached.cancel()

        let newer = Transcriber.Session(whisper: WhisperKit())
        check("second checked tail ready", try await ready(newer))
        let oldCount = FakeASR.count
        FakeASR.text = "Checked new syllable."
        push([0.1] + [Float](repeating: 0, count: 16), to: newer)
        check("partial-frame speech forces fresh checked tail", try await newer.finish() == "Checked new syllable." && FakeASR.count == oldCount + 1)
        newer.cancel()

        let pressed = Transcriber.Session(whisper: WhisperKit())
        check("tail ready before new press", try await ready(pressed))
        let pressCount = FakeASR.count
        pressed.invalidateTail()
        check("new press rejects ready cache", try await pressed.finish() == "Checked new syllable." && FakeASR.count == pressCount + 1)
        pressed.cancel()

        let escaped = Transcriber.Session(whisper: WhisperKit())
        check("tail ready before Escape", try await ready(escaped))
        let escapeCount = FakeASR.count
        escaped.cancel()
        do { _ = try await escaped.finish(); check("Escape cannot finish", false) }
        catch { check("Escape cannot publish or run fresh ASR", FakeASR.count == escapeCount && escaped.lastTail.isEmpty) }

        // A speculative check already running at stop is awaited once, without cancelling and redoing it.
        FakeASR.delay = 300
        let inflight = Transcriber.Session(whisper: WhisperKit())
        inflight.drafter = AsrManager(); push(tailAudio, to: inflight)
        let inCount = FakeASR.count
        inflight.stream(Chunker())
        check("speculative job starts in pause", try await until { FakeASR.count > inCount })
        check("inflight matching check reused once", try await inflight.finish() == "Checked new syllable." && FakeASR.count == inCount + 1)
        inflight.cancel()

        let resuming = Transcriber.Session(whisper: WhisperKit())
        resuming.drafter = AsrManager(); push(tailAudio, to: resuming)
        let resumeCount = FakeASR.count
        resuming.stream(Chunker())
        check("guess running before resumed speech", try await until { FakeASR.count > resumeCount })
        push([0.1], to: resuming)
        FakeASR.text = "Fresh checked resumption."
        check("new speech cancels inflight stale check", try await resuming.finish() == "Fresh checked resumption." && FakeASR.count == resumeCount + 2)
        resuming.cancel()

        FakeASR.ignoreCancellation = true
        let discarding = Transcriber.Session(whisper: WhisperKit())
        discarding.drafter = AsrManager(); push(tailAudio, to: discarding)
        let discardCount = FakeASR.count
        discarding.stream(Chunker())
        check("guess running before discard", try await until { FakeASR.count > discardCount })
        discarding.cancel()
        do { _ = try await discarding.finish(); check("inflight Escape cannot finish", false) }
        catch { check("inflight Escape cannot publish", discarding.lastTail.isEmpty) }
        // Acquire/release the real gate to prove a cancelled guess does not leave it occupied.
        try await Transcriber.gate.acquire()
        await Transcriber.gate.release()
        check("discarded guess leaves gate usable", discarding.lastTail.isEmpty)
        FakeASR.ignoreCancellation = false
        FakeASR.text = "Checked new syllable."

        // A different foreground Session preempts the production Whisper gate's speculative owner.
        let preempted = Transcriber.Session(whisper: WhisperKit())
        preempted.drafter = AsrManager(); push(tailAudio, to: preempted)
        let preemptCount = FakeASR.count
        preempted.stream(Chunker())
        check("preemptible guess started", try await until { FakeASR.count > preemptCount })
        let preemptLog = Log.recorded.count
        let foreground = Transcriber.Session(whisper: WhisperKit())
        push(tailAudio, to: foreground)
        check("foreground tail completes through production gate", try await foreground.finish() == "Checked new syllable.")
        preempted.invalidateTail()
        check("preempted guess never publishes", preempted.lastTail.isEmpty && !Log.recorded.dropFirst(preemptLog).contains { $0.hasPrefix("ending tail ready:") })
        foreground.cancel(); preempted.cancel()
        let priorityGate = Transcriber.Gate()
        try await priorityGate.acquire()
        do {
            try await priorityGate.acquire(speculative: true)
            check("speculation never queues behind foreground", false)
        } catch { check("busy gate skips speculation", true) }
        let cancelledWaiter = Task {
            do { try await priorityGate.acquire(); await priorityGate.release(); return false }
            catch { return true }
        }
        cancelledWaiter.cancel()
        check("cancelled waiter leaves foreground queue", await cancelledWaiter.value)
        await priorityGate.release()
        try await priorityGate.acquire()
        await priorityGate.release()
        check("cancelled waiter never strands gate", true)
        FakeASR.delay = 0
        Transcriber.lastJob = 10

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

        // A slow target must leave opening PCM buffered, not start a draft without its start-box protection.
        var targetWait = StartTargetWait(at: 0)
        let slowCapture = TalkCapture<[Float]>(maxFrames: 48_000)
        let slowSession = Transcriber.Session(whisper: WhisperKit())
        slowCapture.append(firstTap, frames: firstTap.count)
        check("slow target holds transcription past 300ms", targetWait.result(found: false, unchanged: true, at: 0.3) == .wait && slowSession.recorded.isEmpty)
        slowCapture.append(gap, frames: gap.count)
        check("slow target accepted at 1.4 seconds", targetWait.result(found: true, unchanged: true, at: 1.4) == .adopt)
        check("slow discovery retains all opening PCM once", slowCapture.activate { push($0, to: slowSession) } && slowSession.recorded == firstTap + gap)
        check("late target cannot replay opening PCM", targetWait.result(found: true, unchanged: true, at: 2) == .wait && !slowCapture.activate { push($0, to: slowSession) })
        slowSession.cancel()
        for byOtherKey in [true, false] {
            var delivery = DictationDelivery()
            delivery.begin(); delivery.confirm()
            let finishingA = delivery.current
            var key = TalkKeyState()
            _ = key.event(key: 63, down: true, at: 0)
            delivery.begin()
            _ = key.event(key: 63, down: false, at: 0.1)
            check("finishing tap cancellation classified", (byOtherKey ? key.otherKey(at: 0.2) : key.expireTap(at: 0.6)) == .cancel)
            check("finishing delivery survives pending tap", delivery.cancel(disposableTap: true) && delivery.current == finishingA)
        }

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
    source.write_text(stubs.replace("__PRODUCTION_GATE__", gate) + session + "\n}\n" + recording + insert_stubs + replacement_adapter + "\n}\n" + tests)
    core = ROOT / "Sources/VoiceCore"
    files = [core / name for name in ["MediaEcho.swift", "MediaAudio.swift", "MediaOpening.swift", "MediaGate.swift", "Chunker.swift",
                                    "Silence.swift", "FocusGate.swift", "CheckedTail.swift", "BoxText.swift", "EnterSend.swift", "LongTalk.swift", "BoxMatch.swift", "DictationEnding.swift", "TalkKeyState.swift", "DictationDelivery.swift", "TalkTimingTrace.swift", "TalkCapture.swift", "StartTargetWait.swift"]]
    subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-swift-version", "5", str(source),
                    *map(str, files), "-o", str(tmp / "check")], cwd=ROOT, check=True)
    subprocess.run([str(tmp / "check")], cwd=ROOT, check=True, env=os.environ)
