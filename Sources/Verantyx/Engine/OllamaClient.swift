import Foundation

// MARK: - LLMStreamEvent
// openclaw/pi-agent-core の StreamFn パターンを Swift に移植。
// ollama-stream.ts の `for await (const chunk of parseNdjsonStream(reader))` に対応。

public enum LLMStreamEvent: Sendable {
    case token(String)
    case thinking(String)
    case toolCall(name: String, args: String)
    case done(stopReason: StopReason)
    case error(String)
}

public enum StopReason: String, Sendable {
    case endTurn   = "stop"
    case toolUse   = "tool_calls"
    case maxTokens = "length"
    case error     = "error"
}

// MARK: - OllamaClient
// openclaw の ollama-stream.ts から設計を学んで改修。
// 変更点:
//   - generate() が token-by-token streaming に変更（stream: true + /api/chat NDJSON）
//   - streamConversation() で会話履歴をそのまま渡せるようにした
//   - multi-turn messages array 対応（AgentLoop が渡す conversation のため）
//   - num_ctx=65536 デフォルト（ollama の 4096 デフォルトは小さすぎる）
//   - thinking コンテンツの分離抽出

public actor OllamaClient {

    public static let shared = OllamaClient()
    private let baseURL = "http://127.0.0.1:11434"
    private var _available: Bool? = nil
    private var _availableTime: Date? = nil

    // MARK: - Availability (5s TTL cache)

    public func isAvailable() async -> Bool {
        if let t = _availableTime, Date().timeIntervalSince(t) < 5, let c = _available { return c }
        let ok = await probe()
        _available = ok; _availableTime = Date()
        return ok
    }

    private func probe() async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    // MARK: - Model list

    public func listModels() async -> [String] {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else { return [] }
            return models.compactMap { $0["name"] as? String }
        } catch { return [] }
    }

    // MARK: - generate() — streaming token-by-token (replaces batch mode)
    // openclaw: ollama-stream.ts の createOllamaStreamFn() を参考に実装。
    // Ollamaは stream:true 時に NDJSON チャンクを逐次返す。
    // ここでは AgentLoop 互換のシグネチャを保ちつつ、内部はストリームで受信する。

    public func generate(
        model: String,
        prompt: String,
        maxTokens: Int = 2048,
        temperature: Double = 0.15,
        onToken: (@Sendable (String) -> Void)? = nil   // NEW: per-token callback
    ) async -> String? {
        // シングルユーザーメッセージをmulti-turn形式に変換
        let messages: [[String: Any]] = [["role": "user", "content": prompt]]
        return await streamChat(
            model: model,
            messages: messages,
            maxTokens: maxTokens,
            temperature: temperature,
            onToken: onToken
        )
    }

    // MARK: - generateConversation() — multi-turn対応（AgentLoop用）
    // openclaw: convertToOllamaMessages() と同様にロールをそのまま渡す

    public func generateConversation(
        model: String,
        messages: [(role: String, content: String)],
        maxTokens: Int = 2048,
        temperature: Double = 0.15,
        onToken: (@Sendable (String) -> Void)? = nil
    ) async -> String? {
        let ollamaMessages: [[String: Any]] = messages.map { ["role": $0.role, "content": $0.content] }
        return await streamChat(
            model: model,
            messages: ollamaMessages,
            maxTokens: maxTokens,
            temperature: temperature,
            onToken: onToken
        )
    }

    // MARK: - Core: streamChat()
    // openclaw の NDJSON ストリーム解析ロジックをそのまま Swift で再現。
    // done:true チャンクを受け取るまでトークンを結合。

    private func streamChat(
        model: String,
        messages: [[String: Any]],
        maxTokens: Int,
        temperature: Double,
        onToken: (@Sendable (String) -> Void)? = nil
    ) async -> String? {
        guard let url = URL(string: "\(baseURL)/api/chat") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 600   // 大きいファイルの生成に対応

        // openclaw: num_ctx=65536 (ollama のデフォルト 4096 は小さすぎる)
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
            "options": [
                "num_ctx": 65536,
                "num_predict": max(maxTokens, 512),
                "temperature": temperature,
                "top_p": 0.9,
                "repeat_penalty": 1.05
            ]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = bodyData

        var accumulated      = ""
        var accumulatedThink = ""

        do {
            let (stream, resp) = try await URLSession.shared.bytes(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }

            // openclaw: parseNdjsonStream(reader) — 1行 = 1 JSONオブジェクト
            for try await line in stream.lines {
                guard !line.isEmpty,
                      let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                if let message = json["message"] as? [String: Any] {
                    // 通常コンテンツ
                    if let token = message["content"] as? String, !token.isEmpty {
                        accumulated += token
                        onToken?(token)  // ← UI へリアルタイム配信
                    }
                    // 思考コンテンツ（Gemma-4 thinking）
                    if let think = message["thinking"] as? String, !think.isEmpty {
                        accumulatedThink += think
                    }
                }

                // openclaw: chunk.done → finalResponse
                if json["done"] as? Bool == true { break }
            }

            let result = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            // 空なら thinking フォールバック（Gemma-4 thinking-only モード）
            if result.isEmpty && !accumulatedThink.isEmpty {
                return accumulatedThink.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return result.isEmpty ? nil : result

        } catch {
            print("[OllamaClient] streamChat error: \(error)")
            return nil
        }
    }

    // MARK: - streamGenerate() — AsyncThrowingStream (chat UI用, 既存互換)

    nonisolated public func streamGenerate(
        model: String,
        messages: [(role: String, content: String)],
        maxTokens: Int = 2048,
        temperature: Double = 0.7
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let baseURL = self.baseURL
        return AsyncThrowingStream { continuation in
            Task {
                guard let url = URL(string: "\(baseURL)/api/chat") else {
                    continuation.finish(); return
                }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.timeoutInterval = 600

                let ollamaMessages = messages.map { ["role": $0.role, "content": $0.content] }
                let body: [String: Any] = [
                    "model": model,
                    "messages": ollamaMessages,
                    "stream": true,
                    "options": [
                        "num_ctx": 65536,
                        "num_predict": max(maxTokens, 512),
                        "temperature": temperature
                    ]
                ]
                guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
                    continuation.finish(); return
                }
                req.httpBody = bodyData

                do {
                    let (stream, _) = try await URLSession.shared.bytes(for: req)
                    for try await line in stream.lines {
                        guard !line.isEmpty,
                              let data = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if let msg = json["message"] as? [String: Any] {
                            if let token = msg["content"] as? String, !token.isEmpty {
                                continuation.yield(.token(token))
                            }
                            if let think = msg["thinking"] as? String, !think.isEmpty {
                                continuation.yield(.thinking(think))
                            }
                        }
                        if json["done"] as? Bool == true {
                            continuation.yield(.done(stopReason: .endTurn))
                            continuation.finish()
                            return
                        }
                    }
                    continuation.yield(.done(stopReason: .endTurn))
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func resetAvailability() { _available = nil; _availableTime = nil }
}

// MARK: - AnthropicClient
// openclaw/src/agents/ の Anthropic Messages API 実装を参考に Swift で実装。
// claw-code の claude-cli-runner.ts + openai-ws-stream.ts の設計を踏襲。
//
// 設計原則 (openclaw から学んだこと):
//   1. messages array 形式（system は最上位パラメータ）
//   2. stream: true で Server-Sent Events を受信
//   3. "content_block_delta" → "text_delta" でトークンを逐次処理
//   4. "message_stop" で終了
//   5. stopReason: "end_turn" / "tool_use" / "max_tokens"

public actor AnthropicClient {

    public static let shared = AnthropicClient()

    var apiKey: String = ""  // internal: Task 内で await AnthropicClient.shared.apiKey で取得
    private let baseURL = "https://api.anthropic.com/v1"
    private let anthropicVersion = "2023-06-01"
    private let betaHeader = "interleaved-thinking-2025-05-14"  // thinking beta

    // MARK: - Configuration

    public func configure(apiKey: String) {
        self.apiKey = apiKey
    }

    public var isConfigured: Bool { !apiKey.isEmpty }

    // MARK: - Available models

    public static let models: [(id: String, displayName: String)] = [
        ("claude-opus-4-5",      "Claude Opus 4.5"),
        ("claude-sonnet-4-5",    "Claude Sonnet 4.5"),
        ("claude-haiku-4-5",     "Claude Haiku 4.5"),
        ("claude-3-7-sonnet-20250219", "Claude 3.7 Sonnet (Thinking)"),
        ("claude-opus-4-0",      "Claude Opus 4"),
        ("claude-sonnet-4-0",    "Claude Sonnet 4"),
    ]

    // MARK: - generate() — streaming (token-by-token)
    // openclaw: anthropic-payload-log.ts + pi-embedded-runner の SSE 処理を参考に実装

    public func generate(
        model: String,
        systemPrompt: String,
        messages: [(role: String, content: String)],
        maxTokens: Int = 8096,
        temperature: Double = 0.15,
        enableThinking: Bool = false,      // claude-3-7-sonnet 以降でサポート
        budgetTokens: Int = 10000,
        onToken: (@Sendable (String) -> Void)? = nil,
        onThinking: (@Sendable (String) -> Void)? = nil
    ) async -> String? {
        guard !apiKey.isEmpty else {
            print("[AnthropicClient] API key not configured")
            return nil
        }

        guard let url = URL(string: "\(baseURL)/messages") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 600

        // Thinking beta header
        if enableThinking {
            req.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        }

        // openclaw: Anthropic messages format
        var anthropicMessages: [[String: Any]] = messages.map { msg in
            // User と assistant のみ — system は最上位パラメータ
            return ["role": msg.role, "content": msg.content]
        }

        var body: [String: Any] = [
            "model":      model,
            "system":     systemPrompt,
            "messages":   anthropicMessages,
            "max_tokens": max(maxTokens, 1024),
            "stream":     true
        ]

        if temperature != 1.0 && !enableThinking {
            // thinking が有効な場合 temperature=1 が必須（Anthropic制約）
            body["temperature"] = temperature
        }

        // Extended thinking (claude-3-7-sonnet+)
        if enableThinking {
            body["thinking"] = ["type": "enabled", "budget_tokens": budgetTokens]
        }

        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = bodyData

        return await parseAnthropicSSE(req: req, onToken: onToken, onThinking: onThinking)
    }

    // MARK: - SSE Parser
    // openclaw の stream event 処理を参考:
    //   "content_block_delta" { delta: { type: "text_delta", text: "..." } }
    //   "content_block_delta" { delta: { type: "thinking_delta", thinking: "..." } }
    //   "message_stop" → done

    private func parseAnthropicSSE(
        req: URLRequest,
        onToken: (@Sendable (String) -> Void)?,
        onThinking: (@Sendable (String) -> Void)?
    ) async -> String? {
        var accumulated      = ""
        var accumulatedThink = ""

        do {
            let (stream, resp) = try await URLSession.shared.bytes(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                // エラーレスポンスをログ
                print("[AnthropicClient] HTTP error: \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }

            for try await line in stream.lines {
                // SSE format: "data: {...}" or "event: ..."
                guard line.hasPrefix("data: ") else { continue }
                let jsonStr = String(line.dropFirst(6))  // "data: " の6文字を削除
                guard jsonStr != "[DONE]",
                      let data = jsonStr.data(using: .utf8),
                      let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                let eventType = event["type"] as? String ?? ""

                switch eventType {
                case "content_block_delta":
                    guard let delta = event["delta"] as? [String: Any] else { continue }
                    let deltaType = delta["type"] as? String ?? ""

                    if deltaType == "text_delta", let text = delta["text"] as? String, !text.isEmpty {
                        accumulated += text
                        onToken?(text)   // ← UI にリアルタイム配信

                    } else if deltaType == "thinking_delta",
                              let think = delta["thinking"] as? String, !think.isEmpty {
                        accumulatedThink += think
                        onThinking?(think)
                    }

                case "message_stop":
                    break  // ストリーム終了

                case "error":
                    let err = (event["error"] as? [String: Any])?["message"] as? String ?? "unknown"
                    print("[AnthropicClient] API error: \(err)")
                    return nil

                default:
                    break
                }
            }

            let result = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            return result.isEmpty ? nil : result

        } catch {
            print("[AnthropicClient] SSE error: \(error)")
            return nil
        }
    }

    // MARK: - streamGenerate() — AsyncThrowingStream (chat UI用)

    nonisolated public func streamGenerate(
        model: String,
        systemPrompt: String,
        messages: [(role: String, content: String)],
        maxTokens: Int = 8096,
        temperature: Double = 0.15,
        enableThinking: Bool = false
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        // actor-isolated プロパティは nonisolated コンテキストから参照不可——キーをコピーして渡す
        let capturedBaseURL = baseURL
        let capturedVersion = anthropicVersion
        let capturedBeta    = betaHeader

        return AsyncThrowingStream { continuation in
            Task {
                let apiKey = await AnthropicClient.shared.apiKey  // actor コンテキストから取得
                guard !apiKey.isEmpty else {
                    continuation.yield(.error("Anthropic API key not configured"))
                    continuation.finish(); return
                }
                guard let url = URL(string: "\(capturedBaseURL)/messages") else {
                    continuation.finish(); return
                }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                req.setValue(capturedVersion, forHTTPHeaderField: "anthropic-version")
                req.timeoutInterval = 600
                if enableThinking {
                    req.setValue(capturedBeta, forHTTPHeaderField: "anthropic-beta")
                }

                let anthropicMessages = messages.map { ["role": $0.role, "content": $0.content] }
                var body: [String: Any] = [
                    "model": model, "system": systemPrompt,
                    "messages": anthropicMessages,
                    "max_tokens": max(maxTokens, 1024), "stream": true
                ]
                if !enableThinking { body["temperature"] = temperature }
                if enableThinking { body["thinking"] = ["type": "enabled", "budget_tokens": 10000] }

                guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else {
                    continuation.finish(); return
                }
                req.httpBody = bodyData

                do {
                    let (stream, _) = try await URLSession.shared.bytes(for: req)
                    for try await line in stream.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let jsonStr = String(line.dropFirst(6))
                        guard jsonStr != "[DONE]",
                              let data = jsonStr.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        switch event["type"] as? String ?? "" {
                        case "content_block_delta":
                            if let delta = event["delta"] as? [String: Any] {
                                if let text = delta["text"] as? String, !text.isEmpty {
                                    continuation.yield(.token(text))
                                } else if let think = delta["thinking"] as? String, !think.isEmpty {
                                    continuation.yield(.thinking(think))
                                }
                            }
                        case "message_stop":
                            continuation.yield(.done(stopReason: .endTurn))
                            continuation.finish(); return
                        case "error":
                            let msg = (event["error"] as? [String: Any])?["message"] as? String ?? "error"
                            continuation.yield(.error(msg)); continuation.finish(); return
                        default: break
                        }
                    }
                    continuation.yield(.done(stopReason: .endTurn))
                    continuation.finish()
                } catch {
                    continuation.yield(.error(error.localizedDescription))
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
