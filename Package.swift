// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Pretype",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        // 3.31.4: loads the 2026-07-06 re-conversions of the Gemma 4 -it models
        // (quantized per_layer_model_projection), which 3.31.3 rejects. Minor-pinned,
        // with mlx-swift held at 0.31.4: 0.31.5+ needs swift-tools 6.3, beyond the
        // CI toolchain, and the 3.32 line measured no faster on this workload.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMinor(from: "3.31.4")),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.4"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "Pretype",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
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
