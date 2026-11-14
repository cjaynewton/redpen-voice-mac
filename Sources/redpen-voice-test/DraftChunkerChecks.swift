import Foundation
import VoiceCore

/// Synthetic audio only: a tone for speech, near silence for quiet. No engine, microphone or file.
func draftChunkerChecks(_ check: (String, Bool, String) -> Void) {
    let rate = Chunker.rate
    func c(_ name: String, _ ok: Bool, _ detail: String = "") { check("draftChunker." + name, ok, detail) }
    func n(_ seconds: Double) -> Int { Int(seconds * Double(rate)) }
    func tone(_ seconds: Double, _ amplitude: Float) -> [Float] {
        (0..<n(seconds)).map { amplitude * Float(sin(Double($0) * 2 * .pi * 220 / Double(rate))) }
    }
    func quiet(_ seconds: Double) -> [Float] { tone(seconds, 0.0005) }
    /// Words run together: 210 ms loud, then a 30 ms dip that is far too short and too loud to be a pause.
    func steady(_ seconds: Double) -> [Float] {
        var out: [Float] = []
        while out.count < n(seconds) { out += tone(0.21, 0.1) + tone(0.03, 0.02) }
        return Array(out.prefix(n(seconds)))
    }
    /// Feeds the audio a tenth of a second at a time, as the draft loop does, and returns each cut with the
    /// moment (in samples heard) it was made.
    func run(_ audio: [Float], chunker: DraftChunker = DraftChunker(), firstUntilSpeech: Bool = true) -> [(cut: DraftChunker.Cut, from: Int, heard: Int)] {
        var out: [(DraftChunker.Cut, Int, Int)] = [], from = 0, first = firstUntilSpeech
        var heard = 0
        while heard < audio.count {
            heard = min(audio.count, heard + rate / 10)
            if let cut = chunker.cut(Array(audio[0..<heard]), from: from, first: first) {
                out.append((cut, from, heard)); from = cut.end
                if cut.speech { first = false }
            }
        }
        return out
    }
    let old = Chunker(minSeconds: 0.8, maxSeconds: 6, pauseSeconds: 0.2)

    // Leading silence (the 0.6 s kept from before the press plus a double tap), then steady speech.
    let lead = 1.2
    let talk = quiet(lead) + steady(8)
    let cuts = run(talk)
    let firstCut = cuts.first
    let sinceSpeech = firstCut.map { Double($0.heard) / Double(rate) - lead } ?? 99
    c("firstPieceHoldsSpeech", firstCut?.cut.speech == true && (firstCut?.cut.end ?? 0) > n(lead + 0.5), "\(sinceSpeech)")
    c("firstCutWithinOneSecondOfSpeech", sinceSpeech >= 0.8 && sinceSpeech <= 1.0, "\(sinceSpeech)")
    c("firstPieceStartsAtZeroForTheMediaOpening", firstCut?.from == 0)
    c("noPieceWithoutSpeechIsSent", cuts.allSatisfy { !$0.cut.speech || DraftChunker.hasSpeech(talk, from: $0.from, to: $0.cut.end) }
        && cuts.allSatisfy { $0.cut.speech })
    // The forced cut sits in the dip between two words, not at an arbitrary sample.
    let dipAt = firstCut.map { ($0.cut.end - n(lead)) % n(0.24) } ?? 0
    c("forcedCutLandsInTheQuietestDip", firstCut?.cut.atPause == false && dipAt >= n(0.21) - 480 && dipAt <= n(0.24), "\(dipAt)")
    // The old rule on the same audio: a silent first piece, then nothing with words until six seconds in.
    var oldFrom = 0, oldFirstSpeech = 99.0, oldSilent = 0
    var heard = 0
    while heard < talk.count, oldFirstSpeech == 99 {
        heard = min(talk.count, heard + rate / 5)
        if let cut = old.cut(Array(talk[0..<heard]), from: oldFrom) {
            if DraftChunker.hasSpeech(talk, from: oldFrom, to: cut) { oldFirstSpeech = Double(heard) / Double(rate) - lead } else { oldSilent += 1 }
            oldFrom = cut
        }
    }
    c("oldRuleSentSilenceThenWaitedForSixSeconds", oldSilent >= 1 && oldFirstSpeech > 4, "\(oldSilent) \(oldFirstSpeech)")
    print("Draft chunker synthetic steady speech: first cut \(Int(sinceSpeech * 1000)) ms after speech starts, old rule \(Int(oldFirstSpeech * 1000)) ms")
    // Later pieces with no pause: nothing before about 3 s, then a cut in the later half.
    let later = cuts.dropFirst().first
    let laterLength = later.map { Double($0.heard - $0.from) / Double(rate) } ?? 0
    c("laterPieceCeilingIsThreeSeconds", laterLength >= 2.9 && laterLength <= 3.2 && later?.cut.atPause == false, "\(laterLength)")
    c("laterForcedCutIsInTheLaterHalf", later.map { $0.cut.end - $0.from >= n(1.5) } == true)
    c("steadySpeechKeepsComing", cuts.count >= 3)

    // Speech with real pauses: every cut sits inside a pause and is marked so. (A first phrase longer than
    // about 0.9 s is cut before its pause, by design: the first words do not wait.)
    let phrased = quiet(0.9) + steady(0.7) + quiet(0.5) + steady(1.4) + quiet(0.6) + steady(1.0) + quiet(0.5)
    let phrasedCuts = run(phrased)
    func inPause(_ sample: Int) -> Bool {
        let t = Double(sample) / Double(rate)
        return (t >= 1.6 && t <= 2.1) || (t >= 3.5 && t <= 4.1) || t >= 5.1
    }
    c("pausesAreUsedWhenTheyExist", phrasedCuts.count == 3 && phrasedCuts.allSatisfy { $0.cut.atPause && $0.cut.speech && inPause($0.cut.end) },
      phrasedCuts.map { "\($0.cut.end)" }.joined(separator: ","))
    c("firstWordsAtTheFirstPause", phrasedCuts.first.map { Double($0.heard) / Double(rate) <= 2.0 } == true)

    // All silence: nothing is ever sent. Long silence is stepped over in pieces marked as holding no speech.
    let silent = run(quiet(7))
    c("silenceIsNeverSent", !silent.isEmpty && silent.allSatisfy { !$0.cut.speech && $0.cut.atPause })
    c("silenceSteppedOverOnlyAfterTwoSeconds", silent.first.map { $0.heard >= n(2.0) && $0.heard <= n(2.1) } == true)
    c("stepKeepsALeadIn", silent.first.map { $0.heard - $0.cut.end == 10 * 480 } == true)
    c("shortSilenceWaits", DraftChunker().cut(quiet(1.9), from: 0, first: true) == nil)

    // A talk-key click, then a second tap, then speech a second in: the clicks are not the start of speech.
    var tapped = quiet(3.2)
    for start in [n(0.2), n(0.45)] { for i in start..<(start + 480) { tapped[i] = 0.3 * (i % 2 == 0 ? 1 : -1) } }
    tapped.replaceSubrange(n(1.0)..<n(3.2), with: steady(2.2))
    let levels = Chunker.levels(tapped, from: 0)
    c("clickIsNotSpeech", DraftChunker.speechOnset(levels, quiet: Chunker.quietLevel(levels)).map { abs($0 * 480 - n(1.0)) <= 480 } == true)
    let tappedCuts = run(tapped)
    let tappedSince = tappedCuts.first.map { Double($0.heard) / Double(rate) - 1.0 } ?? 99
    c("clickDoesNotStartTheCount", tappedSince >= 0.8 && tappedSince <= 1.0 && tappedCuts.first?.cut.speech == true, "\(tappedSince)")
    var clicksOnly = quiet(1.5)
    for start in [n(0.2), n(0.45)] { for i in start..<(start + 480) { clicksOnly[i] = 0.3 * (i % 2 == 0 ? 1 : -1) } }
    c("clicksAloneAreNotSent", DraftChunker().cut(clicksOnly, from: 0, first: true) == nil && !DraftChunker.hasSpeech(clicksOnly, from: 0, to: clicksOnly.count))

    // Whisper's checks end only where a draft ended in a real pause, so the final text is never joined in a word.
    let r = rate
    let forced: [(end: Int, atPause: Bool)] = [(1 * r, false), (3 * r, false), (5 * r, false), (6 * r, true), (7 * r, false)]
    let seam = DraftChunker.checkCut(forced, checkedUpTo: 0, from: 0)
    c("checkEndsOnlyAtAPause", seam?.end == 6 * r && seam?.upTo == 4)
    c("noCheckWhileOnlyForcedCuts", DraftChunker.checkCut(Array(forced.prefix(3)), checkedUpTo: 0, from: 0) == nil)
    let allPauses: [(end: Int, atPause: Bool)] = [(1 * r, true), (3 * r, true), (5 * r, true)]
    let asBefore = DraftChunker.checkCut(allPauses, checkedUpTo: 0, from: 0)
    c("pauseDraftsCheckAsBefore", asBefore?.end == 5 * r && asBefore?.upTo == 3 && DraftChunker.checkCut(allPauses, checkedUpTo: 3, from: 5 * r) == nil)
    let long: [(end: Int, atPause: Bool)] = [(2 * r, true), (20 * r, false), (26 * r, false)]
    let limit = DraftChunker.checkCut(long, checkedUpTo: 0, from: 0)
    c("pastTheLimitUsesTheNewestPause", limit?.end == 2 * r && limit?.upTo == 1)
    let noPause: [(end: Int, atPause: Bool)] = [(20 * r, false), (26 * r, false)]
    let fallback = DraftChunker.checkCut(noPause, checkedUpTo: 0, from: 0)
    c("pastTheLimitWithNoPauseFallsBackAsBefore", fallback?.end == 20 * r && fallback?.upTo == 1)

    // The first cut still starts at 0 for the media opening, which can move it later (MediaOpening.cut).
    var opening = MediaOpening(); opening.include(through: n(2.6))
    let proposed = firstCut?.cut.end ?? 0
    c("mediaOpeningStillMovesTheFirstCut", opening.cut(proposed, from: 0, available: n(3)) == n(2.6) && opening.cut(proposed, from: 0, available: n(2.5)) == nil
        && opening.cut(proposed, from: 1, available: n(2.5)) == proposed)
    // Whisper and meetings keep their chunker untouched.
    let defaults = Chunker()
    c("whisperAndMeetingDefaultsUnchanged", defaults.minSeconds == 4 && defaults.maxSeconds == 25 && defaults.pauseSeconds == 0.5)
}
