import Foundation

// MARK: - AgentEngine
// Orchestrates: instruction + context → LLM inference → (explanation, modifiedCode)

struct AgentResult {
    var explanation: String
    var diff: String?          // full modified file content (nil if no code change)
}

actor AgentEngine {

    // MARK: - Main entry point

    func process(
        instruction: String,
        contextFileContent: String?,
        contextFileName: String?,
        modelStatus: AppState.ModelStatus,
        activeOllamaModel: String
    ) async -> AgentResult {

        let prompt = buildPrompt(
            instruction: instruction,
            fileContent: contextFileContent,
            fileName: contextFileName
        )

        let rawOutput: String?
        switch modelStatus {
        case .ollamaReady(let model):
            rawOutput = await OllamaClient.shared.generate(
                model: model,
                prompt: prompt,
                maxTokens: 2048,
                temperature: 0.1
            )
        case .ready:
            // MLX path — will be connected in Phase 2
            rawOutput = await callMLX(prompt: prompt)
        default:
            return AgentResult(
                explanation: "⚠️ No model loaded. Use the model picker to connect Ollama or download a model.",
                diff: nil
            )
        }

        guard let output = rawOutput, !output.isEmpty else {
            return AgentResult(explanation: "⚠️ Model returned empty response. Try again.", diff: nil)
        }

        return parseOutput(output, originalContent: contextFileContent)
    }

    // MARK: - Prompt builder

    private func buildPrompt(
        instruction: String,
        fileContent: String?,
        fileName: String?
    ) -> String {
        let codeSection: String
        if let content = fileContent, !content.isEmpty, let name = fileName {
            codeSection = """
            FILE: \(name)
            ```
            \(content.prefix(8000))
            ```

            """
        } else {
            codeSection = ""
        }

        return """
        You are Verantyx, an expert AI coding assistant running locally on Apple Silicon.

        Your task:
        1. Read the user's instruction carefully.
        2. If code changes are needed, output the COMPLETE modified file in a fenced code block.
        3. After the code block, write a brief explanation of what you changed and why.
        4. If no code changes are needed, just answer conversationally.

        RULE: When outputting modified code, output the ENTIRE file — not just the changed lines.
        This allows the diff view to highlight exactly what changed.

        \(codeSection)USER INSTRUCTION: \(instruction)

        YOUR RESPONSE:
        """
    }

    // MARK: - Output parser

    private func parseOutput(_ raw: String, originalContent: String?) -> AgentResult {
        // Extract fenced code block (```...```)
        let pattern = #"```(?:\w+)?\n([\s\S]*?)```"#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
           let range = Range(match.range(at: 1), in: raw) {

            let modifiedCode = String(raw[range])
            // Explanation = everything after the last ``` block
            let afterCode = raw.components(separatedBy: "```").last ?? ""
            let explanation = afterCode.trimmingCharacters(in: .whitespacesAndNewlines)

            // Only emit diff if content actually changed
            if let orig = originalContent, modifiedCode.trimmingCharacters(in: .whitespacesAndNewlines) != orig.trimmingCharacters(in: .whitespacesAndNewlines) {
                return AgentResult(
                    explanation: explanation.isEmpty ? "Changes applied." : explanation,
                    diff: modifiedCode
                )
            }
        }

        // No code block — conversational answer
        return AgentResult(explanation: raw.trimmingCharacters(in: .whitespacesAndNewlines), diff: nil)
    }

    // MARK: - MLX placeholder (Phase 2)

    private func callMLX(prompt: String) async -> String? {
        // TODO: wire MLXExecutor in Phase 2
        return "MLX inference not yet connected. Use Ollama for now."
    }
}
