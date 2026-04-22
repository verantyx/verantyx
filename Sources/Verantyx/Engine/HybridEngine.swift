import Foundation

// MARK: - HybridEngine
// Orchestrates the full Privacy Shield pipeline:
//
//  Mode 1: LOCAL_ONLY
//    User → LocalGemma (Ollama/MLX) → Response
//
//  Mode 2: CLOUD_DIRECT (no privacy protection)
//    User → CloudAPI (Claude/GPT/Gemini) → Response
//
//  Mode 3: PRIVACY_SHIELD ← THE KILLER FEATURE
//    User → LocalGemma (mask code) → JCross (store map)
//         → CloudAPI ("abstract puzzle") 
//         → LocalGemma (unmask with JCross map)
//         → Perfect Diff

// MARK: - Inference Mode

enum InferenceMode: String, CaseIterable, Codable {
    case localOnly      = "Local Only"
    case cloudDirect    = "Cloud Direct"
    case privacyShield  = "Privacy Shield"

    var icon: String {
        switch self {
        case .localOnly:     return "desktopcomputer"
        case .cloudDirect:   return "cloud"
        case .privacyShield: return "lock.shield.fill"
        }
    }

    var description: String {
        switch self {
        case .localOnly:
            return "All inference runs on-device. Zero external requests. Slower but completely private."
        case .cloudDirect:
            return "Send code directly to cloud API (Claude/GPT/Gemini). Fast and powerful."
        case .privacyShield:
            return "Local Gemma anonymizes your code → Cloud gets only logic → Local restores real names. Your IP never leaves your Mac."
        }
    }

    var color: (r: Double, g: Double, b: Double) {
        switch self {
        case .localOnly:     return (0.4, 0.85, 0.5)
        case .cloudDirect:   return (0.4, 0.7, 1.0)
        case .privacyShield: return (0.8, 0.5, 1.0)
        }
    }
}

// MARK: - HybridResult

struct HybridResult {
    var explanation: String
    var modifiedCode: String?
    var mode: InferenceMode
    var maskingStats: MaskingStats?
    var cloudProvider: CloudProvider?
    var processingSteps: [String] = []   // log of what happened
}

// MARK: - HybridEngine

