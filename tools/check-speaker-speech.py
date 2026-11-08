#!/usr/bin/env python3
"""Offline spoken-audio check. macOS say writes synthetic WAVs, never plays them.
No mic, ASR model, installed app or network service is used. All scratch files stay in .build.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = r'''
import Foundation
import AVFoundation
@main struct Check {
    static var checks = 0
    static func check(_ name: String, _ ok: Bool) {
        if !ok { print("FAIL \(name)"); fflush(stdout); exit(1) }; checks += 1
    }
    static func load(_ path: String) throws -> [Float] {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let audio = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: audio)
        return Array(UnsafeBufferPointer(start: audio.floatChannelData![0], count: Int(audio.frameLength)))
    }
    static func main() throws {
        let video = try load(CommandLine.arguments[1]), user = try load(CommandLine.arguments[2])
        let key = 9600, gap = 640, end = min(video.count, key + gap + 16000)
        let reference = Array(video[key + gap..<end])
        var expected = [Float](repeating: 0, count: key + user.count + 8000)
        for i in user.indices { expected[key + i] = user[i] }
        let headphones = MediaAudio.removing(mic: expected, played: reference, preRoll: key)
        check("spoken headphones type automatically", headphones.certain)
        check("spoken headphones unchanged", headphones.samples == expected)
        // Preserve existing confirmed cleanup even with pre-roll in the newly tolerated room-noise range.
        func noise(_ seed: UInt64, _ count: Int) -> [Float] {
            var state = seed
            return (0..<count).map { _ in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max) * 0.1
            }
        }
        let played = noise(12, 16000), near = noise(92, 48000)
        for floor: Float in [0.0032, 0.0071] {
            var tested = false
            for gain: Float in [0.15, 0.18, 0.20, 0.25] {
                var mic = near
                for i in 0..<key { mic[i] = i.isMultiple(of: 2) ? floor : -floor }
                for i in played.indices { mic[key + i] += played[i] * gain }
                let old = PreviousMediaAudio.removing(mic: mic, played: played, preRoll: key)
                if old.certain, old.match >= 0.14, old.match < 0.30, old.diagnostics.gain != nil {
                    let current = MediaAudio.removing(mic: mic, played: played, preRoll: key)
                    check("confirmed low-level cleanup unchanged at \(floor)", current.certain && current.samples == old.samples)
                    tested = true; break
                }
            }
            check("confirmed low-level control found at \(floor)", tested)
        }
        var mic = expected
        for (delay, gain): (Int, Float) in [(0, 0.8), (320, 0.45), (880, 0.25)] {
            for i in 0..<end { mic[i + delay] += gain * video[i] }
        }
        let before = LegacyMediaAudio.removing(mic: mic, played: reference, preRoll: key)
        check("installed helper reproduces speaker abstention", !before.certain)
        let result = MediaAudio.removing(mic: mic, played: reference, preRoll: key)
        print("spoken room: \(result.diagnostics.logLine)")
        check("spoken room types automatically", result.certain)
        check("spoken startup gap measured", result.diagnostics.gapSamples == gap)
        check("spoken loss is measured and bounded", result.diagnostics.lostUserSamples >= gap && result.diagnostics.lostUserSamples <= 3840)
        check("spoken video pre-roll removed", result.samples.prefix(key + gap).allSatisfy { $0 == 0 })
        var error: Float = 0, energy: Float = 0
        for i in key + gap..<mic.count where !result.diagnostics.cuts.contains(where: { $0.contains(i) }) {
            error += (result.samples[i] - expected[i]) * (result.samples[i] - expected[i])
            energy += expected[i] * expected[i]
        }
        // Same synthetic voice in both tracks is a demanding double-talk control, not ASR word accuracy.
        check("spoken user signal retained", error / max(energy, 0.000001) < 0.15)
        for range in result.diagnostics.cuts { check("spoken cut stays blank", result.samples[range].allSatisfy { $0 == 0 }) }
        print("spoken retained-signal error/user energy \(error / max(energy, 0.000001)); \(checks) speech checks passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="speaker-speech-", dir=root / ".build") as directory:
    directory = Path(directory)
    for name, words in [("video", "Please tell me what happened in the garden this morning."),
                        ("user", "My first words should appear, and the video should stay out of this message.")]:
        subprocess.run(["/usr/bin/say", "-v", "Samantha", "--file-format=WAVE", "--data-format=LEI16@16000",
                        "-o", str(directory / f"{name}.wav"), words], check=True)
    legacy = subprocess.check_output(["git", "show", "bef88a6:Sources/VoiceCore/MediaAudio.swift"], cwd=root, text=True)
    (directory / "Legacy.swift").write_text(legacy.replace("public enum MediaAudio", "public enum LegacyMediaAudio", 1))
    previous = subprocess.check_output(["git", "show", "39b95e5:Sources/VoiceCore/MediaAudio.swift"], cwd=root, text=True)
    (directory / "Previous.swift").write_text(previous.replace("public enum MediaAudio", "public enum PreviousMediaAudio", 1))
    (directory / "Check.swift").write_text(source)
    subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", str(directory / "Check.swift"),
                    str(directory / "Legacy.swift"), str(directory / "Previous.swift"), str(root / "Sources/VoiceCore/MediaAudio.swift"),
                    "-o", str(directory / "check")], check=True, env=os.environ)
    subprocess.run([str(directory / "check"), str(directory / "video.wav"), str(directory / "user.wav")], check=True)
