import Foundation

// MARK: - MLXRunner
// Manages the mlx_lm.server process — an OpenAI-compatible HTTP server
// that loads a model once into Unified Memory and serves it at localhost:8080.
//
// Architecture:
//   Swift IDE → HTTP /v1/chat/completions → mlx_lm.server → Apple Silicon GPU
//
// The server exposes an OpenAI-compatible API, so we can reuse the same
// chat completion format as CloudAPIClient, but pointing to localhost.
//
// Usage:
//   await MLXRunner.shared.startServer(model: "mlx-community/gemma-3-27b-it-4bit")
//   let text = await MLXRunner.shared.generate(prompt: "...")

// MARK: - MLX Popular Models

struct MLXModel: Identifiable, Hashable {
    let id: String          // HuggingFace repo ID
    let displayName: String
    let sizeGB: Double
    let tags: [String]

    var isDownloaded: Bool {
        let cachePath = MLXRunner.cacheDir.appendingPathComponent(
            id.replacingOccurrences(of: "/", with: "--")
        )
        return FileManager.default.fileExists(atPath: cachePath.path)
    }
}

// MARK: - MLXRunner

actor MLXRunner {

    static let shared = MLXRunner()

    // ── Python path ──────────────────────────────────────────────────
    static let pythonPath: String = {
        for p in ["/usr/local/bin/python3", "/opt/homebrew/bin/python3",
                  "/usr/bin/python3", "python3"] {
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return "python3"
    }()

    static let cacheDir: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".cache/huggingface/hub")
    }()

    static let port = 8080
    static let baseURL = "http://127.0.0.1:\(port)"

    // MLX-recommended models for code editing
    static let popularModels: [MLXModel] = [
        MLXModel(id: "mlx-community/gemma-4-26b-a4b-it-4bit",
                 displayName: "Gemma 4 26B (4bit) ⭐ 最新・最高性能",
                 sizeGB: 17.0,
                 tags: ["thinking", "latest", "recommended"]),
        MLXModel(id: "mlx-community/gemma-3-27b-it-4bit",
                 displayName: "Gemma 3 27B (4bit) — 安定版",
                 sizeGB: 18.0,
                 tags: ["thinking", "stable"]),
        MLXModel(id: "mlx-community/gemma-3-12b-it-4bit",
                 displayName: "Gemma 3 12B (4bit) — 軽量版",
                 sizeGB: 8.0,
                 tags: ["fast"]),
        MLXModel(id: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
                 displayName: "Qwen 2.5 Coder 7B — コード特化",
                 sizeGB: 4.5,
                 tags: ["code", "fast"]),
        MLXModel(id: "mlx-community/Qwen2.5-Coder-32B-Instruct-4bit",
                 displayName: "Qwen 2.5 Coder 32B — 最高精度",
                 sizeGB: 20.0,
                 tags: ["code", "large"]),
        MLXModel(id: "mlx-community/Mistral-7B-Instruct-v0.3-4bit",
                 displayName: "Mistral 7B Instruct",
                 sizeGB: 4.0,
                 tags: ["fast"]),
        MLXModel(id: "mlx-community/Phi-4-mini-instruct-4bit",
                 displayName: "Phi-4 Mini — 超高速",
                 sizeGB: 2.5,
                 tags: ["fast", "small"]),
    ]

    // ── State ────────────────────────────────────────────────────────
    private var serverProcess: Process?
    private(set) var loadedModel: String?
    private(set) var serverState: MLXServerState = .stopped

    enum MLXServerState: Equatable {
        case stopped
        case loading(model: String)
        case ready(model: String)
        case error(String)
    }

    // ── Start server ─────────────────────────────────────────────────

    func startServer(
        model: String,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws {

        // If same model already running, skip
        if case .ready(let m) = serverState, m == model {
            await MainActor.run { onProgress("✅ MLX server already running: \(model)") }
            return
        }

        // Kill previous server if different model
        stopServer()
        serverState = .loading(model: model)
        await MainActor.run { onProgress("⚙️ Loading \(model) into Unified Memory…") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.pythonPath)
        process.arguments = [
            "-m", "mlx_lm", "server",
            "--model", model,
            "--port", String(Self.port),
            "--host", "127.0.0.1",
            "--max-tokens", "4096",
        ]

        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()  // discard stdout noise

        // Read startup logs to detect readiness
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let line = String(data: data, encoding: .utf8) else { return }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                onProgress("MLX: \(trimmed)")
            }
        }

        try process.run()
        self.serverProcess = process
        self.loadedModel = model

        // Poll until server is ready (max 120s — large model loading)
        let deadline = Date().addingTimeInterval(120)
        var ready = false
        while Date() < deadline {
            if await probeServer() {
                ready = true
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run { onProgress("⏳ Waiting for MLX server…") }
        }

        if ready {
            serverState = .ready(model: model)
            await MainActor.run { onProgress("✅ MLX ready: \(model)") }
        } else {
            serverState = .error("Timeout loading \(model)")
            process.terminate()
            throw MLXError.serverTimeout
        }
    }

    func stopServer() {
        serverProcess?.terminate()
        serverProcess = nil
        loadedModel = nil
        serverState = .stopped
    }

    // ── Probe server readiness ────────────────────────────────────────

    func probeServer() async -> Bool {
        guard let url = URL(string: "\(Self.baseURL)/v1/models") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    // ── Generate (non-streaming) ─────────────────────────────────────

    func generate(
        prompt: String,
        systemPrompt: String = "You are Verantyx, an expert AI coding assistant running on Apple Silicon via MLX.",
        maxTokens: Int = 4096,
        temperature: Double = 0.1
    ) async -> String? {
        guard let model = loadedModel,
              case .ready = serverState else { return nil }

        let url = URL(string: "\(Self.baseURL)/v1/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 180

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": prompt]
            ],
            "max_tokens": maxTokens,
            "temperature": temperature,
            "stream": false
        ]

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = bodyData

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String
            else { return nil }
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    // ── Streaming generate ───────────────────────────────────────────

    func streamGenerate(
        prompt: String,
        systemPrompt: String = "You are Verantyx, an expert AI coding assistant running on Apple Silicon via MLX.",
        maxTokens: Int = 4096,
        temperature: Double = 0.1
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let model = self.loadedModel,
                      case .ready = self.serverState else {
                    continuation.finish(); return
                }

                let url = URL(string: "\(Self.baseURL)/v1/chat/completions")!
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.timeoutInterval = 180

                let body: [String: Any] = [
                    "model": model,
                    "messages": [
                        ["role": "system", "content": systemPrompt],
                        ["role": "user",   "content": prompt]
                    ],
                    "max_tokens": maxTokens,
                    "temperature": temperature,
                    "stream": true
                ]

                guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
                    continuation.finish(); return
                }
                req.httpBody = bodyData

                do {
                    let (stream, _) = try await URLSession.shared.bytes(for: req)
                    for try await line in stream.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        if jsonStr == "[DONE]" { break }
                        guard let data = jsonStr.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = json["choices"] as? [[String: Any]],
                              let delta = choices.first?["delta"] as? [String: Any],
                              let token = delta["content"] as? String,
                              !token.isEmpty
                        else { continue }
                        continuation.yield(token)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // ── Download model via mlx_lm download ──────────────────────────

    func downloadModel(
        repoId: String,
        onProgress: @escaping @Sendable (String) -> Void
    ) async throws {
        await MainActor.run { onProgress("⬇️ Downloading \(repoId)…") }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: Self.pythonPath)
                process.arguments = ["-m", "mlx_lm", "download", "--model", repoId]

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError  = errPipe

                // Stream download progress
                outPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if let line = String(data: data, encoding: .utf8), !line.isEmpty {
                        onProgress(line.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                errPipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    if let line = String(data: data, encoding: .utf8), !line.isEmpty {
                        onProgress(line.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }

                do {
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus == 0 {
                        onProgress("✅ Download complete: \(repoId)")
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: MLXError.downloadFailed(repoId))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

// MARK: - MLXError

enum MLXError: Error, LocalizedError {
    case serverTimeout
    case downloadFailed(String)
    case notReady

    var errorDescription: String? {
        switch self {
        case .serverTimeout:         return "MLX server timed out loading model."
        case .downloadFailed(let m): return "Download failed: \(m)"
        case .notReady:              return "MLX server not ready."
        }
    }
}
