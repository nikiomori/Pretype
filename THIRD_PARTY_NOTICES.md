# Third-Party Notices

Pretype is MIT-licensed (see [LICENSE](LICENSE)), but the released `Pretype.app` statically
bundles the Swift packages below, and at runtime the app downloads model weights that carry
their own licenses. This file lists both.

## Bundled libraries

| Package | License | Source |
| :--- | :--- | :--- |
| mlx-swift | MIT | <https://github.com/ml-explore/mlx-swift> |
| mlx-swift-lm | MIT | <https://github.com/ml-explore/mlx-swift-lm> |
| swift-transformers | Apache-2.0 | <https://github.com/huggingface/swift-transformers> |
| swift-huggingface | Apache-2.0 | <https://github.com/huggingface/swift-huggingface> |
| swift-jinja | MIT | <https://github.com/huggingface/swift-jinja> |
| swift-nio | Apache-2.0 | <https://github.com/apple/swift-nio> |
| swift-collections | Apache-2.0 | <https://github.com/apple/swift-collections> |
| swift-atomics | Apache-2.0 | <https://github.com/apple/swift-atomics> |
| swift-crypto | Apache-2.0 | <https://github.com/apple/swift-crypto> |
| swift-asn1 | Apache-2.0 | <https://github.com/apple/swift-asn1> |
| swift-numerics | Apache-2.0 | <https://github.com/apple/swift-numerics> |
| swift-syntax | Apache-2.0 (with Runtime Library Exception) | <https://github.com/swiftlang/swift-syntax> |
| swift-system | Apache-2.0 | <https://github.com/apple/swift-system> |
| EventSource | MIT | <https://github.com/mattt/EventSource> |
| yyjson | MIT | <https://github.com/ibireme/yyjson> |

Each package's full license text ships with its source at the link above (Apache-2.0
packages: `LICENSE.txt`, plus `NOTICE.txt` where present). The exact pinned versions are
recorded in [Package.resolved](Package.resolved).

## Model weights (downloaded at runtime, not distributed with the app)

Pretype never ships model weights; it downloads the model you select from Hugging Face on
first use. Those weights are licensed by their publishers, not by Pretype's MIT license:

| Model family | Publisher | License |
| :--- | :--- | :--- |
| Gemma 4 (all variants) | Google | [Gemma Terms of Use](https://ai.google.dev/gemma/terms) — includes use restrictions |
| MiniCPM5 | OpenBMB | See the [model card](https://huggingface.co/openbmb) |
| Qwen 2.5 / 3.5 | Alibaba (Qwen) | Apache-2.0 — see the [model card](https://huggingface.co/Qwen) |
| Ternary Bonsai | prism-ml | See the [model card](https://huggingface.co/prism-ml) |

By downloading a model through Pretype you accept its publisher's terms. Check the model
card on Hugging Face for the authoritative, current license of any specific repository.
