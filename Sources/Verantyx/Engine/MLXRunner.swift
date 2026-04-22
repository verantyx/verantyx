import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Hub

// MARK: - MLXRunner (Direct In-Process Inference)
//
// Loads the MLX model directly into the app process via MLXLMCommon.ModelContainer.
// No subprocess, no HTTP server, no port conflicts.
//
// generate() callback API:
//   ([Int]) -> GenerateDisposition  (.more | .stop)
//   Tokenizer.decode(tokens: [Int]) -> String  for piece decoding

// MARK: - MLX Popular Models

struct MLXModel: Identifiable, Hashable {
    let id: String
    let displayName: String
    let sizeGB: Double
    let tags: [String]

    var isDownloaded: Bool {
        let home  = FileManager.default.homeDirectoryForCurrentUser
        let cache = home.appendingPathComponent(".cache/huggingface/hub")
        let name  = "models--" + id.replacingOccurrences(of: "/", with: "--")
        return FileManager.default.fileExists(atPath: cache.appendingPathComponent(name).path)
    }
}

// MARK: - MLXRunner Actor

actor MLXRunner {

    static let shared = MLXRunner()

    static let cacheDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
    }()

    static let popularModels: [MLXModel] = [
        MLXModel(id: "mlx-community/gemma-4-26b-a4b-it-4bit",
                 displayName: "Gemma 4 26B (4bit) ⭐ 最新・最高性能",
                 sizeGB: 17.0, tags: ["thinking", "latest", "recommended"]),
        MLXModel(id: "mlx-community/gemma-3-27b-it-4bit",
                 displayName: "Gemma 3 27B (4bit) — 安定版",
                 sizeGB: 18.0, tags: ["thinking", "stable"]),
        MLXModel(id: "mlx-community/gemma-3-12b-it-4bit",
                 displayName: "Gemma 3 12B (4bit) — 軽量版",
                 sizeGB: 8.0, tags: ["fast"]),
        MLXModel(id: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
                 displayName: "Qwen 2.5 Coder 7B — コード特化",
                 sizeGB: 4.5, tags: ["code", "fast"]),
        MLXModel(id: "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit",
                 displayName: "Qwen 2.5 Coder 32B — 最高精度",
                 sizeGB: 20.0, tags: ["code", "large"]),
        MLXModel(id: "mlx-community/Mistral-7B-Instruct-v0.3-4bit",
                 displayName: "Mistral 7B Instruct",
                 sizeGB: 4.0, tags: ["fast", "general"]),
        MLXModel(id: "mlx-community/phi-4-4bit",
                 displayName: "Phi-4 (4bit) — Microsoft",
                 sizeGB: 8.5, tags: ["reasoning"]),
    ]

    // MARK: - Private state

    private var container: ModelContainer? = nil
    private(set) var currentModelId: String? = nil
    private(set) var isLoaded: Bool = false

    // MARK: - Load model

    func loadModel(
        id modelId: String,
        hfToken: String? = nil,
        progressHandler: @escaping @Sendable (String) -> Void
    ) async throws {
        if currentModelId == modelId, isLoaded {
            await MainActor.run { progressHandler("✓ \(modelId) already loaded") }
            return
        }
        container = nil; isLoaded = false; currentModelId = nil
        await MainActor.run { progressHandler("⟳ Loading \(modelId) into Unified Memory…") }

        // ── Auto-patch config.json if needed ─────────────────────────────────
        // Gemma-4 and newer models use a mixed quantization format where the
        // "quantization" dict contains BOTH top-level keys (group_size, bits, mode)
        // AND per-layer keys (e.g. "language_model.model.layers.0.mlp.gate_proj": {...}).
        // MLXLMCommon ≤ 2.21 cannot decode this mixed structure → Type mismatch error.
        // We patch the JSON in-place before loading (idempotent).
        patchQuantizationConfig(modelId: modelId, log: progressHandler)

        var hub = defaultHubApi
        if let token = hfToken { hub = HubApi(hfToken: token) }

        let config = ModelConfiguration(id: modelId)
        let loaded = try await LLMModelFactory.shared.loadContainer(
            hub: hub, configuration: config
        ) { progress in
            let pct = Int(progress.fractionCompleted * 100)
            Task { @MainActor in progressHandler("↓ Downloading… \(pct)%") }
        }

        container = loaded; currentModelId = modelId; isLoaded = true
        await MainActor.run { progressHandler("✅ \(modelId) loaded — ready") }
    }

    // MARK: - Config.json quantization patcher

    /// Fixes models (e.g. Gemma-4, gemma-3-27b-it-4bit) whose config.json mixes
    /// top-level quant fields with per-layer entries inside the same "quantization" key.
    ///
    /// Gemma-4 mixed format (causes "Type mismatch at 'quantization.mode'"):
    ///   "quantization": {
    ///     "group_size": 64,
    ///     "bits": 4,
    ///     "mode": "flex",             ← string (fine)
    ///     "language_model.layers.0.mlp.gate_proj": {"group_size":64,"bits":4}  ← dict ← BREAKS
    ///   }
    ///
    /// Fix: move all dict-valued keys → "quantization_per_layer" (ignored by MLXLMCommon).
    /// Also handles "mode" being a nested dict (alternate Gemma-4 format).
    /// Searches ALL config.json files under the model snapshot directory (recursive).
    /// Idempotent: skips if quantization_per_layer already exists.
    private func patchQuantizationConfig(modelId: String, log: @Sendable (String) -> Void) {
        let cacheRoot = MLXRunner.cacheDir
        let dirName   = "models--" + modelId.replacingOccurrences(of: "/", with: "--")
        let modelDir  = cacheRoot.appendingPathComponent(dirName)

        // ── Find all config.json files under the model dir (snapshots/blobs) ──
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelDir.path) else {
            log("⚠️ Model cache dir not found: \(modelDir.path)")
            return
        }

        var configPaths: [URL] = []
        if let enumerator = fm.enumerator(at: modelDir,
                                           includingPropertiesForKeys: [.isRegularFileKey],
                                           options: [.skipsHiddenFiles]) {
            for case let file as URL in enumerator {
                if file.lastPathComponent == "config.json" {
                    configPaths.append(file)
                }
            }
        }

        if configPaths.isEmpty {
            log("⚠️ No config.json found under \(modelDir.lastPathComponent)")
            return
        }

        for configPath in configPaths {
            patchSingleConfig(at: configPath, log: log)
        }
    }

    /// Patch a single config.json file in-place (idempotent).
    private func patchSingleConfig(at configPath: URL, log: @Sendable (String) -> Void) {
        guard let data = try? Data(contentsOf: configPath),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        // Already patched?
        if json["quantization_per_layer"] != nil { return }

        // ── Case 1: "quantization" is a dict with mixed top-level + per-layer keys ──
        if var quant = json["quantization"] as? [String: Any] {
            var topLevel:  [String: Any] = [:]
            var perLayer:  [String: Any] = [:]

            for (k, v) in quant {
                if v is [String: Any] {
                    // Any nested dict → move to per_layer
                    // This covers both actual layer entries AND "mode": {"key": ...}
                    perLayer[k] = v
                } else {
                    topLevel[k] = v
                }
            }

            guard !perLayer.isEmpty else { return }  // nothing to fix

            json["quantization"]           = topLevel
            json["quantization_per_layer"] = perLayer

            if let patched = try? JSONSerialization.data(withJSONObject: json,
                                                          options: [.prettyPrinted, .sortedKeys]) {
                do {
                    try patched.write(to: configPath)
                    log("🔧 Patched config.json: moved \(perLayer.count) keys → quantization_per_layer (\(configPath.deletingLastPathComponent().lastPathComponent))")
                } catch {
                    log("❌ Failed to write patched config.json: \(error.localizedDescription)")
                }
            }
            return
        }

        // ── Case 2: "quantization" is an Array (some newer MLX models) ──────────
        // e.g. "quantization": [{"key": "layer.0", "bits": 4, "group_size": 64}, ...]
        // MLXLMCommon 2.21+ can handle array format, so we just leave it.
        // If it fails anyway, convert to per_layer dict keyed by "key" field.
        if let quantArray = json["quantization"] as? [[String: Any]] {
            var perLayer: [String: Any] = [:]
            for entry in quantArray {
                if let key = entry["key"] as? String {
                    var layerEntry = entry
                    layerEntry.removeValue(forKey: "key")
                    perLayer[key] = layerEntry
                }
            }
            guard !perLayer.isEmpty else { return }
            json["quantization"]           = [String: Any]()  // empty top-level
            json["quantization_per_layer"] = perLayer
            if let patched = try? JSONSerialization.data(withJSONObject: json,
                                                          options: [.prettyPrinted, .sortedKeys]) {
                try? patched.write(to: configPath)
                log("🔧 Patched config.json (array→dict): \(perLayer.count) layers migrated")
            }
        }
    }

    // MARK: - Token-by-token streaming

    func streamGenerateTokens(
        prompt: String,
        maxTokens: Int = 4096,
        temperature: Double = 0.1,
        onToken: @escaping @Sendable (String) -> Void,
        onFinish: @escaping @Sendable (String) -> Void
    ) async throws {
        guard let box = container else { throw MLXError.notLoaded }

        let params    = GenerateParameters(temperature: Float(temperature))
        let userInput = UserInput(prompt: prompt)

        try await box.perform { (context: ModelContext) in
            // Prepare token IDs from the chat template / raw prompt
            let lmInput: LMInput
            do {
                lmInput = try await context.processor.prepare(input: userInput)
            } catch {
                // If no chat template, fall back to raw token encoding
                let ids = context.tokenizer.encode(text: prompt)
                lmInput = LMInput(tokens: .init(ids.map { Int32($0) }))
            }

            var allTokens: [Int] = []
            var partialBuffer: [Int] = []

            let result = try MLXLMCommon.generate(
                input: lmInput, parameters: params, context: context
            ) { newTokens -> GenerateDisposition in
                allTokens += newTokens
                partialBuffer += newTokens

                // Decode incrementally — flush when we have clean UTF-8
                let piece = context.tokenizer.decode(tokens: partialBuffer)
                if !piece.isEmpty && piece.isValidUTF8 {
                    partialBuffer = []
                    Task { @MainActor in onToken(piece) }
                }

                return allTokens.count >= maxTokens ? .stop : .more
            }

            // Flush any remaining buffer
            if !partialBuffer.isEmpty {
                let last = context.tokenizer.decode(tokens: partialBuffer)
                if !last.isEmpty { Task { @MainActor in onToken(last) } }
            }

            let fullText = result.output
            Task { @MainActor in onFinish(fullText) }
        }
    }

    // MARK: - Single-shot (blocking)

    func generate(
        prompt: String,
        maxTokens: Int = 2048,
        temperature: Double = 0.1
    ) async throws -> String {
        guard let box = container else { throw MLXError.notLoaded }
        let params    = GenerateParameters(temperature: Float(temperature))
        let userInput = UserInput(prompt: prompt)

        return try await box.perform { (context: ModelContext) in
            let lmInput: LMInput
            do {
                lmInput = try await context.processor.prepare(input: userInput)
            } catch {
                let ids = context.tokenizer.encode(text: prompt)
                lmInput = LMInput(tokens: .init(ids.map { Int32($0) }))
            }
            var all: [Int] = []
            let result = try MLXLMCommon.generate(
                input: lmInput, parameters: params, context: context
            ) { tokens -> GenerateDisposition in
                all += tokens; return all.count >= maxTokens ? .stop : .more
            }
            return result.output
        }
    }

    // MARK: - Download only (no load)

    func downloadModel(
        repoId: String,
        hfToken: String? = nil,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws {
        var hub = defaultHubApi
        if let token = hfToken { hub = HubApi(hfToken: token) }
        let config = ModelConfiguration(id: repoId)
        await MainActor.run { onProgress("↓ Fetching \(repoId)…") }
        _ = try await LLMModelFactory.shared.loadContainer(hub: hub, configuration: config) { p in
            let pct = Int(p.fractionCompleted * 100)
            Task { @MainActor in onProgress("↓ \(repoId)  \(pct)%") }
        }
        await MainActor.run { onProgress("✅ Download complete: \(repoId)") }
    }
}

// MARK: - String UTF-8 validity helper

private extension String {
    var isValidUTF8: Bool { utf8.withContiguousStorageIfAvailable { _ in true } != nil }
}

// MARK: - LMInput convenience (tokens from MLXArray)

private extension LMInput {
    init(tokens array: MLXArray) {
        self.init(tokens: array)
    }
}

// MARK: - Errors

enum MLXError: Error, LocalizedError {
    case notLoaded
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notLoaded:             return "MLX model not loaded."
        case .downloadFailed(let m): return "Download failed: \(m)"
        }
    }
}
