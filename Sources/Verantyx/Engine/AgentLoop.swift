import Foundation

// MARK: - AgentLoop
// Multi-turn autonomous agent execution loop.
// Enables: "create a Python calculator" → scaffold → run → verify → done
//
// Loop flow:
//  1. Build prompt (instruction + cortex memory + file context)
//  2. Call LLM
//  3. Parse tool calls from response
//  4. Execute tools (MKDIR, WRITE_FILE, RUN, WORKSPACE)
//  5. Feed results back → repeat until [DONE] or safety gate
//
// ── Turn Limit Policy ──────────────────────────────────────────────────────
//  • AI Priority Mode : UNLIMITED turns. Circuit breaker kills loops where
//    AI repeats the exact same tool call 3 times in a row (hash比較).
//  • Human Mode       : UNLIMITED turns. After 5 consecutive unanswered tool
//    calls, AI must emit a Yield — a status report asking the user to confirm.
//
// ── OOM Prevention ────────────────────────────────────────────────────────
//  When conversation grows beyond COMPRESS_THRESHOLD chars, old turns are
//  offloaded to CortexEngine and pruned from the live context window.

actor AgentLoop {

    static let shared = AgentLoop()
    private let executor = AgentToolExecutor()

    // ── Safety gates (not a hard turn limit) ──────────────────────────────
    /// AI Priority: abort if the last N AI outputs are identical (stuck loop)
    private let circuitBreakerWindow = 3

    /// Human Mode: after this many consecutive tool-only turns, emit a Yield
    private let yieldAfterToolTurns = 5

    // compressThreshold is now per-model (from ModelProfile)

    // MARK: - Main loop

    func run(
        instruction: String,
        contextFile: String? = nil,
        contextFileName: String? = nil,
        workspaceURL: URL?,
        modelStatus: AppState.ModelStatus,
        activeModel: String,
        cortex: CortexEngine?,
        selfFixMode: Bool = false,
        isAIPriority: Bool = false,   // ←← drives turn policy
        memoryLayer: JCrossLayer = .l2,   // ➤ cross-session injection depth
        isFirstSession: Bool = false,         // ➤ inject self-awareness task on first turn
        onProgress: @escaping @Sendable (LoopEvent) async -> Void
    ) async {

        var currentWorkspace = workspaceURL
        var conversation: [(role: String, content: String)] = []
        var turn = 0

        // ── Model tier detection ──────────────────────────────────────────
        let profile = ModelProfileDetector.detect(modelId: activeModel)
        let compressThreshold = profile.tier.compressThreshold
        await onProgress(.aiMessage(
            "🤖 モデルプロファイル: \(activeModel) → \(profile.tier.displayName) | " +
            "Max tokens: \(profile.tier.maxTokens) | Temp: \(profile.tier.temperature)"
        ))

        // ── Safety state ──────────────────────────────────────────────────
        /// Circuit breaker: rolling hash of last N raw responses (AI Priority)
        var recentResponseHashes: [Int] = []
        /// Yield counter: consecutive turns where AI only called tools (Human Mode)
        var consecutiveToolOnlyTurns = 0
        /// IDE Fix sandbox: consecutive blocked tool calls (loop circuit breaker)
        var consecutiveBlockedCalls = 0
        /// Total chars in conversation (for OOM guard)
        var totalConversationChars = 0

        // ── Build initial system prompt ───────────────────────────────────
        let memorySection = await cortex?.buildMemoryPrompt(for: instruction) ?? ""
        let isWorkspaceless = workspaceURL == nil

        // ── Self-evolution context ────────────────────────────────────────
        let selfEvoContext: String
        if selfFixMode {
            let nodesEmpty = await MainActor.run { SelfEvolutionEngine.shared.sourceNodes.isEmpty }
            if nodesEmpty {
                await onProgress(.aiMessage("🔍 IDE ソースを自動インデックス中…"))
                await SelfEvolutionEngine.shared.indexSourceTree()
            }

            selfEvoContext = await MainActor.run {
                let nodes = SelfEvolutionEngine.shared.sourceNodes
                if nodes.isEmpty {
                    return """

## SELF-FIX MODE (Index not found)
The source could not be indexed. Please:
1. Open the VerantyxIDE folder as workspace (Cmd+Shift+O)
2. Click [Index Source] in the Self-Evolution panel (⟳ icon)
Then try again.
Do NOT run ls or shell commands.
"""
                }
                let indexSummary = nodes.prefix(60).map { n in
                    "  • \(n.relativePath) — \(n.summary)"
                }.joined(separator: "\n")
                return """

## SELF-FIX MODE ACTIVE ⚠️

You are in SELF-FIX mode. The user has explicitly requested that you modify
the Verantyx IDE's own source code to address their request.

The IDE source is indexed. Key files:
\(indexSummary)

Instructions:
1. Identify the relevant Swift file(s) from the index above.
2. Output the COMPLETE modified file content using EXACTLY this format:

[PATCH_FILE: Sources/Verantyx/Views/ExampleView.swift]
```swift
// complete new file content here
```

3. You may output multiple PATCH_FILE blocks if needed.
4. Do NOT run `ls`, `find`, or any shell commands — all files are listed above.
5. The IDE will detect PATCH_FILE blocks and show them in the Self-Evolution panel.
6. After outputting patches, briefly explain what you changed and why.

For non-code output (HTML, diagrams, etc.) use <artifact type="html"> tags.
"""
            }
        } else {
            selfEvoContext = ""
        }

        // ── Archived session memory (JCross) ─────────────────────────────
        let archiveSection = SessionMemoryArchiver.shared.buildCrossSessionInjection(
            topK: 5,
            layer: memoryLayer
        )

        // ── Mode-specific loop rules (injected into system prompt) ────────
        let loopRules: String
        if isAIPriority {
            loopRules = """

## LOOP POLICY — AI Priority Mode (Unlimited)
- You have NO turn limit. Keep working until [DONE].
- Call tools as many times as needed without stopping.
- Only stop when the task is truly complete.
- Do NOT apologize or ask permission mid-task; just keep going.
"""
        } else {
            loopRules = """

## LOOP POLICY — Human Mode (Unlimited + Yield)
- You have NO turn limit. Keep working until [DONE].
- However, if you have called tools 5 times in a row without resolving the issue,
  you MUST emit a Yield: stop tool calls and write a brief status report to the user
  explaining what you tried, what failed, and what decision you need from them.
  Example: "I've tried X and Y. The build still fails because Z. Should I try A or B?"
- After the user replies, continue working.
"""
        }

        // Use tier-appropriate system prompt (nano gets a simplified version)
        let contextSection: String
        if let file = contextFile {
            let limit = profile.tier == .nano ? 2000 : 6000
            let name  = contextFileName ?? "file"
            contextSection = "CURRENT FILE (\(name)):\n```\n\(file.prefix(limit))\n```"
        } else {
            contextSection = ""
        }
        // ── Capture live MCP tool snapshot + build profile system prompt ─────
        // MCPEngine is @MainActor — hop over to grab the snapshot safely.
        let profileSystemPrompt = await MainActor.run {
            let liveMCPTools = MCPEngine.shared.connectedTools
            return profile.systemPromptWith(mcpTools: liveMCPTools)
        }

        // ── Skill Library: boot index + retrieve relevant skills ─────────────
        // Load disk index once (no-op if already loaded), then retrieve top-3
        // skills that are semantically closest to the current instruction.
        // Only large/giant models get the skill section; nano/small ignore it.
        let skillSection: String
        if profile.tier == .large || profile.tier == .giant {
            await SkillLibrary.shared.loadIndex()
            let skillCount = await SkillLibrary.shared.count
            if skillCount > 0 {
                let relevantSkills = await SkillLibrary.shared.search(query: instruction, topK: 3)
                skillSection = SkillInjector.buildSection(skills: relevantSkills)
                if !relevantSkills.isEmpty {
                    await onProgress(.aiMessage(
                        "🔧 [SkillLib] \(relevantSkills.count) relevant skill(s) injected: " +
                        relevantSkills.map { $0.name }.joined(separator: ", ")
                    ))
                }
            } else {
                skillSection = SkillInjector.buildSection(skills: [])
            }
        } else {
            skillSection = ""
        }

        let systemPrompt = """
        \(profileSystemPrompt)
        \(loopRules)
        \(memorySection)
        \(archiveSection)
        \(skillSection)
        \(selfEvoContext)
        \(isWorkspaceless ? "\nNOTE: No workspace is open. If the task requires a project, create one with [WORKSPACE:] and [MKDIR:]." : "")
        \(contextSection)
        """

        conversation.append((role: "system", content: systemPrompt))


        // ── Self-awareness task (first session only) ──────────────────────
        // モデルが自分の能力を把握するための初回タスク
        if isFirstSession {
            let selfTask = profile.selfAwarenessTask
            conversation.append((role: "user", content: selfTask))
            let toolScope = profile.tier == .nano ? "simple file tools only" : "the full tool set"
            let responseStyle = profile.tier == .nano ? "very short" : "focused and structured"
            let ack = "I am \(activeModel), a \(profile.tier.displayName) model (\(Int(profile.parameterBillions))B params). " +
                      "I will use \(toolScope) and keep responses \(responseStyle)."
            conversation.append((role: "assistant", content: ack))
            await onProgress(.aiMessage("\u{1F9E0} [Self-Aware] \(ack)"))
        }

        conversation.append((role: "user",   content: instruction))
        totalConversationChars = systemPrompt.count + instruction.count

        await onProgress(.start(instruction: instruction))

        // ── Agent loop — no hard turn cap ─────────────────────────────────
        while true {
            turn += 1
            await onProgress(.thinking(turn: turn))

            // ── OOM guard: compress if balloon ──────────────────────────
            if totalConversationChars > compressThreshold {
                conversation = await compressConversation(
                    conversation,
                    cortex: cortex,
                    instruction: instruction
                )
                totalConversationChars = conversation.reduce(0) { $0 + $1.content.count }
                await onProgress(.aiMessage("🧠 [Memory] 会話履歴を圧縮してコンテキストをオフロードしました"))
            }

            // ── Call LLM (streaming) ──────────────────────────────────────
            guard let rawResponse = await callModel(
                conversation: conversation,
                modelStatus: modelStatus,
                activeModel: activeModel,
                profile: profile,
                onProgress: onProgress    // ← onToken コールバックで .streamToken を発行
            ) else {
                await onProgress(.error("Model returned nil response"))
                return
            }

            // ── AI Priority circuit breaker ───────────────────────────────
            if isAIPriority {
                let hash = rawResponse.hashValue
                recentResponseHashes.append(hash)
                if recentResponseHashes.count > circuitBreakerWindow {
                    recentResponseHashes.removeFirst()
                }
                if recentResponseHashes.count == circuitBreakerWindow
                    && Set(recentResponseHashes).count == 1 {
                    let msg = "⚡ [Circuit Breaker] AIが同じ出力を\(circuitBreakerWindow)回繰り返しました。無限ループを検知して停止します。"
                    await onProgress(.error(msg))
                    await cortex?.remember(
                        key: "circuit_break_\(turn)",
                        value: "Loop at turn \(turn): \(rawResponse.prefix(100))",
                        importance: 0.9,
                        zone: .near
                    )
                    return
                }
            }

            // ── Store in cortex ───────────────────────────────────────────
            await cortex?.extractAndStore(from: rawResponse, userInstruction: instruction)

            // ── Parse tool calls ──────────────────────────────────────────
            let (tools, cleanText) = AgentToolParser.parse(from: rawResponse)

            // ── aiMessage emission strategy ──────────────────────────────
            // Ollama and MLX both use streaming (streamToken callbacks).
            // The UI bubble is already fully populated by the time callModel
            // returns. Emitting aiMessage(cleanText) AGAIN would cause the
            // AppState handler to overwrite the streaming bubble with the
            // parsed text — which appears as a duplicate on the first message.
            //
            // Rule: only emit aiMessage when the model does NOT stream tokens.
            //       Streaming models (Ollama, MLX) skip this step — the
            //       streaming bubble is already correct and complete.
            //       Non-streaming models (fallback .ready) must emit it.
            let isStreamingModel: Bool
            switch modelStatus {
            case .ollamaReady, .mlxReady: isStreamingModel = true
            default:                      isStreamingModel = false
            }

            if !cleanText.isEmpty && !isStreamingModel {
                // Non-streaming path: emit the full response as a chat bubble
                await onProgress(.aiMessage(cleanText))
            }
            // For streaming models: aiMessage is intentionally skipped here.
            // The streaming bubble (populated by streamToken) remains as-is.
            // Tool-call annotations (if any) are shown via toolCall/toolResult.

            // ── Auto-register Artifact from AI response ────────────────────
            // Detects <artifact> tags or large code blocks and publishes them
            // to the ArtifactPanelView immediately after the response completes.
            if let artifact = ArtifactParser.extract(from: rawResponse) {
                await MainActor.run {
                    AppState.shared?.ingestArtifact(artifact)
                }
            }

            // If no tools → conversational answer → done
            if tools.isEmpty {
                consecutiveToolOnlyTurns = 0
                // Pass cleanText for the .done handler's duplicate-guard check
                await onProgress(.done(message: cleanText, workspace: currentWorkspace))
                return
            }

            // ── Execute tools ─────────────────────────────────────────────
            var toolResults: [String] = []
            var isDone = false

            for tool in tools {
                let call = AgentToolCall(tool: tool)
                await onProgress(.toolCall(call))

                var result: String

                // ── IDE Fix sandbox ────────────────────────────────────
                // Allowed: readFile, gitCommit, applyPatch, buildIDE, restartIDE,
                //          jcross*, askHuman, done.
                // Blocked: listDir, runCommand, browse, search, setWorkspace…
                // Strategy: on FIRST block in a turn → break loop, inject
                //   correction DIRECTLY into conversation so the model sees it.
                //   consecutiveBlockedCalls counts turns (not tools within a turn).
                //   After 3 blocked turns → hard-stop.
                if selfFixMode && isForbiddenInSelfFixMode(tool) {
                    consecutiveBlockedCalls += 1

                    let blockedUI = AgentToolCall(tool: tool, result: "🚫 BLOCKED (IDE Fix Sandbox)", succeeded: false)
                    await onProgress(.toolResult(blockedUI))

                    if consecutiveBlockedCalls >= 3 {
                        // Hard-stop: model is definitively stuck
                        await onProgress(.aiMessage("""
                        ⚠️ **IDE Fix モード: ループを検知して停止しました**

                        禁止ツールを\(consecutiveBlockedCalls)回連続で呼び出したため安全に停止しました。
                        [READ: Sources/…/File.swift] でファイルを読み、[APPLY_PATCH] でパッチを当ててください。
                        """))
                        await onProgress(.done(message: "IDE Fix sandbox ループ防止", workspace: currentWorkspace))
                        return
                    }
                    // Inject correction DIRECTLY into conversation so the model
                    // sees it as context in the very next turn — not just a tool result.
                    let correction = """
                    [IDE Fix Sandbox] 禁止ツールを呼び出しました (通算 \(consecutiveBlockedCalls)回): \(call.displayLabel)

                    IDE Fix モードで許可されているツール:
                      [READ: Sources/.../File.swift]       ← ファイル内容を読む
                      [GIT_COMMIT: msg]                    ← 変更前にバックアップ
                      [APPLY_PATCH: Sources/.../File.swift] ← 修正を適用
                      [BUILD_IDE]                          ← ビルド検証
                      [DONE: msg]                          ← 完了

                    [LIST_DIR], [RUN], [SEARCH], [BROWSE], [WORKSPACE] は使用不可です。
                    今すぐ [READ: 対象ファイルパス] で始めてください。
                    """

                    conversation.append((role: "assistant", content: rawResponse))
                    conversation.append((role: "user", content: correction))
                    toolResults.append("\(call.displayLabel) → BLOCKED #\(consecutiveBlockedCalls)")

                    // Break the for-tool loop: skip remaining tools in this batch.
                    // The while loop continues, calling the model with the correction injected.
                    isDone = false
                    break
                } else {
                    consecutiveBlockedCalls = 0  // Any allowed tool resets the counter
                }

                if case .setWorkspace(let path) = tool {
                    let wsURL = URL(fileURLWithPath: path)
                    currentWorkspace = wsURL
                    await onProgress(.workspaceChanged(wsURL))
                    result = await executor.execute(tool, workspaceURL: currentWorkspace)
                } else if case .done(let msg) = tool {
                    result = await executor.execute(tool, workspaceURL: currentWorkspace)
                    await onProgress(.done(message: msg, workspace: currentWorkspace))
                    isDone = true
                } else {
                    result = await executor.execute(tool, workspaceURL: currentWorkspace)
                }

                let completedCall = AgentToolCall(tool: tool, result: result, succeeded: !result.hasPrefix("✗"))
                await onProgress(.toolResult(completedCall))
                toolResults.append("\(call.displayLabel) → \(result)")
            }

            if isDone { return }

            // ── Yield check (Human Mode) ──────────────────────────────────
            consecutiveToolOnlyTurns += 1
            if !isAIPriority && consecutiveToolOnlyTurns >= yieldAfterToolTurns {
                consecutiveToolOnlyTurns = 0
                let yieldMsg = """
                ⏸ [Yield — ターン\(turn)] \(yieldAfterToolTurns)回連続でツールを呼び出しましたが、\
                まだ完了していません。現状を報告します：

                \(toolResults.suffix(3).joined(separator: "\n"))

                次のステップについて確認してください。続行しますか？または別のアプローチを指定してください。
                """
                await onProgress(.aiMessage(yieldMsg))
                // Pause — wait for user's next message via the normal chat flow
                return
            }

            // ── Feed results back → next turn ────────────────────────────
            let toolResultSummary = "TOOL RESULTS:\n" + toolResults.map { "  \($0)" }.joined(separator: "\n")
            conversation.append((role: "assistant", content: rawResponse))
            conversation.append((role: "user",      content: toolResultSummary + "\n\nContinue if there's more to do, or [DONE] if complete."))
            totalConversationChars += rawResponse.count + toolResultSummary.count
        }
    }

    // MARK: - IDE Fix sandbox helpers

    /// Returns true for tools that are BLOCKED when selfFixMode is active.
    /// Allow-list design: only the tools needed for a patch workflow are permitted.
    /// - READ is required to understand current file state before patching.
    /// - GIT_COMMIT creates a safety checkpoint before applying changes.
    /// - Everything else (listDir, runCommand, browse, search…) is blocked.
    private func isForbiddenInSelfFixMode(_ tool: AgentTool) -> Bool {
        switch tool {
        // Self-Fix pipeline — always allowed
        case .applyPatch, .buildIDE, .restartIDE:           return false
        // File reading: agent must read before it can write a correct patch
        case .readFile:                                      return false
        // Git commit: safety backup before destructive patch
        case .gitCommit:                                     return false
        // Memory / human-loop / completion
        case .jcrossQuery, .jcrossStore, .askHuman, .done:  return false
        // Skill library: safe — only writes to ~/.verantyx/skills/
        case .forgeSkill, .useSkill:                        return false
        // Everything else: blocked
        default: return true
        }
    }

    // MARK: - Context compression (OOM guard)

    /// Compress old conversation turns into CortexEngine, then prune them.
    /// Keeps the last 4 turns intact (most recent context).
    private func compressConversation(
        _ conversation: [(role: String, content: String)],
        cortex: CortexEngine?,
        instruction: String
    ) async -> [(role: String, content: String)] {
        guard conversation.count > 6 else { return conversation }

        let keepCount = 4   // always keep the latest 4 entries
        let toCompress = Array(conversation.dropFirst(1).dropLast(keepCount)) // skip system prompt
        let toKeep     = Array(conversation.prefix(1) + conversation.suffix(keepCount))

        // Build a text digest of what's being dropped
        let digest = toCompress.map { turn in
            let prefix = turn.role == "assistant" ? "A" : "U"
            return "\(prefix): \(String(turn.content.prefix(150)))"
        }.joined(separator: " | ")

        await cortex?.remember(
            key: "loop_compression_t\(toCompress.count)",
            value: digest,
            importance: 0.8,
            zone: .near
        )

        // Insert a compression notice so the model knows context was trimmed
        var result = toKeep
        let notice = (
            role: "user",
            content: "🧠 [Context trimmed — \(toCompress.count) older turns offloaded to memory. Key task: \(instruction.prefix(100))]"
        )
        result.insert(notice, at: 1)
        return result
    }

    // MARK: - LLM call (streaming)
    // openclaw の StreamFn パターンを参考:
    //   - Ollama: stream:true + NDJSON + onToken コールバック
    //   - Anthropic: SSE + content_block_delta → text_delta
    // AgentLoop では UI へのリアルタイム配信のために onProgress(.streamToken) を emit

    private func callModel(
        conversation: [(role: String, content: String)],
        modelStatus: AppState.ModelStatus,
        activeModel: String,
        profile: ModelProfile = ModelProfileDetector.detect(modelId: "default"),
        onProgress: @escaping @Sendable (LoopEvent) async -> Void
    ) async -> String? {
        switch modelStatus {

        case .ollamaReady(let model):
            // multi-turn 会話配列を直接渡す（prompt string に変換不要）
            return await OllamaClient.shared.generateConversation(
                model: model,
                messages: conversation,
                maxTokens: profile.tier.maxTokens,
                temperature: profile.tier.temperature,
                onToken: { token in
                    Task { await onProgress(.streamToken(token)) }
                }
            )

        case .anthropicReady(let model, _):
            // system prompt を分離
            let systemContent = conversation.first(where: { $0.role == "system" })?.content ?? ""
            let chatMessages  = conversation.filter { $0.role != "system" }
            let isThinking    = model.contains("3-7") || model.contains("claude-3-7")
            return await AnthropicClient.shared.generate(
                model: model,
                systemPrompt: systemContent,
                messages: chatMessages,
                maxTokens: max(profile.tier.maxTokens, 8096),  // Anthropic は大きめに
                temperature: profile.tier.temperature,
                enableThinking: isThinking,
                onToken: { token in
                    Task { await onProgress(.streamToken(token)) }
                },
                onThinking: { _ in }  // thinking は今は捨てる（将来 .thinkToken 追加）
            )

        case .mlxReady:
            // ── MLX direct in-process inference ────────────────────────────
            // Convert conversation array → a single prompt string, then stream
            // tokens via MLXRunner. Streaming deltas go to UI via onProgress,
            // but the RETURN value uses the authoritative onFinish payload
            // (= result.output from MLXLMCommon.generate) to guarantee the
            // rawResponse is never garbled by delta accumulation issues.
            let prompt = buildConversationPrompt(conversation)
            final class StringBox: @unchecked Sendable { var value = "" }
            let authoritativeOutput = StringBox()
            do {
                try await MLXRunner.shared.streamGenerateTokens(
                    prompt: prompt,
                    maxTokens: profile.tier.maxTokens,
                    temperature: profile.tier.temperature,
                    onToken: { @Sendable piece in
                        // Streaming deltas → UI display only
                        Task { await onProgress(.streamToken(piece)) }
                    },
                    onFinish: { @Sendable fullText in
                        // Authoritative output from MLXLMCommon.generate
                        authoritativeOutput.value = fullText
                    }
                )
            } catch {
                await onProgress(.error("MLX error: \(error.localizedDescription)"))
                return nil
            }
            return authoritativeOutput.value.isEmpty ? nil : authoritativeOutput.value

        case .ready:
            return "MLX (local) is active — use the MLX tab in the model picker."

        default:
            return nil
        }
    }

    // MARK: - Conversation builder (Ollama用フォールバック)
    // NOTE: Ollama generateConversation() は messages を直接受け取るため
    // このメソッドは Anthropic 以外では不要になった。互換性のため残す。

    private func buildConversationPrompt(_ conversation: [(role: String, content: String)]) -> String {
        conversation.map { turn in
            switch turn.role {
            case "system":    return "<system>\n\(turn.content)\n</system>"
            case "user":      return "<user>\n\(turn.content)\n</user>"
            case "assistant": return "<assistant>\n\(turn.content)\n</assistant>"
            default:          return turn.content
            }
        }.joined(separator: "\n\n") + "\n\n<assistant>"
    }
}

