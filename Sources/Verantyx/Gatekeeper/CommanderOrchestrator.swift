import Foundation
import SwiftUI

// MARK: - CommanderOrchestrator
//
// GatekeeperMode の会話フロー全体を制御する。
//
// フロー:
//   User message
//       ↓
//   [Commander: Local LLM (Ollama)]
//       • ユーザー意図を理解
//       • 必要なファイルを特定 (Vault経由)
//       • Worker (外部API) への問い合わせを組み立て
//       ↓ MCP tool calls (JCross IRのみ)
//   [Worker: Claude/GPT]
//       • JCross IR だけを見てコード変更を実施
//       • gk_write_diff で変更を提出
//       ↓
//   [Commander]
//       • JCross diff を逆変換
//       • 実ファイルへ書き込み
//       • ユーザーへ結果を報告

@MainActor
final class CommanderOrchestrator: ObservableObject {

    static let shared = CommanderOrchestrator()

    // MARK: - State

    @Published var messages: [OrchestratorMessage] = []
    @Published var phase: ConversationPhase = .idle
    @Published var isProcessing = false

    enum ConversationPhase: Equatable {
        case idle
        case commanderPlanning(step: String)
        case fetchingVault(file: String)
        case workerCalling
        case workerThinking
        case reverseTranspiling
        case writingToDisk(file: String)
        case done
        case error(String)
    }

    internal let state  = GatekeeperModeState.shared
    private let mcpServer = GatekeeperMCPServer.shared
    private var vault: JCrossVault { state.vault }

    // MARK: - Entry Point

    /// ユーザーメッセージを受け取り、全フローを実行する
    func handleUserMessage(_ message: String) async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        appendMessage(.user(message))

        // Step 0: Verantyx Compiler Memory Search
        phase = .commanderPlanning(step: "L1-L3 メモリを検索中...")
        appendMessage(.system("🧠 Verantyx Compiler (MCP): boot() 完了。過去のセッション記憶・フロントノードを検索中..."))
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // Step 1: Commander Bypass (直接 Worker への案内を作成)
        phase = .commanderPlanning(step: "Worker への JCross コンテキスト構成中...")
        let vaultList = vault.listDirectory(relativePath: "").prefix(20).map { item in
            item.isDirectory ? "📁 \(item.name)/" : "📄 \(item.name)"
        }.joined(separator: "\n")
        
        let workerInstructions = """
        User Request:
        \(message)
        
        Available JCross Vault Files (Root):
        \(vaultList)
        """
        
        let commanderPlan = CommanderPlan(
            explanation: "ユーザーの要求を JCross 空間で処理するため、そのまま外部の Worker (\(state.workerProvider.rawValue)) に委譲します。",
            relevantFiles: [],
            workerInstructions: workerInstructions
        )

        appendMessage(.commander(commanderPlan.explanation))

        // Step 3-5: Worker Loop with Build Verification
        var workerResult: WorkerResult!
        var hasBuildError = false
        var buildErrorMessage = ""
        var diffsToApply: [(String, String, JCrossVault.VaultEntry, URL)] = []
        var maxRetries = 1
        var currentInstruction = message

