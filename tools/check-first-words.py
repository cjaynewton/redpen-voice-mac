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
media_adapter = (ROOT / "Sources/RedpenVoice/Media.swift").read_text()
resume_media = block(app_source, "private func resumeNow()")
wiring_checks += [
    ("browser pause has separate lifecycle and recording gate", "BrowserPauseOperation" in media_adapter and "needsPause:" in media and "self?.session === s" in media),
    ("old browser completion cannot mutate new hold", media.index("guard self.mediaPause.owns(pauseToken), self.session === s") < media.index("self.pausedHow = how")),
    ("browser operation stops when recording ends", "browserPause?.stop()" in block(app_source, "private func end()")),
    ("browser cancellation stops future pauses", "browserPause?.stop(cancelled: true)" in cancel),
    ("accepted down transfers browser marks", "browserPause?.transfer(to: mediaPause.generation)" in begin),
    ("resume waits for in-flight browser answer", "operation.onSettled" in resume_media and "!operation.finished" in resume_media),
    ("pause-only reconciliation never plays", "releaseBrowserPause(play: false)" in resume_media and "play: play" in media_adapter),
    ("resume rechecks owner before each browser action", "guard allowed() else" in media_adapter[media_adapter.index("static func resume("):media_adapter.index("    /// Until when")] and "DispatchQueue.main.sync(execute: allowed)" in media_adapter),
    ("recovery never uses old key fallback", "!operation.recovery && BrowserMedia.keyAfterQuietCheck" in media_adapter),
    ("browser reference and audio deadlines unchanged", "private var mediaOpening = MediaOpening()" in session and "MediaOpening.timeout" not in media_adapter and "SoundTap" not in media_adapter),
]
insert_source = (ROOT / "Sources/RedpenVoice/Insert.swift").read_text()
replace_source = block(insert_source, "static func replaceDraft(")
finish_source = block(session, "func finish()")
wiring_checks += [
    ("prefix adapter types only planned suffix", "type(edit.replacement, while: safe)" in replace_source and "type(replacement," not in replace_source),
    ("prefix adapter keeps full-box and cursor evidence", all(term in replace_source for term in ["DraftReplacement(expectedBox: expectedBox, actual: value, cursor: cursor", "guard await still()", "confirm(edit.expected, in: element, while: still)"])),
    ("prefix adapter never retries uncertain edit", replace_source.count("backspace(") == 1 and replace_source.count("type(edit.replacement,") == 1),
    ("new press preserves finishing session tail", "invalidateTail" not in begin and "clearDraftTailLocked" not in begin),
    ("Escape cancels cache and tasks", "clearDraftTailLocked()" in block(session, "func cancel()") and "session?.cancel()" in block(app_source, "private func discard()")),
    ("ending waits for capture before finish", block(app_source, "private func end()").index("self.recorder.end()") < block(app_source, "private func end()").index("s.finish()")),
    ("Enter waits for checked finish and confirmed delivery", block(app_source, "private func end()").index("s.finish()") < block(app_source, "private func end()").index("self.finishEnter(gen: gen, wordsIn: inserted && !(long && s.endingLost))")),
    ("tail work never publishes draft or check", all(term not in block(session, "private func prepareDraftTail(") for term in ["onDraft?", "onCheck?", "pieces.append("])),
    ("tail staging never starts inference or an asynchronous job", all(term not in block(session, "private func prepareDraftTail(") for term in ["whisperText", "Task.detached", "Task {", "gate.acquire"])),
    ("tail staging never seals cleanup", "cleanupSealed = true" not in block(session, "private func prepareDraftTail(")),
    ("no speculative task can be orphaned at stop", all(term not in session for term in ["draftTailTask", "draftTailID", "draftTailText", "priority: .utility", "preempt:"])),
    ("final check is awaited directly", "tail = try await Transcriber.whisperText(whisper, finalAudio" in finish_source),
    ("final gate wait and outcome logged including retry", 'ending check: in line \(inLine)ms outcome=\(endingOutcome)' in transcriber_source and 'ending check retry: in line \(retryInLine)ms outcome=\(endingOutcome)' in transcriber_source),
    ("foreground audio selection seals cleanup", "cleanupSealed = true" in finish_source),
    ("ordinary checks clear staged audio before inference", "lock.withLock { clearDraftTailLocked() }" in block(session, "func stream(_ chunker:")),
    ("cleanup clears cached audio identity", "clearDraftTailLocked()" in block(session, "fileprivate func acceptMediaResult(") and "audioGeneration += 1" in block(session, "func silence(")),
]
wiring_checks += [
    ("default-on setting passed independently of draft mode", 'config.fasterFinish != false { s.fastFinisher = parakeet }' in transcriber_source),
    ("fast engine loads for default-on finish", 'config.fasterFinish != false { await loadDraftEngine() }' in transcriber_source),
    ("fast finish shares sealed final audio", 'Transcriber.parakeetText(fastFinisher, finalAudio)' in finish_source),
    ("same names and ums pipeline after either engine", all(term in block(app_source, "private func end()") for term in ['raw = self.names.apply(raw)', 'Fillers.strip(raw)', 's.finish()'])),
    ("draft callbacks serialize edit and bookkeeping", 'self.edits.enqueue { await self.draft(i, t, from: s) }' in app_source and 'self.edits.enqueue { await self.check(r, t, from: s) }' in app_source),
    ("capture stops independently of edit queue", block(app_source, "private func end()").index('self.recorder.end()') < block(app_source, "private func end()").index('await self.edits.enqueue')),
    ("confirmed edits await off-main reads", 'await EditWait.confirm' in insert_source and 'Task.detached(priority: .userInitiated)' in block(insert_source, 'private static func confirm(')),
    ("edit pacing never sleeps the main thread", 'usleep(' not in insert_source),
    ("deferred correction revokes on send and newer press", all(term in block(app_source, "private func swapEnding(") for term in ['!start.sent', 'self.delivery == d.generation'])),
    ("suspended final delivery revokes on a sent Enter", 'self.enterRevision == endingEnterRevision' in block(app_source, "private func end()")),
    ("waiting short delivery cannot overlap new recording", 'self.session == nil && self.delivery == gen' in block(app_source, "private func checkWaiting(")),
]
end_source = block(app_source, "private func end()")
queued_finish = end_source[end_source.index("await self.edits.enqueue"):]
wiring_checks += [
    ("discard considers unconfirmed and partial attempts", "d.typedAny || d.deliveryUncertain" in block(app_source, "private func discard()")),
    ("discard proves uncertain draft before removal", "reconcileLateDraft(d)" in block(app_source, "private func removeDrafts(") and "guard d.lateDraft == nil else { return false }" in app_source),
    ("cleanup network outside edit queue", end_source.index("await Cleanup.run(raw)") < end_source.index("await self.edits.enqueue")),
    ("tap classification sleeps outside edit queue", "Task.sleep" not in queued_finish),
    ("long paste quiet wait outside edit queue", "Task.sleep" not in block(app_source, "private func finishLongDrafts(")),
    ("queued finish revalidates tap before editing", "guard self.deliveries.waitForTap(after: gen) <= 0" in queued_finish),
    ("Paste last serialized and revalidates generation", "edits.enqueue" in block(app_source, "private func pasteLastNow(") and "self.delivery == gen" in block(app_source, "private func pasteLastNow(")),
    ("waiting timer coalesces pending edit jobs", "!self.waitingCheckPending" in block(app_source, "private func holdForClick(")),
    ("Return and backstop respect same posting boundary", "EditBoundary.shared.sendWhenSafe" in (ROOT / "Sources/RedpenVoice/EnterSendTap.swift").read_text()),
    ("Enter override invalidates ending across cleanup waits", end_source.index("let endingEnterRevision = enterRevision") < end_source.index("s.finish()") and "var newer = self.delivery != gen || self.enterRevision != endingEnterRevision" in queued_finish),
    ("main hardware check asynchronously awaits listener", "await DraftSafety.resolveHardwareAsync" in block(app_source, "private func draftQuiet(") and "await DraftSafety.resolveHardwareAsync" in block(app_source, "private static func userQuietSinceAsync(")),
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
    static var whisperAudio: [[Float]] = []
    static var fastAudio: [[Float]] = []
    static var fastDelay = 0
    static var fastFails = false
    static var fastEmpty = false
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
                            endingOutcome: Int? = nil) async throws -> String {
        let inLine = try await gate.acquire()
        if let endingOutcome { Log.note("ending check: in line \(inLine)ms outcome=\(endingOutcome)") }
        do {
            try Task.checkCancellation()
            FakeASR.lock.withLock { FakeASR.calls += 1; FakeASR.whisperAudio.append(a) }
            if FakeASR.delay > 0 {
                if FakeASR.ignoreCancellation {
                    let delay = FakeASR.delay
                    // A detached wait really ignores cancellation of the calling engine task.
                    await Task.detached { try? await Task.sleep(for: .milliseconds(delay)) }.value
                }
                else { try await Task.sleep(for: .milliseconds(FakeASR.delay)) }
            }
            if !FakeASR.ignoreCancellation { try Task.checkCancellation() }
            let text = try FakeASR.read(a)
            await gate.release()
            return text
        } catch { await gate.release(); throw error }
    }
    static func parakeetText(_ p: AsrManager, _ a: [Float]) async throws -> String {
        FakeASR.lock.withLock { FakeASR.fastAudio.append(a) }
        if FakeASR.fastDelay > 0 { try await Task.sleep(for: .milliseconds(FakeASR.fastDelay)) }
        if FakeASR.fastFails { throw NSError(domain: "synthetic-fast", code: 1) }
        return FakeASR.fastEmpty ? "" : try FakeASR.read(a)
    }
    __PRODUCTION_GATE__
    static let gate = Gate()
    final class Once {
        let lock = NSLock(); var done = false
        func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
    }