// MARK: - LoopEvent

enum LoopEvent: @unchecked Sendable {
    case start(instruction: String)
    case thinking(turn: Int)
    case streamToken(String)          // NEW: リアルタイムトークン（UIがダイレクト・ストリーミング表示用）
    case aiMessage(String)             // 完成テキストブロック
    case toolCall(AgentToolCall)
    case toolResult(AgentToolCall)
    case workspaceChanged(URL)
    case done(message: String, workspace: URL?)
    case error(String)
}
import Foundation

// MARK: - ModelProfile
// モデルの能力に基づいてシステムプロンプトと動作パラメータを自動調整する。
//
// 分類基準 (パラメータ数):
//   nano  : ~2B  (gemma4:e2b, gemma-mini, phi-mini など)
//   small : ~7B  (Mistral-7B, Qwen-7B など)
//   mid   : ~14B (Qwen-14B, gemma-3-12b など)
//   large : ~27B (gemma-3-27b, Qwen-32B など)
//   giant : ~70B+ (Llama-3-70B など)

// MARK: - ModelTier

enum ModelTier: String, Sendable {
    case nano   = "nano"    // ~2B  — 最小
    case small  = "small"   // ~7B  — 小型
    case mid    = "mid"     // ~12-14B — 中型
    case large  = "large"   // ~26-32B — 大型
    case giant  = "giant"   // ~70B+ — 最大

