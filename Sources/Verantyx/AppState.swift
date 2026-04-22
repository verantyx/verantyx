import Foundation
import SwiftUI
import AppKit

// MARK: - Core data models

struct ChatMessage: Identifiable, Equatable {
    var id: UUID
    var role: Role
    var content: String
    var timestamp = Date()

    init(id: UUID = UUID(), role: Role, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }

    enum Role { case user, assistant, system }
}

struct FileDiff: Identifiable {
    let id = UUID()
    let fileURL: URL
    let originalContent: String
    let modifiedContent: String
    var hunks: [DiffHunk]

    var hasChanges: Bool { originalContent != modifiedContent }
}

struct DiffHunk: Identifiable {
    let id = UUID()
    var lines: [DiffLine]
}

struct DiffLine: Identifiable {
    let id = UUID()
    var kind: Kind
    var text: String

    enum Kind { case context, added, removed }
}

// MARK: - AppState

@MainActor
final class AppState: ObservableObject {

    // Workspace
    @Published var workspaceURL: URL?
    @Published var workspaceFiles: [URL] = []
    @Published var selectedFile: URL?
    @Published var selectedFileContent: String = ""

    // Model
    @Published var modelStatus: ModelStatus = .none
    @Published var ollamaModels: [String] = []
    @Published var activeOllamaModel: String = "gemma4:26b"
    @Published var customHFRepoId: String = "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit"
    @Published var downloadProgress: Double = 0

    // Chat
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isGenerating = false

    // ── Performance metrics (the "Apple Silicon violence" numbers) ──
    @Published var tokensPerSecond: Double = 0       // live tok/s display
    @Published var totalTokensGenerated: Int = 0     // session total
    @Published var streamingText: String = ""        // current token buffer for live render
    @Published var inferenceMs: Int = 0              // last response latency ms

    // ── Process log ("what is the AI thinking right now") ──
    @Published var processLog: [ProcessLogEntry] = []   // raw live log
    @Published var showProcessLog: Bool = true

    struct ProcessLogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        var text: String
        var kind: Kind

        enum Kind { case memory, tool, browser, thinking, system, perf }

        var prefix: String {
            switch kind {
            case .memory:   return "→ MEM  "
            case .tool:     return "→ TOOL "
            case .browser:  return "→ DOM  "
            case .thinking: return "▶ THINK"
            case .system:   return "⋯ SYS  "
            case .perf:     return "⚡ PERF "
            }
        }

