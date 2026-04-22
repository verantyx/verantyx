import Foundation

// MARK: - OllamaClient
// Connects to Ollama at localhost:11434.
// gemma4:26b is a thinking model — uses /api/chat with num_predict ≥ 1024.

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

    // MARK: - Generation (thinking model aware)

    /// Generates a completion. Uses /api/chat with num_predict=2048 for thinking models.
    public func generate(
        model: String,
        prompt: String,
        maxTokens: Int = 2048,
        temperature: Double = 0.1
    ) async -> String? {
        guard let url = URL(string: "\(baseURL)/api/chat") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300   // large files may take time

        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "stream": false,
            "options": [
                "num_predict": max(maxTokens, 2048),  // ensure thinking completes
                "temperature": temperature,
                "top_p": 0.9,
                "repeat_penalty": 1.05
            ]
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        req.httpBody = bodyData

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = json["message"] as? [String: Any] else { return nil }

            let content = (message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty { return content }

            // Thinking model fallback if content is empty
            let thinking = (message["thinking"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return thinking.isEmpty ? nil : thinking
        } catch {
            print("[OllamaClient] error: \(error)")
            return nil
        }
    }

    // MARK: - Streaming (for chat UI)
    // nonisolated: returns a stream immediately; the async work happens inside the Task

    nonisolated public func streamGenerate(
        model: String,
        prompt: String,
        maxTokens: Int = 2048,
        temperature: Double = 0.7
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let url = URL(string: "\(self.baseURL)/api/chat") else {
                    continuation.finish(); return
                }
                var req = URLRequest(url: url)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.timeoutInterval = 300

                let body: [String: Any] = [
                    "model": model,
                    "messages": [["role": "user", "content": prompt]],
                    "stream": true,
                    "options": ["num_predict": max(maxTokens, 2048), "temperature": temperature]
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

                        if let msg = json["message"] as? [String: Any],
                           let token = msg["content"] as? String, !token.isEmpty {
                            continuation.yield(token)
                        }
                        if json["done"] as? Bool == true {
                            continuation.finish(); return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    public func resetAvailability() { _available = nil; _availableTime = nil }
}