    // 使えるツールのサブセット（nano ほど少ない）
    var enabledToolCategories: Set<ToolCategory> {
        switch self {
        case .nano:
            // nano: ファイル操作のみ。Web/JCross/Gitは混乱するのでオフ
            return [.filesystem, .done]
        case .small:
            // small: ファイル + 単純な検索
            return [.filesystem, .web_simple, .done]
        case .mid:
            // mid: ほぼフル。JCrossとGitは除く
            return [.filesystem, .web_full, .done, .selffix]
        case .large, .giant:
            // large/giant: 全ツール有効
            return [.filesystem, .web_full, .jcross, .git, .human, .done, .selffix]
        }
    }

    var maxTokens: Int {
        switch self {
        case .nano:   return 1024
        case .small:  return 2048
        case .mid:    return 4096
        case .large:  return 8192   // gemma4 27B — raised from 3072 to avoid mid-sentence cutoff
        case .giant:  return 12288
        }
    }

    var compressThreshold: Int {
        switch self {
        case .nano:   return 4_000
        case .small:  return 8_000
        case .mid:    return 12_000
        case .large:  return 16_000
        case .giant:  return 24_000
        }
    }

    var temperature: Double {
        switch self {
        case .nano:   return 0.05  // 確定的に
        case .small:  return 0.1
        case .mid:    return 0.12
        case .large:  return 0.15
        case .giant:  return 0.2
        }
    }

