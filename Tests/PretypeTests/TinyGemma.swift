import Foundation
import HuggingFace
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
@testable import Pretype

/// A tiny Gemma 4 for the engine tests, built through the same type
/// registry as the app's own loads and saved the way a real checkpoint is,
/// so the load paths run for real on the CPU in a fraction of a second.
enum TinyGemma {
    /// Its config.json. `wrapper`: the `gemma4` type, whose checkpoints name
    /// every key `model.language_model.…` and whose sanitize renames them;
    /// `tableRows`: the per-layer table's vocabulary.
    static func config(bits: Int = 4, wrapper: Bool = false, tableRows: Int = 64) -> String {
        """
        {"model_type": "\(wrapper ? "gemma4" : "gemma4_text")", "hidden_size": 64, "num_hidden_layers": 2,
         "intermediate_size": 64, "num_attention_heads": 2, "head_dim": 32, "global_head_dim": 32,
         "vocab_size": 64, "vocab_size_per_layer_input": \(tableRows), "num_key_value_heads": 1,
         "num_kv_shared_layers": 0, "hidden_size_per_layer_input": 32, "sliding_window": 8,
         "sliding_window_pattern": 2, "use_double_wide_mlp": false,
         "quantization": {"group_size": 32, "bits": \(bits)}}
        """
    }

    /// A fresh, unloaded model for `config`, from the LLM type registry.
    static func model(_ config: String, seed: UInt64) async throws -> any LanguageModel {
        let data = Data(config.utf8)
        let base = try JSONDecoder.json5().decode(BaseConfiguration.self, from: data)
        return try await withRandomState(MLXRandom.RandomState(seed: seed)) {
            try await LLMModelFactory.shared.typeRegistry.createModel(configuration: data, modelType: base.modelType)
        }
    }

    /// Writes a quantized tiny Gemma into `directory` as a snapshot holds
    /// one: config.json, a tokenizer file for the snapshot check, and its
    /// weights — in `shards` files behind an index when more than one, the
    /// table in the last.
    /// `config`: another model's config.json in place of the tiny Gemma's.
    static func write(to directory: URL, bits: Int = 4, shards: Int = 1, wrapper: Bool = false,
                      tableRows: Int = 64, seed: UInt64 = 7, config other: String? = nil) async throws {
        let config = other ?? config(bits: bits, wrapper: wrapper, tableRows: tableRows)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(config.utf8).write(to: directory.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("tokenizer.json"))
        let source = try await model(config, seed: seed)
        quantize(model: source, groupSize: 32, bits: bits)
        eval(source)
        // A checkpoint's names: the wrapper's sanitize maps them back.
        let parameters = Dictionary(uniqueKeysWithValues: source.parameters().flattened().map { key, value in
            (wrapper ? "model." + key.replacingOccurrences(of: "language_model.model.", with: "language_model.") : key, value)
        })
        let keys = parameters.keys.filter { !$0.contains("embed_tokens_per_layer.") }.sorted()
            + parameters.keys.filter { $0.contains("embed_tokens_per_layer.") }.sorted()
        var weightMap: [String: String] = [:]
        for shard in 0 ..< shards {
            let name = shards == 1 ? "model.safetensors" : "model-0000\(shard + 1)-of-0000\(shards).safetensors"
            let mine = keys.enumerated().filter { $0.offset * shards / keys.count == shard }.map { $0.element }
            for key in mine { weightMap[key] = name }
            try save(arrays: parameters.filter { mine.contains($0.key) }, url: directory.appendingPathComponent(name))
        }
        if shards > 1 {
            try JSONSerialization.data(withJSONObject: ["weight_map": weightMap])
                .write(to: directory.appendingPathComponent("model.safetensors.index.json"))
        }
    }

    /// The module at the per-layer table's path.
    static func table(_ model: Module) -> Module? {
        model.leafModules().flattened().first { $0.0.hasSuffix("embed_tokens_per_layer") }?.1
    }

    /// Logits for a fixed prompt.
    static func logits(_ model: any LanguageModel) -> MLXArray {
        let tokens = MLXArray([3, 17, 42, 9, 63, 0, 28].map(Int32.init)).reshaped([1, 7])
        return model(LMInput.Text(tokens: tokens), cache: nil, state: nil).logits
    }

    /// The per-layer policy a test pins: on, any volume.
    static let serving = HostPLE.Policy(enabled: true) { _ in true }

