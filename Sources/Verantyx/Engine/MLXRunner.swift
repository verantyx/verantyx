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