    var displayName: String {
        switch self {
        case .nano:   return "Nano (~2B)"
        case .small:  return "Small (~7B)"
        case .mid:    return "Medium (~12B)"
        case .large:  return "Large (~27B)"
        case .giant:  return "Giant (70B+)"
        }
    }
}

enum ToolCategory {
    case filesystem, web_simple, web_full, jcross, git, human, done, selffix
}

// MARK: - ModelProfile

struct ModelProfile: Sendable {
    let modelId: String
    let tier: ModelTier
    let parameterBillions: Double
    let supportsThinkTags: Bool   // <think>...</think> 対応モデル

    // ── System prompt adapted to this model's capabilities ──────────────────
    var systemPrompt: String {
        switch tier {
        case .nano:
            return nanoPrompt
        case .small:
            return smallPrompt
        case .mid:
            return midPrompt
        case .large, .giant:
            return largePrompt
        }
    }

    // ── First-turn self-awareness message ────────────────────────────────────
    // モデルロード直後に AI 自身に自分の能力を伝えるプロンプト
    var selfAwarenessTask: String {
        """
        [SYSTEM: Model Capability Report]
        You are running as: \(modelId)
        Parameter scale: \(parameterBillions)B parameters (\(tier.displayName))
        Context window: ~\(tier.compressThreshold / 4) tokens
        Max output: \(tier.maxTokens) tokens per turn
        \(supportsThinkTags ? "Thinking: You can use <think>...</think> for internal reasoning." : "Thinking: Keep reasoning concise, no special tags.")

        \(tier == .nano ? nanoSelfNote : "")
        \(tier == .small ? smallSelfNote : "")
        \(tier == .mid ? midSelfNote : "")
        \(tier == .large || tier == .giant ? largeSelfNote : "")

        Acknowledge by describing in 1 sentence what you can and cannot do in this configuration.
        """
    }

