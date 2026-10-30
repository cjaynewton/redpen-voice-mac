// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "redpen-voice",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Whisper on this Mac (Core ML), for the downloadable engine.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
        // Sparkle, for one-click updates of the download, each checked against the maintainer's signing key.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
        // Parakeet (NVIDIA's fast English speech model) on this Mac through Core ML, for the Fast engine.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        // Logic with no window or microphone in it, so it can be checked from the command line.
        .target(name: "VoiceCore"),
        .executableTarget(name: "RedpenVoice", dependencies: ["VoiceCore", .product(name: "WhisperKit", package: "argmax-oss-swift"),
                                                            .product(name: "Sparkle", package: "Sparkle"),
                                                            .product(name: "FluidAudio", package: "FluidAudio")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "redpen-voice-test", dependencies: ["VoiceCore"]),
        .testTarget(name: "VoiceCoreTests", dependencies: ["VoiceCore"], path: "Tests", exclude: ["private"]),
    ]
)
