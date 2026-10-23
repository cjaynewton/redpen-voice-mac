// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "redpen-voice",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Whisper on this Mac (Core ML), for the downloadable engine.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
    ],
    targets: [
        // Logic with no window or microphone in it, so it can be checked from the command line.
        .target(name: "VoiceCore"),
        .executableTarget(name: "RedpenVoice", dependencies: ["VoiceCore", .product(name: "WhisperKit", package: "argmax-oss-swift")]),
        .executableTarget(name: "redpen-voice-test", dependencies: ["VoiceCore"]),
    ]
)
