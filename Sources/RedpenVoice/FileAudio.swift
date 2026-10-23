import AVFoundation

/// Gets a file the engine can read. Plain audio files go straight in; a video, or audio the engine cannot open,
/// has its sound copied out to a temporary .m4a first.
enum FileAudio {
    static func readable(_ url: URL) async throws -> URL {
        if (try? AVAudioFile(forReading: url)) != nil { return url }
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw NSError(domain: "RedpenVoice", code: 10, userInfo: [NSLocalizedDescriptionKey: "No sound in that file"])
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("redpen-voice-\(UUID().uuidString).m4a")
        try await export.export(to: out, as: .m4a)
        return out
    }
}