    // MARK: - Tier-specific notes

    private var nanoSelfNote: String { """
        CONSTRAINTS: You are a nano model (~2B params). Your capabilities are limited.
        - Only use these tools: MKDIR, WRITE, READ, LIST_DIR, EDIT_LINES, RUN, DONE
        - Do NOT attempt multi-step reasoning chains — keep each response focused
        - If unsure, write a simple answer rather than using tools
        - One task at a time. Short responses only.
        """ }

    private var smallSelfNote: String { """
        CAPABILITIES: Small model (~7B). Good for single-file tasks and simple searches.
        - Use SEARCH for factual queries; avoid SEARCH_MULTI (too complex)
        - Keep reasoning under 3 steps per turn
        """ }

    private var midSelfNote: String { """
        CAPABILITIES: Medium model (~12B). Capable of multi-file tasks and web grounding.
        - Use SEARCH and BROWSE freely; avoid JCROSS_QUERY/STORE (not yet reliable)
        - You can use <think>...</think> for planning
        """ }

    private var largeSelfNote: String { """
        CAPABILITIES: Large model (~26B+). Full autonomous agent capabilities.
        - Use ALL tools including JCROSS, GIT_COMMIT, ASK_HUMAN
        - Follow the full ReAct 4-phase loop: OBSERVE → ACT → EVOLVE → CONSOLIDATE
        - You can handle complex multi-session, multi-file tasks autonomously
        """ }