    /// A scratch folder, removed with `body`'s test.
    static func scratch(_ name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pretype-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

/// An unquantized tiny Gemma in a container, with a tokenizer whose ids
/// stay inside its vocabulary — enough for a residency's load and warm-up,
/// and for the decode loop. `eos`: the ids the configuration ends a turn on;
/// `tokenizerEOS`: the tokenizer's own EOS token, as an id; `window`: the
/// sliding layers' span — a prompt past it wraps their ring, which then
/// can't be trimmed back, and a decode reuses a checkpoint instead;
/// `chats`: where the tokenizer records each chat it renders; `recurrent`:
/// one more layer that can't rewind, as Qwen3.5's recurrent ones can't.
func tinyContainer(eos: Set<Int> = [], tokenizerEOS: Int? = nil, window: Int = 8,
                   chats: LockedValue<[String]>? = nil, recurrent: Bool = false) throws -> ModelContainer {
    let config = #"{"hidden_size": 32, "num_hidden_layers": 2, "intermediate_size": 32, "num_attention_heads": 2, "head_dim": 16, "global_head_dim": 16, "vocab_size": 64, "vocab_size_per_layer_input": 64, "num_key_value_heads": 1, "num_kv_shared_layers": 0, "hidden_size_per_layer_input": 16, "sliding_window": WINDOW, "sliding_window_pattern": 2, "use_double_wide_mlp": false}"#
        .replacingOccurrences(of: "WINDOW", with: "\(window)")
    let configuration = try JSONDecoder.json5().decode(Gemma4TextConfiguration.self, from: Data(config.utf8))
    let model = withRandomState(MLXRandom.RandomState(seed: 3)) { Gemma4TextModel(configuration) }
    return ModelContainer(context: ModelContext(
        configuration: ModelConfiguration(directory: FileManager.default.temporaryDirectory, eosTokenIds: eos),
        model: recurrent ? WithRecurrentLayer(model) : model, processor: NoInputProcessor(),
        tokenizer: CharTokenizer(eos: tokenizerEOS, chats: chats)))
}

/// A model's caches plus one that can't be trimmed back — a stand-in for a
/// recurrent layer, which only a checkpoint can bring back.
private final class WithRecurrentLayer: Module, LLMModel {
    @ModuleInfo var inner: Gemma4TextModel

    init(_ inner: Gemma4TextModel) {
        _inner.wrappedValue = inner
        super.init()
    }

    func callAsFunction(_ inputs: MLXArray, cache: [KVCache]?) -> MLXArray {
        inner(inputs, cache: cache.map { Array($0.dropLast()) })
    }

    func newCache(parameters: GenerateParameters?) throws -> [any KVCache] {
        try inner.newCache(parameters: parameters) + [MambaCache()]
    }

    var loraLayers: [Module] { [] }
}

struct NoInputProcessor: UserInputProcessor {
    func prepare(input: UserInput) async throws -> LMInput { throw CancellationError() }
}

/// One id per character, folded into a 64-token vocabulary; decoding spells
/// each id as one letter, digit, `-` or `_` — never a space or a newline, so
/// no text-based stop cuts a decode short.
struct CharTokenizer: MLXLMCommon.Tokenizer {
    static let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
    /// Its own EOS token, as an id; none by default.
    var eos: Int?
    /// Given, each chat renders as its messages' text, recorded here; else
    /// as no tokens.
    var chats: LockedValue<[String]>?
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { text.unicodeScalars.map { Int($0.value % 64) } }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { String(tokenIds.map { Self.alphabet[$0 % 64] }) }
    func convertTokenToId(_ token: String) -> Int? { token.count == 1 ? token.first.flatMap(Self.alphabet.firstIndex(of:)) : nil }
    func convertIdToToken(_ id: Int) -> String? { String(Self.alphabet[id % 64]) }
    var bosToken: String? { nil }
    var eosToken: String? { eos.map { String(Self.alphabet[$0 % 64]) } }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        guard let chats else { return [] }
        let text = messages.compactMap { $0["content"] as? String }.joined(separator: "\n")
        chats.mutate { $0.append(text) }
        return encode(text: text, addSpecialTokens: false)
    }
}

/// Runs `body` against an empty scratch Hugging Face cache, so no test
/// reads or writes the user's own.
func withScratchHub<R>(_ body: () throws -> R) throws -> R {
    let root = try TinyGemma.scratch("hub")
    defer { try? FileManager.default.removeItem(at: root) }
    return try ModelStorage.$hub.withValue(HubCache(cacheDirectory: root), operation: body)
}

func withScratchHub<R>(_ body: () async throws -> R) async throws -> R {
    let root = try TinyGemma.scratch("hub")
    defer { try? FileManager.default.removeItem(at: root) }
    return try await ModelStorage.$hub.withValue(HubCache(cacheDirectory: root), operation: body)
}
