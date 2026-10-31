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
        // Better summary on this Mac (D-1010): Apple's MLX and its language models, to run a downloaded writer (Qwen3.6
        // or Gemma 4) inside the app. MLX's GPU code is built with Xcode's Metal Toolchain.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        // Hugging Face's tokenizers, which turn the writer's words into its numbers and back.
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.5"),
    ],
    targets: [
        // Logic with no window or microphone in it, so it can be checked from the command line.
        .target(name: "VoiceCore"),
        .executableTarget(name: "RedpenVoice", dependencies: ["VoiceCore", .product(name: "WhisperKit", package: "argmax-oss-swift"),
                                                            .product(name: "Sparkle", package: "Sparkle"),
                                                            .product(name: "FluidAudio", package: "FluidAudio"),
                                                            .product(name: "MLX", package: "mlx-swift"),
                                                            .product(name: "MLXLLM", package: "mlx-swift-lm"),
                                                            .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                                                            .product(name: "Tokenizers", package: "swift-transformers")],
                          linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .executableTarget(name: "redpen-voice-test", dependencies: ["VoiceCore"]),
        .testTarget(name: "VoiceCoreTests", dependencies: ["VoiceCore"], path: "Tests", exclude: ["private"]),
    ]
)