    // MARK: - Tier prompts

    private var nanoPrompt: String { """
        You are VerantyxAgent (Nano). You are a small, fast AI assistant.
        Keep answers SHORT and FOCUSED. Use simple language.

        Available tools (use ONLY these):
        [LIST_DIR: path]     — list files in a directory
        [READ: path]         — read a file
        [MKDIR: path]        — create directory
        [WRITE: path]        — write file
        [EDIT_LINES: path]   — edit specific lines in a file
        [RUN: command]       — run a shell command
        [DONE: message]      — finish the task

        RULES:
        - ONE tool per turn maximum
        - Keep explanations under 3 sentences
        - If you don't know something, say "I don't know"
        - End every completed task with [DONE]
        """ }

    private var smallPrompt: String { """
        You are VerantyxAgent (Small). An efficient coding assistant.

        Available tools:
        [LIST_DIR: path]       — list directory
        [READ: path]           — read file
        [MKDIR: path]          — create directory
        [WRITE: path]          — write file
        [EDIT_LINES: path]     — partial file edit
        [RUN: command]         — shell command
        [SEARCH: query]        — web search
        [BROWSE: url]          — fetch URL
        [WORKSPACE: path]      — set workspace
        [DONE: message]        — finish

        RULES:
        - Check files before editing: LIST_DIR → READ → EDIT
        - Use SEARCH for recent/unknown info
        - Maximum 2 tools per turn
        - End with [DONE]
        """ }

