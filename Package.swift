// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Pretype",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        // 3.32: Gemma 4 MTP drafters (speculative fix/reply decoding), and
        // loads the 2026-07-06 -it re-conversions. mlx-swift 0.32.3,
        // not 0.32.2 (launch crash before macOS 26.4); both need swift-tools 6.3.
        // Pinned to main past 3.32.3 for the Qwen3.5 fixes the 8 GB default
        // needs (#633 gated-delta L2-norm eps, #631 reload leak, #614 prefill
        // vocab projection) — back to `.upToNextMinor(from: "3.33.0")` once tagged.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", revision: "7eb77efa4e8fb56183b905904d122e66ebdb422e"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.32.3")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        // Parakeet TDT v3 (CoreML) for opt-in dictation of the languages Apple's
        // SpeechTranscriber skips — see Dictation/Parakeet.swift.
        .package(url: "https://github.com/FluidInference/FluidAudio", .upToNextMinor(from: "0.17.7")),
    ],
    targets: [
        .executableTarget(
            name: "Pretype",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Pretype"
        ),
        .testTarget(
            name: "PretypeTests",
            dependencies: ["Pretype"],
            path: "Tests/PretypeTests"
        )
    ]
)