'''
# Exercise the actual Insert.replaceDraft adapter with an inert editor, never AX or keyboard events.
replacement_adapter = block(insert_source, "static func replaceDraft(")
text_start = insert_source[insert_source.index("static func text("):]
text_adapter = text_start[:text_start.index("async -> Bool {")] + block(text_start, "async -> Bool {")
insert_stubs = r'''

typealias AXUIElement = NSObject
let kAXFocusedUIElementAttribute = "focus"
let kAXSelectedTextAttribute = "text"
enum FakeAXResult { case success, failure }
func AXUIElementCreateSystemWide() -> AXUIElement { Insert.element }
func AXUIElementCopyAttributeValue(_ el: AXUIElement, _ attr: CFString, _ result: inout CFTypeRef?) -> FakeAXResult {
    result = Insert.element; return .success
}
func AXUIElementGetTypeID() -> CFTypeID { CFGetTypeID(Insert.element) }
func AXUIElementSetAttributeValue(_ el: AXUIElement, _ attr: CFString, _ value: CFString) -> FakeAXResult {
    guard Insert.axAccepts else { return .failure }
    Insert.box += value as String; return .success
}
enum Insert {
    static let element = NSObject()
    static var box = ""
    static var deleted = 0, typed = "", attempts = 0
    static var typedSome = false, typedCount = 0, typedPadding = 0, unconfirmed = false
    static var axAccepts = false
    static var dictation: Int?
    static var draftAttempt: (element: AXUIElement, draft: DictationEnding.LateDraft)?
    static var onTypeChunk: (() -> Void)?
    static var ownWindowInFront: Bool { false }
    static var canTypeAtFocus: Bool { true }
    static func wakeElectron(_ e: AXUIElement) {}
    static func fit(_ text: String, in e: AXUIElement) -> String { text }
    static func spaced(_ text: String, before e: AXUIElement) -> String { text }
    static func remember(_ text: String) {}
    static func landed(in e: AXUIElement, before: String) async -> Bool { box != before }
    static var canConfirm = true
    static var onConfirm: (() -> Void)?
    static var lastEdit: (element: AXUIElement, before: String, range: NSRange, replacement: String)?
    static func reset(_ value: String) { box = value; deleted = 0; typed = ""; attempts = 0; canConfirm = true; onConfirm = nil; onTypeChunk = nil; axAccepts = false; typedSome = false; typedCount = 0 }
    static func value(_ e: AXUIElement) -> String? { box }
    static func selectedRange(_ e: AXUIElement) -> NSRange? { NSRange(location: box.utf16.count, length: 0) }
    static func focusedElement() -> (AXUIElement, Int)? { (element, 1) }
    static func forgetLast() {}
    static func backspace(_ count: Int, while still: () async -> Bool) async -> Int {
        attempts += 1
        var n = 0
        while n < count {
            guard await still() else { break }
            box.removeLast(); deleted += 1; n += 1
        }
        return n
    }
    static func type(_ text: String, while still: () async -> Bool) async -> Bool {
        let units = Array(text.utf16)
        for from in stride(from: 0, to: units.count, by: 20) {
            guard await still() else { return false }
            let part = Array(units[from..<min(from + 20, units.count)])
            let posted = String(decoding: part, as: UTF16.self)
            typed += posted; box += posted; typedSome = true; typedCount += part.count
            if let onTypeChunk { await Task.yield(); onTypeChunk() }
        }
        return await still()
    }
    static func confirm(_ expected: String, in e: AXUIElement, while still: () async -> Bool, attempts: Int = 20) async -> Bool {
        if let onConfirm { await Task.yield(); onConfirm() }
        guard await still() else { return false }
        return canConfirm && BoxText.same(expected, box)
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
    @MainActor static func main() async throws {
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
            let ok = await Insert.replaceDraft(draft, with: final, expectedBox: draft, in: Insert.element, while: { true })
            check("actual prefix adapter confirms whole result", ok && Insert.box == final)
            check("actual prefix adapter posts only changed suffix", Insert.deleted == deleted && Insert.typed == typed && final.hasPrefix(kept))
        }
        Insert.reset("Changed box")
        check("actual adapter refuses changed full box", !(await Insert.replaceDraft("draft", with: "checked", expectedBox: "draft", in: Insert.element, while: { true })) && Insert.attempts == 0)
        Insert.reset("Keep wrong words")
        check("actual adapter stops partial edit without retry", !(await Insert.replaceDraft("Keep wrong words", with: "Keep checked words", expectedBox: Insert.box, in: Insert.element, while: { Insert.deleted < 1 })) && Insert.deleted == 1 && Insert.attempts == 1 && Insert.typed.isEmpty)
        Insert.reset("Keep words")
        Insert.canConfirm = false
        check("actual adapter needs confirmation and never retries", !(await Insert.replaceDraft("Keep words", with: "Keep words.", expectedBox: Insert.box, in: Insert.element, while: { true })) && Insert.attempts == 1 && Insert.typed == ".")

        for change in ["sent", "moved", "Escape"] {
            Insert.reset("Keep words")
            var ownsBox = true
            Insert.onConfirm = { ownsBox = false }
            let edited = await Insert.replaceDraft("Keep words", with: "Keep words.", expectedBox: "Keep words", in: Insert.element, while: { ownsBox })
            check("actual asynchronous adapter refuses confirmation after \(change)", !edited && Insert.attempts == 1 && Insert.typed == ".")
        }
        Insert.onConfirm = nil

        // Actual Insert.text cancelled in AX confirmation or between posted chunks.
        for viaAX in [false, true] {
            Insert.reset("Original ")
            var recording = true
            Insert.axAccepts = viaAX
            if viaAX { Insert.onConfirm = { recording = false } }
            else { Insert.onTypeChunk = { recording = false } }
            let attempted = "These are words that span more than one typing chunk"
            let typed = await Insert.text(attempted, joining: 7, confirmed: true, while: { recording })
            check("Escape interrupts actual draft posting/confirm", !typed && Insert.unconfirmed)
            let posted = viaAX ? attempted : String(attempted.prefix(20))
            check("Escape retains exact posted attempt", Insert.draftAttempt?.draft.text == posted && Insert.box == "Original " + posted)
            let start = BoxPrint(role: "AXTextArea", identifier: nil, frame: nil, text: "Original ", title: "Chat")
            let match = DictationEnding.reconcileLateDraft(Insert.draftAttempt!.draft, confirmedDrafts: "", start: start, now: start,
                actual: Insert.box, cursor: Insert.selectedRange(Insert.element), sameElement: true, sameWindow: true,
                userEdited: false, inStartBox: true)
            check("Escape can prove exactly the posted text", match?.text == posted)
            let removed = await Insert.replaceDraft(match!.text, with: "", expectedBox: match!.box.text!, in: Insert.element, while: { true })
            check("Escape removes only proven own text", removed && Insert.box == "Original ")
        }
        Insert.onConfirm = nil; Insert.onTypeChunk = nil

        // Both second Enter and cap wait only for the posting transaction, not AX confirmation.
        for reason in ["second Enter", "Enter cap", "backstop"] {
            Insert.reset("wrong")
            var returned = false
            Insert.onTypeChunk = {
                EditBoundary.shared.sendWhenSafe { returned = true }
                check("\(reason) waits until matching retype completes", !returned && Insert.box == "right")
            }
            Insert.onConfirm = { check("\(reason) precedes confirmation", returned) }
            _ = await Insert.replaceDraft("wrong", with: "right", expectedBox: "wrong", in: Insert.element, while: { true })
            check("\(reason) sends at safe boundary", returned)
        }
        Insert.onTypeChunk = nil; Insert.onConfirm = nil

        // The async listener grace catches held Enter; unknown typing and clicks still fail closed.
        var listenerReads = 0
        var mainTurn = false
        let mainJob = Task { @MainActor in mainTurn = true }
        let caught = await DraftSafety.resolveHardwareAsync(since: 1) {
            listenerReads += 1
            return .init(now: 2, keyDownAgo: 0, leftClickAgo: 10, rightClickAgo: 10,
                talkKeyDownTimes: listenerReads > 1 ? [2] : [], typingKeyDownAt: nil)
        }
        await mainJob.value
        check("listener grace catches late Enter evidence", caught.failure(since: 1) == nil && listenerReads == 2)
        check("listener grace yields the main actor", mainTurn)
        var unknownReads = 0
        let unknown = await DraftSafety.resolveHardwareAsync(since: 1) {
            unknownReads += 1
            return .init(now: 2, keyDownAgo: 0, leftClickAgo: 10, rightClickAgo: 10,
                talkKeyDownTimes: [], typingKeyDownAt: nil)
        }
        check("listener grace bounded to two waits", unknownReads == 3 && unknown.failure(since: 1) == .hardwareKey)
        var clickReads = 0
        let click = await DraftSafety.resolveHardwareAsync(since: 1) {
            clickReads += 1
            return .init(now: 2, keyDownAgo: 0, leftClickAgo: 0, rightClickAgo: 10,
                talkKeyDownTimes: [], typingKeyDownAt: nil)
        }
        check("listener never grants exemption to a click", clickReads == 1 && click.failure(since: 1) != nil)

        // The real confirmation wait and edit queue, with a blocking fake AX read on a worker.
        let edits = SerialEdits()
        var slowReadStarted = false, confirmedSlow = false, laterEditRan = false
        let pendingEdit = edits.enqueue {
            confirmedSlow = await EditWait.confirm(attempts: 1, while: { true }) {
                slowReadStarted = true
                return await Task.detached { Thread.sleep(forTimeInterval: 1.3); return true }.value
            }
        }
        check("fake AX confirmation started", try await until { slowReadStarted })
        let keyScheduled = ProcessInfo.processInfo.systemUptime
        var enter = EnterSend()
        enter.arm(now: keyScheduled)
        let response = await Task { @MainActor in
            let handled = ProcessInfo.processInfo.systemUptime
            return (handled - keyScheduled, enter.keyDown(code: 36, flags: 0, own: false, repeated: false, now: handled))
        }.value
        check("Enter handler runs within 50ms during 1300ms AX read", response.0 < 0.05)
        if case .hold = response.1 {} else { check("Enter held during confirmation", false) }
        check("Enter runs before AX completion", !confirmedSlow)
        let laterEdit = edits.enqueue { laterEditRan = true }
        check("later edit cannot overtake suspended AX confirmation", !laterEditRan)
        await pendingEdit.value
        await laterEdit.value
        check("confirmation and subsequent edit both complete in order", confirmedSlow && laterEditRan)
        var allowed = true
        let revoked = await EditWait.confirm(attempts: 1, while: { allowed }) {
            allowed = false; return true
        }
        check("confirmation cannot succeed after ownership revoked", !revoked)
        let invalidFocus = await EditWait.confirm(attempts: 20, while: { true }, read: { nil })
        check("changed focus ends confirmation immediately", !invalidFocus)
        print("simulated Enter handler delay \(Int(response.0 * 1000))ms during 1300ms fake AX read")

        // Actual Session routing, cleaned PCM, fallback, word processing and Escape.
        FakeASR.text = "um monika sends two reports"
        for (seconds, enabled, expectedFast) in [(19.99, true, true), (20.0, true, true), (20.01, true, false), (3.0, false, false)] {
            let short = Transcriber.Session(whisper: WhisperKit())
            if enabled { short.fastFinisher = AsrManager() }
            let audio = [Float](repeating: 0.1, count: Int(seconds * 16000))
            push(audio, to: short)
            let fastBefore = FakeASR.lock.withLock { FakeASR.fastAudio.count }
            let whisperBefore = FakeASR.count
            let text = try await short.finish()
            check("actual Session short/long/off engine route", (FakeASR.lock.withLock { FakeASR.fastAudio.count } > fastBefore) == expectedFast)
            check("fast finish avoids Whisper tail inference", FakeASR.count - whisperBefore == (expectedFast ? 0 : 1))
            check("fast result uses unchanged names then ums processing", Fillers.strip(Names(text: "monika = Monica").apply(text)) == "Monica sends two reports")
            short.cancel()
        }
        Transcriber.lastJob = 0
        let earlyFast = Transcriber.Session(whisper: WhisperKit())
        earlyFast.fastFinisher = AsrManager()
        FakeASR.text = "Whisper already checked this ending."
        let earlyBefore = FakeASR.count
        push(noise(777, 16000) + [Float](repeating: 0, count: 16000), to: earlyFast)
        earlyFast.stream(Chunker())
        check("ordinary early Whisper inference runs", try await until { FakeASR.count > earlyBefore })
        // Let the stream publish the completed fake result before stop cancels its nap.
        try await Task.sleep(for: .milliseconds(100))
        let earlyFastBefore = FakeASR.lock.withLock { FakeASR.fastAudio.count }
        let checkedBefore = FakeASR.count
        let earlyResult = try await earlyFast.finish()
        check("already checked Whisper beats enabled fast finish", earlyResult == "Whisper already checked this ending." && FakeASR.count == checkedBefore)
        check("already checked Whisper starts no fast inference", FakeASR.lock.withLock { FakeASR.fastAudio.count } == earlyFastBefore)
        check("early reuse numeric outcome logged", Log.recorded.contains { $0.hasPrefix("ending tail: reused=1 outcome=1 ") })
        earlyFast.cancel()
        Transcriber.lastJob = 10

        let cleanedFast = Transcriber.Session(whisper: WhisperKit())
        cleanedFast.fastFinisher = AsrManager()
        let fastPCM = noise(333, 32000)
        push(fastPCM, to: cleanedFast)
        cleanedFast.silence(upTo: 8000)
        let fastCleanedPCM = cleanedFast.recorded
        _ = try await cleanedFast.finish()
        check("fast final gets cleaned PCM byte for byte", FakeASR.lock.withLock { FakeASR.fastAudio.last == fastCleanedPCM } && fastCleanedPCM.prefix(8000).allSatisfy { $0 == 0 })
        cleanedFast.silence(upTo: 16000)
        check("fast consumption seals cleanup", cleanedFast.recorded == fastCleanedPCM)
        cleanedFast.cancel()
        let failedFast = Transcriber.Session(whisper: WhisperKit())
        failedFast.fastFinisher = AsrManager(); push(fastPCM, to: failedFast)
        FakeASR.fastFails = true
        let beforeFallback = FakeASR.count
        _ = try await failedFast.finish()
        check("fast failure checks remaining speech once with Whisper", FakeASR.count == beforeFallback + 1)
        FakeASR.fastFails = false
        failedFast.cancel()
        let emptyFast = Transcriber.Session(whisper: WhisperKit())
        emptyFast.fastFinisher = AsrManager(); push(fastPCM, to: emptyFast)
        FakeASR.fastEmpty = true
        let beforeEmptyFallback = FakeASR.count
        let emptyRecovered = try await emptyFast.finish()
        check("empty fast result cannot lose nonempty speech", !emptyRecovered.isEmpty && FakeASR.count == beforeEmptyFallback + 1)
        FakeASR.fastEmpty = false
        emptyFast.cancel()

        let joinedFast = Transcriber.Session(whisper: WhisperKit())
        joinedFast.drafter = AsrManager(); joinedFast.fastFinisher = AsrManager()
        let headAudio = noise(334, 96000) + [Float](repeating: 0, count: 16000)
        FakeASR.text = "Whisper checked head."
        joinedFast.streamDrafts(); joinedFast.stream(Chunker())
        push(headAudio, to: joinedFast)
        check("ordinary Whisper head commits before fast ending", try await until { joinedFast.written.count == 1 })
        let checkedSamples = FakeASR.lock.withLock { FakeASR.whisperAudio.last!.count }
        let newTail = noise(335, 8000)
        push(newTail, to: joinedFast)
        FakeASR.text = "Fast complete tail."
        let joinedResult = try await joinedFast.finish()
        check("fast ending preserves checked head and joins new tail", joinedResult == "Whisper checked head. Fast complete tail.")
        check("fast input starts at exact committed boundary", FakeASR.lock.withLock { FakeASR.fastAudio.last == Array((headAudio + newTail).dropFirst(checkedSamples)) })
        joinedFast.cancel()
        let cancelledFast = Transcriber.Session(whisper: WhisperKit())
        cancelledFast.fastFinisher = AsrManager(); push(fastPCM, to: cancelledFast)
        FakeASR.fastDelay = 100
        let fastCount = FakeASR.lock.withLock { FakeASR.fastAudio.count }
        let cancelledRun = Task { try await cancelledFast.finish() }
        check("fast inference started before Escape", try await until { FakeASR.lock.withLock { FakeASR.fastAudio.count > fastCount } })
        cancelledFast.cancel()
        do { _ = try await cancelledRun.value; check("Escape must suppress fast result", false) }
        catch { check("Escape suppresses fast result", error is CancellationError) }
        FakeASR.fastDelay = 0

        // Tail staging must never put non-cooperative inference ahead of foreground work.
        Transcriber.lastJob = 0
        let tailAudio = noise(992, 8000) + [Float](repeating: 0, count: 8000)
        func staged(_ session: Transcriber.Session) async throws -> Bool {
            let logStart = Log.recorded.count
            session.drafter = AsrManager()
            push(tailAudio, to: session)
            session.stream(Chunker())
            return try await until { Log.recorded.dropFirst(logStart).contains { $0.hasPrefix("ending tail staged:") } }
        }
        FakeASR.text = "Checked synthetic tail."
        FakeASR.delay = 300
        FakeASR.ignoreCancellation = true
        let preparedLogStart = Log.recorded.count
        let prepared = Transcriber.Session(whisper: WhisperKit())
        let beforeStage = FakeASR.count
        check("tail PCM staged before stop", try await staged(prepared))
        check("staging starts no non-cooperative engine job", FakeASR.count == beforeStage)
        check("staging cannot hold gate", try await Transcriber.gate.acquire() == 0)
        await Transcriber.gate.release()
        let quietTail = [Float](repeating: 0, count: 1600)
        push(quietTail, to: prepared)
        let finalStart = FakeASR.count
        let finalTask = Task { try await prepared.finish() }
        check("foreground check starts at stop", try await until { FakeASR.count == finalStart + 1 })
        check("foreground running at stop has not published", prepared.lastTail.isEmpty)
        let preparedResult = try await finalTask.value
        check("running foreground check awaited once", preparedResult == "Checked synthetic tail." && FakeASR.count == finalStart + 1)
        check("quiet capture extension included byte for byte", FakeASR.lock.withLock { FakeASR.whisperAudio.last == tailAudio + quietTail })
        check("awaited outcome and zero line wait logged", Log.recorded.contains { $0 == "ending check: in line 0ms outcome=4" })
        check("staged PCM never reported as checked result reuse", !Log.recorded.dropFirst(preparedLogStart).contains { $0.hasPrefix("ending tail: reused=1") })
        let preparedAudio = prepared.recorded
        prepared.silence(upTo: preparedAudio.count)
        check("foreground consumption seals later cleanup", prepared.recorded == preparedAudio)
        prepared.cancel()

        let resumed = Transcriber.Session(whisper: WhisperKit())
        let resumedStart = FakeASR.count
        check("tail staged before partial-frame resumption", try await staged(resumed))
        push([0.1] + [Float](repeating: 0, count: 16), to: resumed)
        FakeASR.text = "Checked new syllable."
        check("new speech starts no stale inference", FakeASR.count == resumedStart)
        check("resumed speech checked exactly once", try await resumed.finish() == "Checked new syllable." && FakeASR.count == resumedStart + 1)
        check("new syllable present in final engine input", FakeASR.lock.withLock { FakeASR.whisperAudio.last == tailAudio + [0.1] + [Float](repeating: 0, count: 16) })
        check("stale outcome and zero line wait logged", Log.recorded.contains { $0 == "ending check: in line 0ms outcome=2" })
        resumed.cancel()

        // Another accepted press creates its own Session. It must leave the finishing one intact.
        let finishing = Transcriber.Session(whisper: WhisperKit())
        check("tail staged before another session", try await staged(finishing))
        let anotherPress = Transcriber.Session(whisper: WhisperKit())
        push([0.2], to: anotherPress)
        anotherPress.cancel() // a disposable new tap, with no real keys
        let pressLog = Log.recorded.count
        let pressCount = FakeASR.count
        check("other press leaves ending check intact", try await finishing.finish() == "Checked new syllable." && FakeASR.count == pressCount + 1)
        check("other press preserves staged identity", Log.recorded.dropFirst(pressLog).contains { $0 == "ending check: in line 0ms outcome=4" })
        finishing.cancel()

        // Speculation cannot seal cleanup, even without a foreground draft having consumed audio.
        let cleaned = Transcriber.Session(whisper: WhisperKit())
        check("tail staged before confirmed cleanup", try await staged(cleaned))
        let cleanedStart = FakeASR.count
        cleaned.silence(upTo: 100)
        check("staged PCM does not seal confirmed cleanup", cleaned.recorded.prefix(100).allSatisfy { $0 == 0 } && cleaned.recorded[100] == tailAudio[100])
        check("cleanup generation starts no stale inference", FakeASR.count == cleanedStart)
        check("cleanup invalidation gets one foreground check", try await cleaned.finish() == "Checked new syllable." && FakeASR.count == cleanedStart + 1)
        check("engine consumes cleaned generation", FakeASR.lock.withLock { FakeASR.whisperAudio.last == cleaned.recorded })
        cleaned.cancel()

        let echoCleaned = Transcriber.Session(whisper: WhisperKit())
        check("tail staged before measured media result", try await staged(echoCleaned))
        var cleanedPCM = tailAudio
        for i in 0..<100 { cleanedPCM[i] = 0 }
        let echoCount = FakeASR.count
        let mediaResult = MediaAudio.Result(samples: cleanedPCM, certain: true, cleaned: true, match: 1,
                                            diagnostics: MediaAudio.Diagnostics())
        check("measured cleanup accepted after staging", echoCleaned.acceptMediaResult(mediaResult, replacing: tailAudio.count))
        check("measured cleanup replaced staged generation", echoCleaned.recorded == cleanedPCM)
        check("measured cleanup final check runs once", try await echoCleaned.finish() == "Checked new syllable." && FakeASR.count == echoCount + 1)
        check("measured cleanup checked byte for byte", FakeASR.lock.withLock { FakeASR.whisperAudio.last == cleanedPCM })
        check("measured cleanup sealed by foreground consumption", !echoCleaned.acceptMediaResult(mediaResult, replacing: tailAudio.count))
        echoCleaned.cancel()

        let escaped = Transcriber.Session(whisper: WhisperKit())
        check("tail staged before Escape", try await staged(escaped))
        let escapeCount = FakeASR.count
        escaped.cancel()
        do { _ = try await escaped.finish(); check("Escape cannot finish", false) }
        catch { check("Escape cannot publish or run fresh ASR", FakeASR.count == escapeCount && escaped.lastTail.isEmpty) }

        let discarding = Transcriber.Session(whisper: WhisperKit())
        check("tail staged before foreground discard", try await staged(discarding))
        let discardCount = FakeASR.count
        let discardingTask = Task { try await discarding.finish() }
        check("foreground engine running before Escape", try await until { FakeASR.count == discardCount + 1 })
        discarding.cancel(); discardingTask.cancel()
        do { _ = try await discardingTask.value; check("inflight Escape cannot finish", false) }
        catch { check("non-cooperative foreground cannot publish after Escape", discarding.lastTail.isEmpty) }
        check("discarded foreground was awaited without duplicate job", FakeASR.count == discardCount + 1)
        check("discarded foreground releases gate", try await Transcriber.gate.acquire() == 0)
        await Transcriber.gate.release()

        // A separate foreground request cannot queue behind staged tail work, even with a slow engine.
        let waitingTail = Transcriber.Session(whisper: WhisperKit())
        check("another session tail staged", try await staged(waitingTail))
        let foregroundLog = Log.recorded.count
        let foregroundCount = FakeASR.count
        let foreground = Transcriber.Session(whisper: WhisperKit())
        push(tailAudio, to: foreground)
        check("separate foreground completes", try await foreground.finish() == "Checked new syllable.")
        check("staged tail did not add an inference ahead of foreground", FakeASR.count == foregroundCount + 1)
        check("separate foreground has zero added gate wait", Log.recorded.dropFirst(foregroundLog).contains { $0 == "ending check: in line 0ms outcome=0" })
        foreground.cancel(); waitingTail.cancel()

        // A four-second ordinary draft check becomes due after a stage. No speculative job may precede it.
        let drafting = Transcriber.Session(whisper: WhisperKit())
        check("tail staged before ordinary draft check", try await staged(drafting))
        let draftChecks = FakeASR.count
        let checkLock = NSLock()
        var checkedRanges: [Range<Int>] = []
        drafting.onCheck = { range, _ in checkLock.withLock { checkedRanges.append(range) } }
        push(noise(993, 4 * Chunker.rate) + [Float](repeating: 0, count: 8000), to: drafting)
        drafting.streamDrafts()
        check("ordinary draft check completes after resumed speech", try await until { checkLock.withLock { !checkedRanges.isEmpty } })
        check("ordinary draft never queued behind a speculative inference", FakeASR.count == draftChecks + 1)
        check("ordinary check advances checked boundary", drafting.checkedUpTo > 0)
        drafting.cancel()
        // Wait for the existing normal loop to leave, without running real ASR.
        try await Transcriber.gate.acquire(); await Transcriber.gate.release()

        // Paired baseline and staged paths use the same slow cancellation-ignoring engine and PCM.
        for resumedSpeech in [false, true] {
            for repetition in 0..<3 {
                Transcriber.lastJob = 10 // no staging, otherwise the same draft-mode Session path
                let baseline = Transcriber.Session(whisper: WhisperKit())
                baseline.drafter = AsrManager(); push(tailAudio, to: baseline)
                baseline.stream(Chunker())
                if resumedSpeech { push([0.1], to: baseline) }
                let baseLog = Log.recorded.count, baseCalls = FakeASR.count
                let baseStart = ProcessInfo.processInfo.systemUptime
                let baseResult = try await baseline.finish()
                let baselineMS = Log.ms(ProcessInfo.processInfo.systemUptime - baseStart)
                check("baseline one slow check", FakeASR.count == baseCalls + 1)
                check("baseline zero line wait", Log.recorded.dropFirst(baseLog).contains { $0 == "ending check: in line 0ms outcome=0" })
                baseline.cancel()
                Transcriber.lastJob = 0
                let candidate = Transcriber.Session(whisper: WhisperKit())
                check("paired tail staged", try await staged(candidate))
                if resumedSpeech { push([0.1], to: candidate) }
                let candidateLog = Log.recorded.count, candidateCalls = FakeASR.count
                let candidateStart = ProcessInfo.processInfo.systemUptime
                let candidateResult = try await candidate.finish()
                let candidateMS = Log.ms(ProcessInfo.processInfo.systemUptime - candidateStart)
                check("paired output equals baseline", candidateResult == baseResult)
                check("paired final exactly one slow check", FakeASR.count == candidateCalls + 1)
                check("paired foreground queue wait no longer than baseline", Log.recorded.dropFirst(candidateLog).contains { $0.hasPrefix("ending check: in line 0ms outcome=") })
                // Allow scheduling jitter, not another 300 ms engine job. Queue-wait equality is exact above.
                check("paired finish has no extra slow engine duration", candidateMS <= baselineMS + 80)
                print("slow-engine control: resumed=\(resumedSpeech ? 1 : 0) run=\(repetition) baseline_ms=\(baselineMS) staged_ms=\(candidateMS) added_line_ms=0")
                candidate.cancel()
            }
        }
        let priorityGate = Transcriber.Gate()
        check("idle foreground gate wait is zero", try await priorityGate.acquire() == 0)
        let cancelledWaiter = Task {
            do { try await priorityGate.acquire(); await priorityGate.release(); return false }
            catch { return true }
        }
        cancelledWaiter.cancel()
        check("cancelled waiter leaves foreground queue", await cancelledWaiter.value)
        await priorityGate.release()
        check("cancelled waiter never strands gate", try await priorityGate.acquire() == 0)
        await priorityGate.release()
        FakeASR.ignoreCancellation = false
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
    pause_checks = (ROOT / "Sources/redpen-voice-test/BrowserPauseChecks.swift").read_text().replace("import VoiceCore", "")
    tests = tests.replace('        print("quick tap:', '        browserPauseChecks { name, ok, detail in check(name + detail, ok) }\n        print("quick tap:')
    source.write_text(pause_checks + "\n" + stubs.replace("__PRODUCTION_GATE__", gate) + session + "\n}\n" + recording + insert_stubs + replacement_adapter + "\n" + text_adapter + "\n}\n" + tests)
    core = ROOT / "Sources/VoiceCore"
    files = [core / name for name in ["BrowserMedia.swift", "BrowserPauseOperation.swift", "MediaPauseOwnership.swift", "MediaEcho.swift", "MediaAudio.swift", "MediaOpening.swift", "MediaGate.swift", "Chunker.swift",
                                    "Silence.swift", "FocusGate.swift", "CheckedTail.swift", "BoxText.swift", "EnterSend.swift", "LongTalk.swift", "BoxMatch.swift", "DictationEnding.swift", "TalkKeyState.swift", "DictationDelivery.swift", "TalkTimingTrace.swift", "TalkCapture.swift", "StartTargetWait.swift", "FastFinish.swift", "EditWait.swift", "SerialEdits.swift", "EditBoundary.swift", "DraftSafety.swift", "DraftInput.swift", "Names.swift", "Fillers.swift"]]
    subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-swift-version", "5", str(source),
                    *map(str, files), "-o", str(tmp / "check")], cwd=ROOT, check=True)
    subprocess.run([str(tmp / "check")], cwd=ROOT, check=True, env=os.environ)