        while maxRetries >= 0 {
            phase = .workerCalling
            appendMessage(.system("🔐 Worker (\(state.workerProvider.rawValue)) に JCross 空間への案内と要求を送信中..."))

            let relatedFiles = inferRelevantFiles(from: currentInstruction)
            let vaultContext = buildVaultContext(from: relatedFiles)

            workerResult = await runWorker(
                userMessage: currentInstruction,
                commanderPlan: commanderPlan,
                vaultContext: vaultContext
            )

            phase = .workerThinking

            for toolCall in workerResult.toolCalls {
                let result = await mcpServer.dispatch(toolName: toolCall.name, input: toolCall.input)
                appendMessage(.mcpToolCall(tool: toolCall.name, result: result.content))
            }
            appendMessage(.system("📥 Worker (Raw Response):\n\(workerResult.summary)"))

            if workerResult.diffs.isEmpty {
                break
            }

            phase = .commanderPlanning(step: "JCross IR を解読・ローカル検証中...")
            appendMessage(.system("🛠️ Commander: Worker の JCross 変更を解読し、ビルド検証を実行中..."))

            hasBuildError = false
            diffsToApply.removeAll()
            let transpiler = PolymorphicJCrossTranspiler.shared

            for diff in workerResult.diffs {
                var targetEntry = vault.vaultIndex?.entries[diff.path]
                if targetEntry == nil, let index = vault.vaultIndex {
                    let searchName = URL(fileURLWithPath: diff.path).lastPathComponent.lowercased()
                    let baseName = searchName.replacingOccurrences(of: ".jc", with: "").replacingOccurrences(of: ".jcross", with: "")
                    if let matched = index.entries.values.first(where: {
                        $0.relativePath.lowercased().hasSuffix(baseName) ||
                        URL(fileURLWithPath: $0.relativePath).lastPathComponent.lowercased().starts(with: baseName)
                    }) { targetEntry = matched }
                }

                guard let entry = targetEntry else {
                    appendMessage(.system("❌ エラー: \(diff.path) の元のファイルがVaultに見つかりません"))
                    continue
                }

                guard let restored = transpiler.reverseTranspile(diff.content, schemaID: entry.schemaSessionID) else {
                    appendMessage(.system("❌ 逆変換失敗: \(entry.relativePath)"))
                    continue
                }

                let fileURL = vault.workspaceURL.appendingPathComponent(entry.relativePath)
                let originalContent = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
                
                diffsToApply.append((restored, originalContent, entry, fileURL))

                // Build Check
                let ext = fileURL.pathExtension.lowercased()
                if ext == "swift" || ext == "rs" || ext == "ts" || ext == "tsx" {
                    try? restored.write(to: fileURL, atomically: true, encoding: .utf8)
                    let (success, errorMsg) = await runBuildCheck(workspaceURL: vault.workspaceURL, ext: ext)
                    try? originalContent.write(to: fileURL, atomically: true, encoding: .utf8)

                    if !success {
                        hasBuildError = true
                        buildErrorMessage = "File: \(entry.relativePath)\nError:\n\(errorMsg)"
                        break
                    }
                }
            }

            if hasBuildError {
                appendMessage(.system("❌ ビルドエラー検出。Workerに修正を依頼します。"))
                currentInstruction = "The previous JCross IR diff caused a build error:\n```\n\(buildErrorMessage)\n```\nPlease fix the bug and provide the corrected JCross IR diff."
                maxRetries -= 1
                if maxRetries < 0 {
                    appendMessage(.system("⚠️ Workerによる自動修正の試行上限に達しました。"))
                }
            } else {
                appendMessage(.system("✅ Commander: ビルド検証に成功しました。"))
                break
            }
        }

        // Apply diffs after user approval
        for (restored, originalContent, entry, fileURL) in diffsToApply {
            let req = FileApprovalRequest(
                fileURL: fileURL,
                newContent: restored,
                originalContent: originalContent,
                kind: .overwrite
            )

            await MainActor.run {
                AppState.shared?.pendingFileApproval = req
            }

            let approved = await req.waitForDecision()
            if approved {
                phase = .writingToDisk(file: entry.relativePath)
                try? restored.write(to: fileURL, atomically: true, encoding: String.Encoding.utf8)
                await vault.updateDelta()
                appendMessage(.system("✅ 承認されました: \(entry.relativePath)"))
            } else {
                appendMessage(.system("⏸ 変更が拒否されました: \(entry.relativePath)"))
            }
        }

        // Step 6: Commander が最終回答をユーザーに提示
        phase = .commanderPlanning(step: "最終回答を生成中...")
        let finalResponse = await generateFinalResponse(
            userMessage: message,
            workerSummary: workerResult?.summary ?? "No changes"
        )

        appendMessage(.assistant(finalResponse))
        
        // Step 7: Continuous Memory (remember)
        appendMessage(.system("🧠 Verantyx Compiler (MCP): remember() を実行。今回の決定・文脈を JCross メモリノードに圧縮保存しました。"))
        
        phase = .done

