import Foundation

// MARK: - CloudAPIClient
// Multi-provider cloud API client.
// API keys are stored in UserDefaults (Keychain in production).
// Supports: Anthropic Claude, OpenAI GPT, Google Gemini

// MARK: - CloudProvider

enum CloudProvider: String, CaseIterable, Codable {
    case claude   = "Claude (Anthropic)"
    case openai   = "GPT-4 (OpenAI)"
    case gemini   = "Gemini (Google)"
    case deepseek = "DeepSeek"

    var icon: String {
        switch self {
        case .claude:   return "sparkles"
        case .openai:   return "circlebadge.2"
        case .gemini:   return "star.circle"
        case .deepseek: return "waveform.circle"
        }
    }

    var defaultModel: String {
        switch self {
        case .claude:   return UserDefaults.standard.string(forKey: "anthropic_model") ?? "claude-sonnet-4-5"
        case .openai:   return UserDefaults.standard.string(forKey: "openai_model") ?? "gpt-4o"
        case .gemini:   return UserDefaults.standard.string(forKey: "gemini_model") ?? "gemini-3.1-pro"
        case .deepseek: return UserDefaults.standard.string(forKey: "deepseek_model") ?? "deepseek-coder"
        }
    }

    var maxTokens: Int {
        switch self {
        case .claude:   return 8192
        case .openai:   return 4096
        case .gemini:   return 8192
        case .deepseek: return 8192
        }
    }
}

// MARK: - CloudAPIClient

actor CloudAPIClient {

    static let shared = CloudAPIClient()

    // MARK: - Retrieve API key

    func apiKey(for provider: CloudProvider) -> String? {
        switch provider {
        case .claude:   return UserDefaults.standard.string(forKey: "anthropic_api_key")
        case .openai:   return UserDefaults.standard.string(forKey: "openai_api_key")
        case .gemini:   return UserDefaults.standard.string(forKey: "gemini_api_key")
        case .deepseek: return UserDefaults.standard.string(forKey: "api_key_DeepSeek")
        }
    }

    func setAPIKey(_ key: String, for provider: CloudProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespaces)
        switch provider {
        case .claude:   UserDefaults.standard.set(trimmed, forKey: "anthropic_api_key")
        case .openai:   UserDefaults.standard.set(trimmed, forKey: "openai_api_key")
        case .gemini:   UserDefaults.standard.set(trimmed, forKey: "gemini_api_key")
        case .deepseek: UserDefaults.standard.set(trimmed, forKey: "api_key_DeepSeek")
        }
    }

    func hasAPIKey(for provider: CloudProvider) -> Bool {
        guard let key = apiKey(for: provider) else { return false }
        return !key.isEmpty
    }

    // MARK: - Main: send message

    func send(
        systemPrompt: String,
        userMessage: String,
        provider: CloudProvider,
        modelOverride: String? = nil
    ) async -> Result<String, CloudError> {

        guard let key = apiKey(for: provider), !key.isEmpty else {
            return .failure(.noAPIKey(provider))
        }

        let model = modelOverride ?? provider.defaultModel

        switch provider {
        case .claude:   return await callClaude(systemPrompt: systemPrompt, userMessage: userMessage, model: model, apiKey: key)
        case .openai:   return await callOpenAI(systemPrompt: systemPrompt, userMessage: userMessage, model: model, apiKey: key)
        case .gemini:   return await callGemini(systemPrompt: systemPrompt, userMessage: userMessage, model: model, apiKey: key)
        case .deepseek: return await callDeepSeek(systemPrompt: systemPrompt, userMessage: userMessage, model: model, apiKey: key)
        }
    }

    // MARK: - Anthropic Claude

    private func callClaude(systemPrompt: String, userMessage: String, model: String, apiKey: String) async -> Result<String, CloudError> {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": model,
            "max_tokens": CloudProvider.claude.maxTokens,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userMessage]
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            guard httpResponse.statusCode == 200 else {
                let errStr = String(data: data, encoding: .utf8) ?? "unknown"
                return .failure(.apiError(httpResponse.statusCode, errStr.prefix(200).description))
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let content = json["content"] as? [[String: Any]],
                  let firstBlock = content.first,
                  let text = firstBlock["text"] as? String
            else { return .failure(.parseError) }

            return .success(text)
        } catch {
            return .failure(.networkError(error.localizedDescription))
        }
    }

    // MARK: - OpenAI GPT

    private func callOpenAI(systemPrompt: String, userMessage: String, model: String, apiKey: String) async -> Result<String, CloudError> {
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": model,
            "max_tokens": CloudProvider.openai.maxTokens,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userMessage]
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            guard httpResponse.statusCode == 200 else {
                let errStr = String(data: data, encoding: .utf8) ?? "unknown"
                return .failure(.apiError(httpResponse.statusCode, errStr.prefix(200).description))
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let text = message["content"] as? String
            else { return .failure(.parseError) }

            return .success(text)
        } catch {
            return .failure(.networkError(error.localizedDescription))
        }
    }

    // MARK: - Google Gemini

    private func callGemini(systemPrompt: String, userMessage: String, model: String, apiKey: String) async -> Result<String, CloudError> {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": systemPrompt]]],
            "contents": [
                ["role": "user", "parts": [["text": userMessage]]]
            ],
            "generationConfig": [
                "maxOutputTokens": CloudProvider.gemini.maxTokens,
                "temperature": 0.1
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            guard httpResponse.statusCode == 200 else {
                let errStr = String(data: data, encoding: .utf8) ?? "unknown"
                return .failure(.apiError(httpResponse.statusCode, errStr.prefix(200).description))
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let first = candidates.first,
                  let content = first["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let text = parts.first?["text"] as? String
            else { return .failure(.parseError) }

            return .success(text)
        } catch {
            return .failure(.networkError(error.localizedDescription))
        }
    }

    // MARK: - DeepSeek

    private func callDeepSeek(systemPrompt: String, userMessage: String, model: String, apiKey: String) async -> Result<String, CloudError> {
        let url = URL(string: "https://api.deepseek.com/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": model,
            "max_tokens": CloudProvider.deepseek.maxTokens,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user",   "content": userMessage]
            ]
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure(.invalidResponse)
            }
            guard httpResponse.statusCode == 200 else {
                let errStr = String(data: data, encoding: .utf8) ?? "unknown"
                return .failure(.apiError(httpResponse.statusCode, errStr.prefix(200).description))
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let text = message["content"] as? String
            else { return .failure(.parseError) }

            return .success(text)
        } catch {
            return .failure(.networkError(error.localizedDescription))
        }
    }
}

// MARK: - CloudError

enum CloudError: Error, LocalizedError {
    case noAPIKey(CloudProvider)
    case invalidResponse
    case apiError(Int, String)
    case parseError
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey(let p):         return "No API key for \(p.rawValue). Add it in Settings → Cloud APIs."
        case .invalidResponse:         return "Invalid HTTP response from cloud API."
        case .apiError(let code, let msg): return "API error \(code): \(msg)"
        case .parseError:              return "Failed to parse cloud API response."
        case .networkError(let msg):   return "Network error: \(msg)"
        }
    }
}