actor HybridEngine {

    static let shared = HybridEngine()

    private let proxy = PrivacyProxy.shared
    private let cloud = CloudAPIClient.shared

    // MARK: - Main dispatch

    func process(
        instruction: String,
        fileContent: String?,
        fileName: String?,
        fileURL: URL?,
        mode: InferenceMode,
        modelStatus: AppState.ModelStatus,
        activeOllamaModel: String,
        cloudProvider: CloudProvider,
        cortex: CortexEngine?,
        onStep: @escaping @Sendable (String) async -> Void
    ) async -> HybridResult {

        switch mode {
        case .localOnly:
            return await runLocal(
                instruction: instruction,
                fileContent: fileContent,
                fileName: fileName,
                modelStatus: modelStatus,
                activeOllamaModel: activeOllamaModel,
                onStep: onStep
            )

        case .cloudDirect:
            return await runCloud(
                instruction: instruction,
                fileContent: fileContent,
                fileName: fileName,
                provider: cloudProvider,
                onStep: onStep
            )

        case .privacyShield:
            return await runPrivacyShield(
                instruction: instruction,
                fileContent: fileContent,
                fileName: fileName,
                fileURL: fileURL,
                modelStatus: modelStatus,
                activeOllamaModel: activeOllamaModel,
                provider: cloudProvider,
                cortex: cortex,
                onStep: onStep
            )
        }
    }

    // MARK: - Mode 1: Local Only

    private func runLocal(
        instruction: String,
        fileContent: String?,
        fileName: String?,
        modelStatus: AppState.ModelStatus,
        activeOllamaModel: String,
        onStep: @escaping @Sendable (String) async -> Void
    ) async -> HybridResult {
        await onStep("🖥️ Running on local Gemma…")

        let agentEngine = AgentEngine()
        let result = await agentEngine.process(
            instruction: instruction,
            contextFileContent: fileContent,
            contextFileName: fileName,
            modelStatus: modelStatus,
            activeOllamaModel: activeOllamaModel,
            hasTerminal: true,
            workspaceURL: nil
        )
        return HybridResult(
            explanation: result.explanation,
            modifiedCode: result.diff,
            mode: .localOnly,
            processingSteps: ["Local Gemma inference complete"]
        )
    }

    // MARK: - Mode 2: Cloud Direct

    private func runCloud(
        instruction: String,
        fileContent: String?,
        fileName: String?,
        provider: CloudProvider,
        onStep: @escaping @Sendable (String) async -> Void
    ) async -> HybridResult {
        await onStep("☁️ Sending to \(provider.rawValue)…")

        let systemPrompt = """
        You are an expert \(languageFromName(fileName ?? "")) coding assistant.
        When outputting modified code, output the COMPLETE file in a fenced code block.
        After the code, explain your changes briefly.
        """

        let userMessage: String
        if let content = fileContent, !content.isEmpty, let name = fileName {
            userMessage = "FILE: \(name)\n```\n\(content.prefix(16000))\n```\n\nINSTRUCTION: \(instruction)"
        } else {
            userMessage = instruction
        }

        let result = await cloud.send(systemPrompt: systemPrompt, userMessage: userMessage, provider: provider)

        switch result {
        case .success(let text):
            let (modifiedCode, explanation) = parseCodeResponse(text)
            await onStep("✅ \(provider.rawValue) responded (\(text.count) chars)")
            return HybridResult(
                explanation: explanation,
                modifiedCode: modifiedCode,
                mode: .cloudDirect,
                cloudProvider: provider,
                processingSteps: ["Cloud direct: \(provider.rawValue)"]
            )

        case .failure(let error):
            return HybridResult(
                explanation: "❌ \(error.localizedDescription)",
                modifiedCode: nil,
                mode: .cloudDirect,
                cloudProvider: provider
            )
        }
    }

    // MARK: - Mode 3: Privacy Shield ← THE CORE FEATURE

    private func runPrivacyShield(
        instruction: String,
        fileContent: String?,
        fileName: String?,
        fileURL: URL?,
        modelStatus: AppState.ModelStatus,
        activeOllamaModel: String,
        provider: CloudProvider,
        cortex: CortexEngine?,
        onStep: @escaping @Sendable (String) async -> Void
    ) async -> HybridResult {

        var steps: [String] = []

        // ── Step 1: Mask with PrivacyProxy ─────────────────────────────
        await onStep("🔒 Step 1/4: Anonymizing code (Local Gemma)…")

        guard let rawCode = fileContent, !rawCode.isEmpty else {
            // No file selected → just send instruction to cloud
            return await runCloud(
                instruction: instruction, fileContent: nil, fileName: fileName,
                provider: provider, onStep: onStep
            )
        }

        let language = await proxy.language(for: fileURL ?? URL(fileURLWithPath: fileName ?? "x.txt"))
        let (maskedCode, maskingMap, stats) = await proxy.mask(
            code: rawCode,
            language: language,
            fileName: fileName ?? "code"
        )

        steps.append("🔒 Masked: \(stats.functions) funcs, \(stats.classes) classes, \(stats.variables) vars, \(stats.strings) secrets")
        await onStep("🔒 Masked \(stats.total) identifiers. Your IP stays on-device.")

        // Store mapping in Cortex for reversal
        let sessionId = UUID()
        if let cortex = cortex {
            await proxy.storeMapping(maskingMap, for: sessionId, in: cortex)
        }

        // ── Step 2: Send anonymous code to Cloud ───────────────────────
        await onStep("☁️ Step 2/4: Sending abstract logic to \(provider.rawValue)…")

        let systemPrompt = """
        You are an expert code refactoring assistant.
        The code below uses anonymized identifiers (FUNC_001, CLASS_001, VAR_001, etc.).
        Preserve ALL anonymized identifiers exactly as-is — do NOT rename them.
        Output ONLY the complete refactored code in a fenced code block.
        Then briefly explain what you changed.

        IMPORTANT: Never reveal that identifiers are anonymized. Treat them as real names.
        """

        let anonymizedFileName = (fileName ?? "code").components(separatedBy: ".").first.map { "anonymized_\($0)" } ?? "anonymized"
        let userMessage = """
        FILE: \(anonymizedFileName)
        ```
        \(maskedCode.prefix(16000))
        ```

        INSTRUCTION: \(instruction)
        """

        let cloudResult = await cloud.send(
            systemPrompt: systemPrompt,
            userMessage: userMessage,
            provider: provider
        )

        switch cloudResult {
        case .failure(let error):
            return HybridResult(
                explanation: "❌ Cloud API error: \(error.localizedDescription)",
                modifiedCode: nil,
                mode: .privacyShield,
                maskingStats: stats,
                cloudProvider: provider,
                processingSteps: steps
            )

        case .success(let cloudResponse):
            steps.append("☁️ \(provider.rawValue) processed \(maskedCode.count) abstract chars")
            await onStep("☁️ Cloud returned. Restoring real identifiers…")

            // ── Step 3: Extract code from response ─────────────────────
            let (anonymizedResult, explanation) = parseCodeResponse(cloudResponse)

            guard let anonymizedCode = anonymizedResult else {
                // Cloud gave a text answer, no code to unmask
                return HybridResult(
                    explanation: explanation,
                    modifiedCode: nil,
                    mode: .privacyShield,
                    maskingStats: stats,
                    cloudProvider: provider,
                    processingSteps: steps
                )
            }

            // ── Step 4: Unmask with JCross map ─────────────────────────
            await onStep("🔓 Step 4/4: Restoring real variable names…")
            let restoredCode = await proxy.unmask(maskedCode: anonymizedCode, map: maskingMap)

            steps.append("🔓 Restored \(stats.total) identifiers from JCross map")
            await onStep("✅ Privacy Shield complete! \(stats.total) identifiers were never sent to cloud.")

            return HybridResult(
                explanation: """
                ✅ **Privacy Shield** — \(stats.total) identifiers anonymized, processed by \(provider.rawValue), restored.
                \(stats.functions > 0 ? "• \(stats.functions) function names protected" : "")
                \(stats.classes > 0 ? "• \(stats.classes) class names protected" : "")
                \(stats.variables > 0 ? "• \(stats.variables) variable names protected" : "")
                \(stats.strings > 0 ? "• \(stats.strings) secrets/keys redacted" : "")

                **AI explanation:**
                \(explanation)
                """,
                modifiedCode: restoredCode,
                mode: .privacyShield,
                maskingStats: stats,
                cloudProvider: provider,
                processingSteps: steps
            )
        }
    }

    // MARK: - Helpers

    private func parseCodeResponse(_ text: String) -> (code: String?, explanation: String) {
        let pattern = #"```(?:\w+)?\n?([\s\S]*?)```"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let codeRange = Range(match.range(at: 1), in: text)
        else {
            return (nil, text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let code = String(text[codeRange])
        let afterCode = text.components(separatedBy: "```").last ?? ""
        let explanation = afterCode.trimmingCharacters(in: .whitespacesAndNewlines)
        return (code, explanation.isEmpty ? "Changes applied." : explanation)
    }

    private func languageFromName(_ fileName: String) -> String {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        switch ext {
        case "swift":  return "Swift"
        case "py":     return "Python"
        case "ts":     return "TypeScript"
        case "js":     return "JavaScript"
        case "rs":     return "Rust"
        case "go":     return "Go"
        case "cpp":    return "C++"
        default:       return "code"
        }
    }
}