    private var midPrompt: String { """
        You are VerantyxAgent (Medium). A capable autonomous coding assistant.

        Available tools:
        [LIST_DIR: path]       — list directory (tree)
        [READ: path]           — read file
        [MKDIR: path]          — create directory
        [WRITE: path]          — write whole file
        [EDIT_LINES: path]     — partial line edit
        [RUN: command]         — shell command
        [SEARCH: query]        — web search
        [SEARCH_MULTI: query]  — parallel multi-source search
        [BROWSE: url]          — fetch URL
        [APPLY_PATCH: path]    — patch IDE source
        [BUILD_IDE]            — compile IDE
        [WORKSPACE: path]      — set workspace
        [DONE: message]        — finish

        WORKFLOW:
        1. Explore: LIST_DIR → READ relevant files
        2. Plan: <think>what to change</think>
        3. Act: EDIT_LINES or APPLY_PATCH
        4. Verify: RUN or BUILD_IDE
        5. Done: DONE

        Use SEARCH_MULTI when you need current information.
        """ }

    private var largePrompt: String {
        // Returns the base prompt without MCP section.
        // For runtime injection use systemPromptWith(mcpTools:) from AgentLoop.
        AgentToolParser.buildPrompt(mcpTools: [])
    }

    /// Returns the system prompt with live MCP tools injected.
    /// Call this from @MainActor context (e.g., AgentLoop.run).
    @MainActor
    func systemPromptWith(mcpTools: [MCPTool]) -> String {
        switch tier {
        case .nano:  return nanoPrompt
        case .small: return smallPrompt
        case .mid:   return midPrompt
        case .large, .giant:
            return AgentToolParser.buildPrompt(mcpTools: mcpTools)
        }
    }
}