        var color: Color {
            switch kind {
            case .memory:   return Color(red: 0.4, green: 0.9, blue: 0.6)
            case .tool:     return Color(red: 0.4, green: 0.8, blue: 1.0)
            case .browser:  return Color(red: 0.9, green: 0.7, blue: 0.3)
            case .thinking: return Color(red: 0.8, green: 0.8, blue: 1.0)
            case .system:   return Color(red: 0.6, green: 0.6, blue: 0.6)
            case .perf:     return Color(red: 0.3, green: 1.0, blue: 0.5)
            }
        }
    }

    // Diff
    @Published var pendingDiff: FileDiff?
    @Published var showDiff = false

    // Privacy Shield / Hybrid mode
    @Published var inferenceMode: InferenceMode = .localOnly {
        didSet { UserDefaults.standard.set(inferenceMode.rawValue, forKey: "inference_mode") }
    }
    @Published var cloudProvider: CloudProvider = .claude {
        didSet { UserDefaults.standard.set(cloudProvider.rawValue, forKey: "cloud_provider") }
    }
    @Published var lastMaskingStats: MaskingStats?
    @Published var privacySteps: [String] = []

    // ── Model configuration (all persisted via UserDefaults) ──
    @Published var temperature: Double = 0.1 {
        didSet { UserDefaults.standard.set(temperature, forKey: "model_temperature") }
    }
    @Published var maxTokensOllama: Int = 2048 {
        didSet { UserDefaults.standard.set(maxTokensOllama, forKey: "max_tokens_ollama") }
    }
    @Published var maxTokensMLX: Int = 4096 {
        didSet { UserDefaults.standard.set(maxTokensMLX, forKey: "max_tokens_mlx") }
    }
    @Published var ollamaEndpoint: String = "http://localhost:11434" {
        didSet { UserDefaults.standard.set(ollamaEndpoint, forKey: "ollama_endpoint") }
    }
    @Published var systemPrompt: String = "You are Verantyx, an expert AI coding assistant running on Apple Silicon. Be concise and precise. Prefer code over prose." {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: "system_prompt") }
    }
    @Published var streamingEnabled: Bool = true {
        didSet { UserDefaults.standard.set(streamingEnabled, forKey: "streaming_enabled") }
    }

    // ── Tool toggles ──
    @Published var toolBrowserEnabled: Bool = true {
        didSet { UserDefaults.standard.set(toolBrowserEnabled, forKey: "tool_browser") }
    }
    @Published var toolWebSearchEnabled: Bool = true {
        didSet { UserDefaults.standard.set(toolWebSearchEnabled, forKey: "tool_web_search") }
    }
    @Published var toolTerminalEnabled: Bool = true {
        didSet { UserDefaults.standard.set(toolTerminalEnabled, forKey: "tool_terminal") }
    }
    @Published var toolDiffEnabled: Bool = true {
        didSet { UserDefaults.standard.set(toolDiffEnabled, forKey: "tool_diff") }
    }
    @Published var toolJCrossEnabled: Bool = true {
        didSet { UserDefaults.standard.set(toolJCrossEnabled, forKey: "tool_jcross") }
    }

    enum ModelStatus: Equatable {
        case none
        case connecting
        case downloading(progress: Double)
        case ready(name: String)
        case ollamaReady(model: String)
        case mlxReady(model: String)          // ← MLX server running at localhost:8080
        case mlxDownloading(model: String)    // ← mlx_lm download in progress
        case error(String)
    }

    // Workspace manager (lazy)
    private let workspace = WorkspaceManager()
    let agent = AgentEngine()
    let terminal = TerminalRunner()
    let cortex = CortexEngine()

    // MLX state
    @Published var activeMlxModel: String = "mlx-community/gemma-4-26b-a4b-it-4bit"
    @Published var mlxServerLogs: [String] = []

    // Agent loop
    @Published var agentLoopEnabled: Bool = true {
        didSet { UserDefaults.standard.set(agentLoopEnabled, forKey: "agent_loop_enabled") }
    }

    // MARK: - Workspace actions

    func openWorkspace() {
        guard let url = workspace.pickFolder() else { return }
        workspaceURL = url
        workspaceFiles = []          // clear instantly for UI responsiveness
        selectedFile = nil
        selectedFileContent = ""
        terminal.workingDirectory = url
        addSystemMessage("📂 Workspace: \(url.lastPathComponent)")
        refreshFiles()               // async scan in background
    }

    /// Async directory scan — never blocks the main thread.
    func refreshFiles() {
        guard let root = workspaceURL else { return }
        let exts = ["swift","py","ts","js","go","rs","kt","java","c","cpp","h",
                    "md","json","yaml","toml","html","css","sh","rb","php"]
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let files = await self.workspace.listFilesAsync(in: root, extensions: exts)
            await MainActor.run { self.workspaceFiles = files }
        }
    }

    /// Instant selection — show name immediately, read content async.
    func selectFile(_ url: URL) {
        selectedFile = url          // highlight instantly (no wait)
        selectedFileContent = ""    // clear old content immediately
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            // Read on background thread — never blocks UI
            let content = (try? String(contentsOf: url, encoding: .utf8)) ??
                          (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
            await MainActor.run {
                // Only update if this file is still selected
                guard self.selectedFile == url else { return }
                self.selectedFileContent = content
            }
        }
    }

    // MARK: - Agent actions

    func sendMessage(with overrideText: String? = nil) {
        let text = (overrideText ?? inputText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        inputText = ""

        messages.append(ChatMessage(role: .user, content: text))
        isGenerating = true

        Task {
            // Compress context if needed (Cortex anti-Alzheimer's)
            let trimmed = cortex.compressIfNeeded(messages: messages)
            if trimmed.count < messages.count {
                await MainActor.run { self.messages = trimmed }
            }

            // Route: Privacy Shield / Cloud modes bypass agent loop
            if inferenceMode == .cloudDirect || inferenceMode == .privacyShield {
                await runHybrid(instruction: text)
            } else if agentLoopEnabled {
                await runAgentLoop(instruction: text)
            } else {
                await runSinglePass(instruction: text)
            }
        }
    }

    // MARK: - Hybrid Engine (Privacy Shield / Cloud Direct)

    private func runHybrid(instruction: String) async {
        let context = selectedFileContent.isEmpty ? nil : selectedFileContent
        let contextFile = selectedFile
        await MainActor.run { self.privacySteps = [] }

        let snap_mode = inferenceMode
        let snap_provider = cloudProvider
        let snap_model = activeOllamaModel
        let snap_status = modelStatus

        let result = await HybridEngine.shared.process(
            instruction: instruction,
            fileContent: context,
            fileName: contextFile?.lastPathComponent,
            fileURL: contextFile,
            mode: snap_mode,
            modelStatus: snap_status,
            activeOllamaModel: snap_model,
            cloudProvider: snap_provider,
            cortex: cortex
        ) { [weak self] step in
            guard let self else { return }
            await MainActor.run {
                self.privacySteps.append(step)
                self.messages.append(ChatMessage(role: .system, content: step))
            }
        }

        await MainActor.run {
            isGenerating = false
            lastMaskingStats = result.maskingStats
            messages.append(ChatMessage(role: .assistant, content: result.explanation))
            if let code = result.modifiedCode, !code.isEmpty, let fileURL = contextFile {
                pendingDiff = FileDiff(
                    fileURL: fileURL,
                    originalContent: selectedFileContent,
                    modifiedContent: code,
                    hunks: DiffEngine.compute(original: selectedFileContent, modified: code)
                )
                showDiff = true
            }
        }
    }

    // MARK: - Agent Loop (multi-turn, scaffolding)

    private func runAgentLoop(instruction: String) async {
        let context = selectedFileContent.isEmpty ? nil : selectedFileContent
        let contextFile = selectedFile
        let snap_workspace = workspaceURL
        let snap_model = activeOllamaModel
        let snap_status = modelStatus

        await AgentLoop.shared.run(
            instruction: instruction,
            contextFile: context,
            contextFileName: contextFile?.lastPathComponent,
            workspaceURL: snap_workspace,
            modelStatus: snap_status,
            activeModel: snap_model,
            cortex: cortex
        ) { [weak self] event in
            guard let self else { return }
            await MainActor.run {
                switch event {
                case .start:
                    break

                case .thinking(let t):
                    if t > 1 {
                        self.messages.append(ChatMessage(role: .system,
                            content: "🔄 Agent loop turn \(t)…"))
                    }

                case .aiMessage(let text):
                    if !text.isEmpty {
                        self.messages.append(ChatMessage(role: .assistant, content: text))
                    }

                case .toolCall(let call):
                    self.messages.append(ChatMessage(role: .system,
                        content: "⚙️ \(call.displayLabel)"))
                    // Also log to terminal
                    if case .runCommand(let cmd) = call.tool {
                        Task { await self.terminal.run(cmd, in: self.workspaceURL, initiatedByAI: true) }
                    }

                case .toolResult(let call):
                    if !call.result.isEmpty {
                        let icon = call.succeeded ? "✅" : "❌"
                        self.messages.append(ChatMessage(role: .system,
                            content: "\(icon) \(call.result.prefix(120))"))
                    }

                case .workspaceChanged(let url):
                    self.workspaceURL = url
                    self.terminal.workingDirectory = url
                    self.refreshFiles()
                    self.addSystemMessage("📂 Workspace: \(url.lastPathComponent)")

                case .done(let msg, let ws):
                    self.isGenerating = false
                    if let ws = ws, self.workspaceURL == nil {
                        self.workspaceURL = ws
                        self.terminal.workingDirectory = ws
                        self.refreshFiles()
                    }
                    if !msg.isEmpty {
                        self.messages.append(ChatMessage(role: .assistant,
                            content: "✅ \(msg)"))
                    }

                case .error(let err):
                    self.isGenerating = false
                    self.addSystemMessage("❌ Agent error: \(err)")
                }
            }
        }

        await MainActor.run { self.isGenerating = false }
    }

    // MARK: - Single pass (original behavior)

    // MARK: - Single pass (streaming)
    // Streams tokens directly into the chat bubble in real-time.
    // Tracks tok/s and emits process log entries.

    private func runSinglePass(instruction: String) async {
        let context = selectedFileContent.isEmpty ? nil : selectedFileContent
        let contextFile = selectedFile

        let snap_status = modelStatus
        let snap_model  = activeOllamaModel

        // Build prompt (same as AgentEngine)
        let fileSection = context.map { content in
            let name = contextFile?.lastPathComponent ?? "file"
            return "FILE: \(name)\n```\n\(content.prefix(8000))\n```\n\n"
        } ?? ""

        let prompt = """
        You are Verantyx, an expert AI coding assistant running on Apple Silicon.

        \(fileSection)USER: \(instruction)

        ASSISTANT:
        """

        // Reset streaming state
        streamingText = ""
        tokensPerSecond = 0
        var tokenCount = 0
        let startTime = Date()
        var lastPerfLog = Date()

        logProcess("inference start [", kind: .system)
        logProcess("prompt \(prompt.count) chars", kind: .system)

        // Build the stream based on active model — use live settings
        let stream: AsyncThrowingStream<String, Error>
        switch snap_status {
        case .ollamaReady(let model):
            logProcess("Ollama/\(model)  temp=\(temperature)  maxTok=\(maxTokensOllama)", kind: .system)
            stream = OllamaClient.shared.streamGenerate(
                model: model, prompt: prompt,
                maxTokens: maxTokensOllama,
                temperature: temperature
            )
        case .mlxReady:
            let m = activeMlxModel.components(separatedBy: "/").last ?? activeMlxModel
            logProcess("MLX/\(m) @ localhost:8080  temp=\(temperature)  maxTok=\(maxTokensMLX)", kind: .system)
            stream = await MLXRunner.shared.streamGenerate(
                prompt: prompt,
                maxTokens: maxTokensMLX,
                temperature: temperature
            )
        default:
            messages.append(ChatMessage(role: .assistant,
                content: "⚠️ No model. Connect Ollama or start MLX server."))
            isGenerating = false
            return
        }

        // Reserve a slot in messages for the streaming assistant reply
        let msgId = UUID()
        await MainActor.run {
            messages.append(ChatMessage(id: msgId, role: .assistant, content: ""))
        }

        // Stream tokens
        do {
            for try await token in stream {
                tokenCount += 1
                totalTokensGenerated += 1

                await MainActor.run {
                    // Update in-place streaming message
                    if let idx = self.messages.firstIndex(where: { $0.id == msgId }) {
                        self.messages[idx].content += token
                    }
                    self.streamingText += token

                    // Update tok/s every 0.25s
                    let elapsed = Date().timeIntervalSince(startTime)
                    if elapsed > 0.1 {
                        self.tokensPerSecond = Double(tokenCount) / elapsed
                    }
                }

                // Perf log every 2s
                if Date().timeIntervalSince(lastPerfLog) > 2 {
                    let elapsed = Date().timeIntervalSince(startTime)
                    let tps = Double(tokenCount) / max(elapsed, 0.001)
                    logProcess(String(format: "%.1f tok/s  │  %d tokens", tps, tokenCount), kind: .perf)
                    lastPerfLog = Date()
                }
            }
        } catch {
            logProcess("stream error: \(error.localizedDescription)", kind: .system)
        }

        // Final state
        let elapsed = Date().timeIntervalSince(startTime)
        let finalTps = Double(tokenCount) / max(elapsed, 0.001)
        inferenceMs = Int(elapsed * 1000)
        tokensPerSecond = finalTps

        logProcess(String(format: "done  %.1f tok/s  │  %d tok  │  %.1fs",
                          finalTps, tokenCount, elapsed), kind: .perf)

        // Parse agent tools from the final streamed content
        let finalContent: String
        if let idx = messages.firstIndex(where: { $0.id == msgId }) {
            finalContent = messages[idx].content
        } else { finalContent = "" }

        let (toolCalls, _) = AgentToolParser.parse(from: finalContent)
        let executor = AgentToolExecutor()

        for tool in toolCalls {
            logProcess("\(tool)", kind: .tool)
            let result = await executor.execute(tool, workspaceURL: workspaceURL)

            // Workspace switch side-effect
            if case .setWorkspace(let path) = tool {
                let url = URL(fileURLWithPath: path)
                workspaceURL = url
                terminal.workingDirectory = url
                refreshFiles()
            }
            addSystemMessage(result)
        }

        isGenerating = false
    }

    // MARK: - Process log helpers

    func logProcess(_ text: String, kind: ProcessLogEntry.Kind) {
        let entry = ProcessLogEntry(timestamp: Date(), text: text, kind: kind)
        DispatchQueue.main.async {
            if self.processLog.count > 500 { self.processLog.removeFirst(100) }
            self.processLog.append(entry)
        }
    }

    func clearProcessLog() { processLog.removeAll() }

    func applyDiff() {
        guard let diff = pendingDiff else { return }
        do {
            try diff.modifiedContent.write(to: diff.fileURL, atomically: true, encoding: .utf8)
            selectedFileContent = diff.modifiedContent
            addSystemMessage("✅ Applied changes to \(diff.fileURL.lastPathComponent)")
        } catch {
            addSystemMessage("❌ Failed to write: \(error.localizedDescription)")
        }
        pendingDiff = nil
        showDiff = false
    }

    func skipDiff() {
        pendingDiff = nil
        showDiff = false
        addSystemMessage("⏭ Changes discarded.")
    }

    // MARK: - Model actions

    func connectOllama() {
        Task {
            modelStatus = .connecting
            let models = await OllamaClient.shared.listModels()
            await MainActor.run {
                ollamaModels = models
                if models.contains(activeOllamaModel) {
                    modelStatus = .ollamaReady(model: activeOllamaModel)
                    ToastManager.shared.show("\(activeOllamaModel) ready", icon: "checkmark.circle.fill", color: .green)
                } else if models.contains("gemma4:26b") {
                    activeOllamaModel = "gemma4:26b"
                    modelStatus = .ollamaReady(model: "gemma4:26b")
                    ToastManager.shared.show("gemma4:26b ready", icon: "checkmark.circle.fill", color: .green)
                } else if !models.isEmpty {
                    let m = models.first!
                    activeOllamaModel = m
                    modelStatus = .ollamaReady(model: m)
                    ToastManager.shared.show("\(m) ready", icon: "checkmark.circle.fill", color: .green)
                } else {
                    modelStatus = .error("No Ollama models found")
                    ToastManager.shared.show("No Ollama models. Run: ollama pull gemma4:26b",
                                            icon: "exclamationmark.triangle.fill", color: .orange, duration: 4.5)
                }
            }
        }
    }

    // MARK: - Helpers

    func addSystemMessage(_ text: String) {
        // Only show agent-loop tool events — NOT model load events (those use Toast)
        guard !text.hasPrefix("🟢") && !text.hasPrefix("🔌") else { return }
        messages.append(ChatMessage(role: .system, content: text))
    }

    var isReady: Bool {
        switch modelStatus {
        case .ready, .ollamaReady, .mlxReady: return true
        default: return false
        }
    }

    var statusLabel: String {
        switch modelStatus {
        case .none:                          return "No model"
        case .connecting:                    return "Connecting…"
        case .downloading(let p):            return "Downloading \(Int(p * 100))%"
        case .ready(let n):                  return n
        case .ollamaReady(let m):            return "Ollama: \(m.components(separatedBy: ":").first ?? m)"
        case .mlxReady(let m):              return "MLX: \(m.components(separatedBy: "/").last ?? m)"
        case .mlxDownloading(let m):        return "⏬ \(m.components(separatedBy: "/").last ?? m)"
        case .error(let e):                  return "Error: \(e)"
        }
    }

    var statusColor: Color {
        switch modelStatus {
        case .ready, .ollamaReady, .mlxReady: return .green
        case .error:                           return .red
        case .downloading, .connecting,
             .mlxDownloading:                  return .orange
        case .none:                            return .gray
        }
    }

    // MARK: - MLX Actions

    func startMLXServer(model: String? = nil) {
        let modelId = model ?? activeMlxModel
        modelStatus = .connecting
        mlxServerLogs.removeAll()

        Task {
            do {
                try await MLXRunner.shared.startServer(model: modelId) { @Sendable log in
                    Task { @MainActor in
                        self.mlxServerLogs.append(log)
                        // Suppress verbose model loading from chat
                    }
                }
                await MainActor.run {
                    self.modelStatus = .mlxReady(model: modelId)
                    self.activeMlxModel = modelId
                    ToastManager.shared.show(
                        "MLX: \(modelId.components(separatedBy: "/").last ?? modelId) ready 🚀",
                        icon: "cpu",
                        color: Color(red: 0.4, green: 0.85, blue: 0.6)
                    )
                }
            } catch {
                await MainActor.run {
                    self.modelStatus = .error(error.localizedDescription)
                    ToastManager.shared.show(
                        "MLX error: \(error.localizedDescription)",
                        icon: "exclamationmark.triangle.fill",
                        color: .orange,
                        duration: 5
                    )
                }
            }
        }
    }

    func downloadMLXModel(repoId: String) {
        modelStatus = .mlxDownloading(model: repoId)
        mlxServerLogs.removeAll()

        Task {
            do {
                try await MLXRunner.shared.downloadModel(repoId: repoId) { @Sendable log in
                    Task { @MainActor in
                        self.mlxServerLogs.append(log)
                    }
                }
                await MainActor.run {
                    ToastManager.shared.show(
                        "Downloaded: \(repoId.components(separatedBy: "/").last ?? repoId)",
                        icon: "checkmark.circle.fill",
                        color: .green,
                        duration: 4
                    )
                    self.startMLXServer(model: repoId)
                }
            } catch {
                await MainActor.run {
                    self.modelStatus = .error("Download failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