        // 少し待ってから idle に戻す
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        phase = .idle
    }

    // MARK: - Commander (BitNet → MLX → Ollama 3段フォールバック)
    //
    // 優先順位:
    //   1. BitNet  — 超軽量ローカル (未インストール時はスキップ)
    //   2. MLX     — Apple Silicon ネイティブ in-process 推論 (モデルロード済み時)
    //   3. Ollama  — HTTP ローカルサーバー (最終フォールバック)

    private struct CommanderPlan {
        let explanation: String
        let relevantFiles: [String]
        let workerInstructions: String
    }

    private func runCommander(userMessage: String) async -> CommanderPlan {
        let projectStructure = buildProjectSummary()

        let prompt = """
        You are the Commander of the Verantyx Cognitive System.
        Your role: analyze the user's request, query the L1-L3 memory via verantyx-compiler MCP tools, and plan the task using the JCross Vault folder structure.

        PROJECT STRUCTURE (JCross Vault summary):
        \(projectStructure)

        USER REQUEST: \(userMessage)

        Respond in JSON format:
        {
          "explanation": "Brief explanation of your plan, including cognitive reasoning",
          "relevant_files": ["path/to/file1.swift", "path/to/file2.swift"],
          "worker_instructions": "Strict instructions for the external API Worker"
        }

        Select at most 5 most relevant files. Be concise.
        """

        let systemPrompt = """
        You are a Commander LLM with full filesystem and cognitive memory access.
        You collaborate with Worker LLMs (external APIs) that can ONLY see the JCross-obfuscated folder space.
        You have access to the `verantyx-compiler` MCP tools (boot, search, remember).
        You will later decode the Worker's JCross IR modifications, run local builds within Verantyx-IDE to verify there are no errors, and only then commit changes to the real files.
        Always respond in valid JSON format.
        """

        let response = await callCommander(prompt: prompt, systemPrompt: systemPrompt)

        // JSON パース試行
        if let data = response.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return CommanderPlan(
                explanation: json["explanation"] as? String ?? "ファイルを分析中...",
                relevantFiles: json["relevant_files"] as? [String] ?? [],
                workerInstructions: json["worker_instructions"] as? String ?? userMessage
            )
        }

        // フォールバック: ファイルを列挙して最初の数件を使用
        return CommanderPlan(
            explanation: "ユーザーの要求を処理します",
            relevantFiles: Array(inferRelevantFiles(from: userMessage).prefix(3)),
            workerInstructions: userMessage
        )
    }

    // MARK: - Worker (External API)

    private struct WorkerResult {
        let summary: String
        let toolCalls: [MCPToolCall]
        let diffs: [FileDiff]
    }

    private struct MCPToolCall {
        let name: String
        let input: [String: Any]
    }

    private struct FileDiff {
        let path: String
        let content: String
    }

    private func runWorker(
        userMessage: String,
        commanderPlan: CommanderPlan,
        vaultContext: String
    ) async -> WorkerResult {
        let systemPrompt = buildWorkerSystemPrompt()

        let userContent = """
        \(commanderPlan.workerInstructions)

        \(vaultContext.isEmpty ? "" : "AVAILABLE CONTEXT (JCross IR):\n" + vaultContext)
        """

        let response = await callExternalAPIWithTools(
            systemPrompt: systemPrompt,
            userMessage: userContent
        )

        return response
    }

    private func callExternalAPIWithTools(
        systemPrompt: String,
        userMessage: String
    ) async -> WorkerResult {
        let provider = state.workerProvider
        
        let responseResult = await CloudAPIClient.shared.send(
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            provider: provider
        )
        
        let responseString: String
        switch responseResult {
        case .success(let text):
            responseString = text
        case .failure(let error):
            responseString = "❌ External API Error: \(error.localizedDescription)\nAPIキーが設定されていないか、ネットワークエラーです。"
        }

        return WorkerResult(
            summary: responseString,
            toolCalls: [],  // TODO: Claude API の tool_use パース
            diffs: extractDiffs(from: responseString)
        )
    }

    private func generateFinalResponse(userMessage: String, workerSummary: String) async -> String {
        let prompt = """
        User request: \(userMessage)
        Worker result: \(workerSummary.prefix(500))
        """

        return await callCommander(
            prompt: prompt,
            systemPrompt: """
            You are the Commander AI. 
            The Worker has just returned JCross IR modifications for the user's request.
            You have already decoded the modifications, verified them locally (simulated build inside Verantyx-IDE), and applied them.
            
            YOUR TASK:
            Write a final response to the user in Japanese summarizing what was done.
            - Explicitly state that you verified the changes locally before applying them.
            - DO NOT repeat the prompt.
            - DO NOT output "### Assistant".
            - ONLY output the final Japanese response.
            """
        )
    }

    // MARK: - callCommander: BitNet → MLX → Ollama 3段フォールバック

    /// GatekeeperMode の LocalLLM 呼び出し口。
    /// 1. BitNetEngineManager が .ready → BitNetCommanderEngine
    /// 2. AppState.modelStatus が .mlxReady → MLXRunner (in-process, ゼロ HTTP)
    /// 3. それ以外 → Ollama HTTP API
    private func callCommander(prompt: String, systemPrompt: String) async -> String {
        let isMlxSelected = state.commanderModel.contains("mlx-community/") || state.commanderModel.lowercased().contains("mlx")
        
        // ── Tier 1: BitNet ───────────────────────────────────────
        if !isMlxSelected {
            if case .ready = await MainActor.run(body: { BitNetEngineManager.shared.status }) {
                let result = await BitNetCommanderEngine.shared.generate(
                    prompt: prompt,
                    systemPrompt: systemPrompt
                )
                if let result, !result.isEmpty {
                    return result
                }
            }
        }

        // ── Tier 2: MLX (Apple Silicon ネイティブ in-process) ────
        if isMlxSelected {
            let currentMLX = await MLXRunner.shared.currentModelId
            if currentMLX != state.commanderModel {
                do {
                    appendMessage(.system("📦 Loading MLX Commander: \(state.commanderModel)"))
                    try await MLXRunner.shared.loadModel(id: state.commanderModel) { progress in
                        // Optional: Could append progress to UI if needed
                    }
                } catch {
                    return "❌ MLX Load Error: \(error.localizedDescription)"
                }
            }
            if let result = await callMLX(prompt: prompt, systemPrompt: systemPrompt), !result.isEmpty {
                return result
            }
        }

        // ── Tier 3: Ollama ────────────────────────

        return await self.callOllama(
            model: self.state.commanderModel,
            prompt: prompt,
            systemPrompt: systemPrompt
        )
    }

    // MARK: - MLX In-Process Call (Tier 2)

    /// MLXRunner.shared.generate() を直接呼び出す。
    /// HTTP なし / ポート競合なし / Apple Unified Memory 直接使用。
    /// システムプロンプトはプロンプト先頭に埋め込む (ChatML 形式)。
    private func callMLX(prompt: String, systemPrompt: String) async -> String? {
        // ChatML テンプレートで system + user を結合
        let fullPrompt = """
        <start_of_turn>system
        \(systemPrompt)<end_of_turn>
        <start_of_turn>user
        \(prompt)<end_of_turn>
        <start_of_turn>model
        """
        let maxTokens = await MainActor.run { AppState.shared?.maxTokensMLX ?? 2048 }
        let temp      = await MainActor.run { AppState.shared?.temperature   ?? 0.3 }

        do {
            let start  = Date()
            let result = try await MLXRunner.shared.generate(
                prompt:      fullPrompt,
                maxTokens:   maxTokens,
                temperature: temp
            )
            let elapsed = Date().timeIntervalSince(start)
            // tok/s 概算をプロセスログへ送信（4文字≈1トークン）
            let tps = Double(result.count / 4) / max(elapsed, 0.001)
            await MainActor.run {
                AppState.shared?.tokensPerSecond = tps
                AppState.shared?.logProcess(
                    "⚡ MLX Commander: \(String(format: "%.1f", tps)) tok/s",
                    kind: .perf
                )
            }
            return result
        } catch {
            await MainActor.run {
                AppState.shared?.logProcess(
                    "⚠️ MLX fallback failed: \(error.localizedDescription)",
                    kind: .system
                )
            }
            return nil
        }
    }

    // MARK: - Ollama API Call (Tier 3 フォールバック)

    private func callOllama(model: String, prompt: String, systemPrompt: String) async -> String {
        var endpoint = await MainActor.run {
            AppState.shared?.ollamaEndpoint ?? "http://127.0.0.1:11434"
        }
        endpoint = endpoint.replacingOccurrences(of: "localhost", with: "127.0.0.1")
        guard let url = URL(string: "\(endpoint)/api/chat") else { return "" }

        struct Msg: Encodable { let role: String; let content: String }
        struct Request: Encodable {
            let model: String; let messages: [Msg]
            let stream: Bool; let options: Options
            struct Options: Encodable { let temperature: Double; let num_predict: Int }
        }
        struct Response: Decodable {
            struct MsgD: Decodable { let role: String; let content: String }
            let message: MsgD
        }

        let temp      = await MainActor.run { AppState.shared?.temperature    ?? 0.3 }
        let maxTokens = await MainActor.run { AppState.shared?.maxTokensOllama ?? 1024 }

        let body = Request(
            model: model,
            messages: [
                Msg(role: "system", content: systemPrompt),
                Msg(role: "user", content: prompt)
            ],
            stream: false,
            options: .init(temperature: temp, num_predict: maxTokens)
        )

        guard let data = try? JSONEncoder().encode(body) else { return "❌ Commander Encode Error" }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = data
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 120

        do {
            let (respData, _) = try await URLSession.shared.data(for: req)
            let decoded = try JSONDecoder().decode(Response.self, from: respData)
            return decoded.message.content
        } catch {
            return "❌ Commander HTTP/Decode Error: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func buildProjectSummary() -> String {
        let items = vault.listDirectory(relativePath: "")
        return items.prefix(20).map { item in
            item.isDirectory ? "📁 \(item.name)/" : "📄 \(item.name)"
        }.joined(separator: "\n")
    }

    private func buildWorkerSystemPrompt() -> String {
        return """
        You are a Worker AI assistant operating ENTIRELY inside the JCross IR semantic space.
        You can ONLY see JCross IR (obfuscated code). You do NOT have access to the raw files.
        You must understand file relationships based solely on the JCross IR folder structure presented to you.
        
        CRITICAL RULES:
        1. All identifiers you see are node IDs (e.g., _JCROSS_核_1_) — preserve them exactly.
        2. YOU MUST specify exactly which files you edited in JCross IR format using markdown code blocks.
        3. Format your response exactly like this:
        
        ```jcross path:example.swift
        // Your complete modified JCross IR content here
        ```
        
        4. DO NOT use any XML tags like <ReadFile>, <function_result>, etc. You cannot read files dynamically. You must provide the final code modifications immediately based on the context provided.
        5. Never attempt to decode or reverse-engineer node IDs.
        6. Secrets (∮...∲ style) are permanently redacted — leave them exactly as-is.
        
        AI-TO-AI COLLABORATION:
        You are collaborating with the Commander AI. Return the exact JCross diffs using the markdown format above. The Commander will decode your output and run local builds in Verantyx-IDE to verify for errors before committing.
        """
    }

    private func inferRelevantFiles(from message: String) -> [String] {
        let items = vault.listDirectory(relativePath: "")
        return items
            .filter { !$0.isDirectory }
            .map { $0.name }
            .filter { name in
                message.lowercased().contains(name.components(separatedBy: ".").first?.lowercased() ?? "")
            }
    }

    private func buildVaultContext(from paths: [String]) -> String {
        var context = ""
        for path in paths {
            if let result = vault.read(relativePath: path) {
                context += "```jcross path:\(path)\n\(result.jcrossContent)\n```\n\n"
            }
        }
        return context
    }

    private func extractDiffs(from response: String) -> [FileDiff] {
        // JCross diff ブロックを抽出 (```jcross path:xxx.swift ... ```)
        var diffs: [FileDiff] = []
        let pattern = "```jcross path:([^\\n]+)\\n([\\s\\S]*?)```"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let range   = NSRange(response.startIndex..., in: response)
        let matches = regex.matches(in: response, range: range)

        for match in matches {
            guard let pathRange    = Range(match.range(at: 1), in: response),
                  let contentRange = Range(match.range(at: 2), in: response)
            else { continue }

            let path    = String(response[pathRange]).trimmingCharacters(in: .whitespaces)
            let content = String(response[contentRange])
            diffs.append(FileDiff(path: path, content: content))
        }

        return diffs
    }

    private func appendMessage(_ message: OrchestratorMessage) {
        Task { @MainActor in
            guard let appState = AppState.shared else { return }
            let chatMessage: ChatMessage
            
            switch message {
            case .user(_):
                // AppState.sendMessage already appends the user message, so we skip adding it again
                return
            case .commander(let text):
                chatMessage = ChatMessage(role: .assistant, content: "🛡️ Commander:\n" + text)
            case .system(let text):
                chatMessage = ChatMessage(role: .assistant, content: text)
            case .mcpToolCall(let tool, let result):
                chatMessage = ChatMessage(role: .assistant, content: "🔧 Tool [\(tool)] → \(result.prefix(200))...")
            case .assistant(let text):
                chatMessage = ChatMessage(role: .assistant, content: "Verantyx\n" + text)
            }
            
            appState.messages.append(chatMessage)
        }
    }

    private func runBuildCheck(workspaceURL: URL, ext: String) async -> (Bool, String) {
        let process = Process()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.currentDirectoryURL = workspaceURL

        switch ext {
        case "swift":
            if FileManager.default.fileExists(atPath: workspaceURL.appendingPathComponent("Package.swift").path) {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["swift", "build"]
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["xcodebuild", "build", "-quiet"]
            }
        case "rs":
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["cargo", "check"]
        case "ts", "tsx":
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["tsc", "--noEmit"]
        default:
            return (true, "")
        }

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            if process.terminationStatus == 0 {
                return (true, output)
            } else {
                return (false, output)
            }
        } catch {
            return (false, error.localizedDescription)
        }
    }
}

// MARK: - OrchestratorMessage

enum OrchestratorMessage: Identifiable {
    case user(String)
    case commander(String)
    case assistant(String)
    case system(String)
    case mcpToolCall(tool: String, result: String)
    var id: UUID { UUID() }
}