// MARK: - ModelProfileDetector

enum ModelProfileDetector {

    /// モデルIDからパラメータ数とティアを推定する
    static func detect(modelId: String) -> ModelProfile {
        let id = modelId.lowercased()

        // ── Giant 70B+ (must check BEFORE large to avoid substring collision) ──
        let giantKeywords = ["70b", "72b", "65b", "llama-3-70", "qwen2.5-72",
                             "mixtral-8x7", "mixtral-8x22", "deepseek-r1-70"]
        if giantKeywords.contains(where: { id.contains($0) }) {
            return ModelProfile(modelId: modelId, tier: .giant,
                                parameterBillions: 70.0, supportsThinkTags: true)
        }

        // ── Large ~26-32B (check BEFORE small/mid to stop "6b" in "26b" matching) ──
        let largeKeywords = ["26b", "27b", "32b", "gemma-3-27", "gemma-4-26",
                             "gemma4-26", "qwen2.5-32", "deepseek-r1-32",
                             // Ollama short names that represent large models
                             "gemma4:26", "gemma4:27", "gemma3:27", "gemma3:26"]
        if largeKeywords.contains(where: { id.contains($0) }) {
            let supportsThink = id.contains("gemma-4") || id.contains("gemma4") || id.contains("think")
            return ModelProfile(modelId: modelId, tier: .large,
                                parameterBillions: 26.0, supportsThinkTags: supportsThink)
        }

        // ── Gemma4 / gemma3 base names with no B suffix (Ollama: "gemma4:26b") ──
        // Handle case where Ollama sends "gemma4:26b" → already caught above via "26b"
        // But "gemma4" alone (no size) → treat as large
        if (id.hasPrefix("gemma4") || id.hasPrefix("gemma-4")) && !id.contains("2b") && !id.contains("e2b") {
            let supportsThink = true
            return ModelProfile(modelId: modelId, tier: .large,
                                parameterBillions: 26.0, supportsThinkTags: supportsThink)
        }

        // ── Mid ~12-14B ───────────────────────────────────────────────────────
        let midKeywords = ["12b", "13b", "14b", "gemma-3-12", "codellama-13",
                           "qwen2.5-14", "deepseek-r1-14"]
        if midKeywords.contains(where: { id.contains($0) }) {
            return ModelProfile(modelId: modelId, tier: .mid,
                                parameterBillions: 12.0, supportsThinkTags: true)
        }

        // ── Nano ~2B (check before small to avoid "2b" matching "12b") ────────
        // Note: checked after large/mid so "e2b" in "gemma4:e2b" doesn't hit large
        let nanoKeywords = ["e2b", ":2b", "-2b", "1b", "0.5b", "nano", "mini",
                            "tiny", "small-2b", "1.5b", "phi-mini", "gemma-mini",
                            "gemma2b", "gemma-2b"]
        if nanoKeywords.contains(where: { id.contains($0) }) {
            return ModelProfile(modelId: modelId, tier: .nano,
                                parameterBillions: 2.0, supportsThinkTags: false)
        }

        // ── Small ~7B ────────────────────────────────────────────────────────
        let smallKeywords = ["7b", "8b", "6b", "mistral-7", "qwen-7", "llama-3-8b",
                             "codellama-7", "deepseek-r1-7",
                             // phi-4 is ~14B but behaves like small in terms of context
                             "phi-4", "phi4"]
        if smallKeywords.contains(where: { id.contains($0) }) {
            return ModelProfile(modelId: modelId, tier: .small,
                                parameterBillions: 7.0, supportsThinkTags: id.contains("think"))
        }

        // ── Default: treat as Large ────────────────────────────────────────────
        return ModelProfile(modelId: modelId, tier: .large,
                            parameterBillions: 26.0, supportsThinkTags: false)
    }
}
