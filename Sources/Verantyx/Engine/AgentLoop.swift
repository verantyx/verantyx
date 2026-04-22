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
//  5. Feed results back → repeat until [DONE] or max turns

actor AgentLoop {

    static let shared = AgentLoop()
    private let executor = AgentToolExecutor()
    let maxTurns = 12  // safety limit

    // MARK: - Main loop

    func run(
        instruction: String,
        contextFile: String? = nil,
        contextFileName: String? = nil,
        workspaceURL: URL?,
        modelStatus: AppState.ModelStatus,
        activeModel: String,
        cortex: CortexEngine?,
        onProgress: @escaping @Sendable (LoopEvent) async -> Void
    ) async {

        var currentWorkspace = workspaceURL
        var converstation: [(role: String, content: String)] = []
        var turn = 0

        // ── Build initial system prompt ──────────────────────────────
        let memorySection = await cortex?.buildMemoryPrompt(for: instruction) ?? ""
        let isWorkspaceless = workspaceURL == nil

        // ── Self-evolution context (IDE source awareness) ─────────────
        // Auto-index if: user is asking about the IDE AND nodes not yet loaded
        let looksLikeSelfMod = instruction.localizedCaseInsensitiveContains("fix")
                            || instruction.localizedCaseInsensitiveContains("change")
                            || instruction.localizedCaseInsensitiveContains("add feature")
                            || instruction.localizedCaseInsensitiveContains("modify")
                            || instruction.localizedCaseInsensitiveContains("update")
                            || instruction.localizedCaseInsensitiveContains("improve")
                            || instruction.localizedCaseInsensitiveContains("resize")
                            || instruction.localizedCaseInsensitiveContains("width")
                            || instruction.localizedCaseInsensitiveContains("window")
                            || instruction.localizedCaseInsensitiveContains("UI")
                            || instruction.localizedCaseInsensitiveContains("pane")

        let nodesEmpty = await MainActor.run { SelfEvolutionEngine.shared.sourceNodes.isEmpty }
        if looksLikeSelfMod && nodesEmpty {
            await onProgress(.aiMessage("🔍 IDE ソースをインデックス中…（初回のみ）"))
            await SelfEvolutionEngine.shared.indexSourceTree()
        }

        let selfEvoContext = await MainActor.run {
            let nodes = SelfEvolutionEngine.shared.sourceNodes
            if nodes.isEmpty {
                // Soft fallback: tell AI not to explore filesystem
                return """

## IDE Self-Modification Note
If the user is asking you to fix or change the IDE itself:
- Do NOT run `ls` or shell commands to explore the source.
- Instead, ask the user to click [Index Source] in the Self-Evolution panel (⟳ icon in Activity Bar).
- Once indexed, you will receive the full file list and can output [PATCH_FILE:] blocks.
"""
            }
            let indexSummary = nodes.prefix(60).map { n in
                "  • \(n.relativePath) — \(n.summary)"
            }.joined(separator: "\n")
            return """

## SELF-EVOLUTION (IDE Source Awareness)

You are operating INSIDE the Verantyx IDE and can modify its own Swift source code.
The IDE source is indexed. Key files:
\(indexSummary)

When the user asks you to modify the IDE itself (add feature, change UI, etc.):
1. Identify the relevant Swift file(s) from the index above.
2. Output the COMPLETE modified file content using this format:

[PATCH_FILE: Sources/Verantyx/Views/ExampleView.swift]
```swift
// ... complete new file content ...
```

The IDE will detect these PATCH_FILE blocks, register them as FilePatch objects,
and show them in the Self-Evolution panel for Apply & Rebuild.

IMPORTANT: Do NOT run shell commands like ls or find to explore the source.
All relevant files are already listed above.

For artifact output use <artifact type="html"> tags.
"""
        }

        let systemPrompt = """
        \(AgentToolParser.toolInstructions)
        \(memorySection)
        \(selfEvoContext)
        \(isWorkspaceless ? "\nNOTE: No workspace is open. If the task requires a project, create one with [WORKSPACE:] and [MKDIR:]." : "")
        \(contextFile.map { "CURRENT FILE (\(contextFileName ?? "file")):\n```\n\($0.prefix(6000))\n```" } ?? "")
        """

        converstation.append((role: "system", content: systemPrompt))
        converstation.append((role: "user",   content: instruction))

        await onProgress(.start(instruction: instruction))

        // ── Agent loop ───────────────────────────────────────────────
        while turn < maxTurns {
            turn += 1

            await onProgress(.thinking(turn: turn))

            // Call LLM
            let prompt = buildConversationPrompt(converstation)
            guard let rawResponse = await callModel(
                prompt: prompt,
                modelStatus: modelStatus,
                activeModel: activeModel
            ) else {
                await onProgress(.error("Model returned nil response"))
                return
            }

            // Store in cortex
            await cortex?.extractAndStore(from: rawResponse, userInstruction: instruction)

            // Parse tool calls
            let (tools, cleanText) = AgentToolParser.parse(from: rawResponse)

            // Emit the AI's explanation text
            if !cleanText.isEmpty {
                await onProgress(.aiMessage(cleanText))
            }

            // If no tools → done (conversational answer)
            if tools.isEmpty {
                await onProgress(.done(message: cleanText, workspace: currentWorkspace))
                return
            }

            // Execute tools sequentially
            var toolResults: [String] = []
            var isDone = false

            for tool in tools {
                let call = AgentToolCall(tool: tool)
                await onProgress(.toolCall(call))

                var result: String

                // Handle workspace switch (needs to update currentWorkspace on MainActor side)
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

            // Feed results back for next turn
            let toolResultSummary = "TOOL RESULTS:\n" + toolResults.map { "  \($0)" }.joined(separator: "\n")
            converstation.append((role: "assistant", content: rawResponse))
            converstation.append((role: "user",      content: toolResultSummary + "\n\nContinue if there's more to do, or [DONE] if complete."))
        }

        await onProgress(.error("Max turns (\(maxTurns)) reached without [DONE]"))
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
