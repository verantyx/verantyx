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

    /// Compress conversation when it exceeds this many characters (~4000 tokens)
    private let compressThreshold = 16_000

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
        onProgress: @escaping @Sendable (LoopEvent) async -> Void
    ) async {

        var currentWorkspace = workspaceURL
        var conversation: [(role: String, content: String)] = []
        var turn = 0

        // ── Safety state ──────────────────────────────────────────────────
        /// Circuit breaker: rolling hash of last N raw responses (AI Priority)
        var recentResponseHashes: [Int] = []
        /// Yield counter: consecutive turns where AI only called tools (Human Mode)
        var consecutiveToolOnlyTurns = 0
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
        let archiveSection = SessionMemoryArchiver.shared
            .buildArchiveInjection(topK: 5, relevantTo: instruction)

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

        let systemPrompt = """
        \(AgentToolParser.toolInstructions)
        \(loopRules)
        \(memorySection)
        \(archiveSection)
        \(selfEvoContext)
        \(isWorkspaceless ? "\nNOTE: No workspace is open. If the task requires a project, create one with [WORKSPACE:] and [MKDIR:]." : "")
        \(contextFile.map { "CURRENT FILE (\(contextFileName ?? "file")):\n```\n\($0.prefix(6000))\n```" } ?? "")
        """

        conversation.append((role: "system", content: systemPrompt))
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

            // ── Call LLM ─────────────────────────────────────────────────
            let prompt = buildConversationPrompt(conversation)
            guard let rawResponse = await callModel(
                prompt: prompt,
                modelStatus: modelStatus,
                activeModel: activeModel
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

            if !cleanText.isEmpty {
                await onProgress(.aiMessage(cleanText))
            }

            // If no tools → conversational answer → done
            if tools.isEmpty {
                consecutiveToolOnlyTurns = 0
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

    // MARK: - LLM call

    private func callModel(prompt: String, modelStatus: AppState.ModelStatus, activeModel: String) async -> String? {
        switch modelStatus {
        case .ollamaReady(let model):
            return await OllamaClient.shared.generate(
                model: model, prompt: prompt, maxTokens: 3072, temperature: 0.15
            )
        case .ready:
            return "MLX not connected. Please use Ollama."
        default:
            return nil
        }
    }

    // MARK: - Conversation builder

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
    case aiMessage(String)
    case toolCall(AgentToolCall)
    case toolResult(AgentToolCall)
    case workspaceChanged(URL)
    case done(message: String, workspace: URL?)
    case error(String)
}
