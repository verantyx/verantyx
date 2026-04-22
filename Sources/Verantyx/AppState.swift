import Foundation
import SwiftUI
import AppKit

// MARK: - Core data models

struct ChatMessage: Identifiable, Equatable, Codable {
    var id: UUID
    var role: Role
    var content: String
    var timestamp = Date()

    init(id: UUID = UUID(), role: Role, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }

    enum Role: String, Codable { case user, assistant, system }
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
    @Published var anthropicApiKey: String = "" {
        didSet {
            // Anthropic API キーを AnthropicClient に反映
            Task { await AnthropicClient.shared.configure(apiKey: anthropicApiKey) }
            UserDefaults.standard.set(anthropicApiKey, forKey: "anthropic_api_key")
        }
    }
    @Published var activeAnthropicModel: String = "claude-sonnet-4-5" {
        didSet { UserDefaults.standard.set(activeAnthropicModel, forKey: "anthropic_model") }
    }
    @Published var customHFRepoId: String = "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit"
    @Published var downloadProgress: Double = 0

    // Chat
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isGenerating = false

    // Self-Fix mode — when true, next message(s) target IDE self-modification
    // Must be explicitly toggled by user pressing the "Self Fix" button.
    @Published var selfFixMode: Bool = false
    /// Set to true when the AI calls [RESTART_IDE] — triggers a restart alert in the UI.
    @Published var showRestartAlert: Bool = false

    // Attachments (images + files for multimodal inference)
    @Published var attachedImages: [AttachedImage] = []
    @Published var attachedFiles: [URL] = []

    // Inference task handle (for cancellation)
    private var inferenceTask: Task<Void, Never>? = nil

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

    // Operation Mode (AI Priority vs Human)
    @Published var operationMode: OperationMode = .human {
        didSet {
            UserDefaults.standard.set(operationMode.rawValue, forKey: "operation_mode")
            // Sync MCPEngine execution mode
            let mcpMode: MCPServerConfig.ExecutionMode = operationMode == .aiPriority ? .ai : .human
            Task { await MCPEngine.shared.setMode(mcpMode) }
        }
    }

    // Artifacts (Claude-style live preview)
    @Published var currentArtifact: Artifact? = nil
    @Published var artifactHistory: [Artifact] = []
    @Published var showArtifactPanel: Bool = false

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

    // ── Privacy Gateway: Gemma semantic masking ──
    /// Gemmaによるセマンティックマスキング (Phase 2) の有効/無効
    /// OFF時は Phase 1 正規表現マスキングのみ使用（高速、Gemma不要）
    @Published var gemmaSemanticMaskingEnabled: Bool = true {
        didSet { UserDefaults.standard.set(gemmaSemanticMaskingEnabled, forKey: "gemma_semantic_masking") }
    }

    // ── UI Language ──
    enum UILanguage: String, CaseIterable, Codable {
        case system  = "System"
        case english = "English"
        case japanese = "日本語"

        var localeIdentifier: String {
            switch self {
            case .system:   return Locale.current.identifier
            case .english:  return "en"
            case .japanese: return "ja"
            }
        }

        var flag: String {
            switch self {
            case .system:   return "🌐"
            case .english:  return "🇺🇸"
            case .japanese: return "🇯🇵"
            }
        }
    }

    @Published var appLanguage: UILanguage = {
        let raw = UserDefaults.standard.string(forKey: "app_language") ?? UILanguage.system.rawValue
        return UILanguage(rawValue: raw) ?? .system
    }() {
        didSet { UserDefaults.standard.set(appLanguage.rawValue, forKey: "app_language") }
    }

    // MARK: - Localized string helper
    func t(_ en: String, _ ja: String) -> String {
        switch appLanguage {
        case .japanese: return ja
        case .english:  return en
        case .system:
            return Locale.current.language.languageCode?.identifier == "ja" ? ja : en
        }
    }

    // MARK: - UI Preferences

    @Published var codeFontSize: Int = {
        let v = UserDefaults.standard.integer(forKey: "code_font_size")
        return v > 0 ? v : 12
    }() {
        didSet { UserDefaults.standard.set(codeFontSize, forKey: "code_font_size") }
    }

    @Published var notifyOnDiffApply: Bool = UserDefaults.standard.bool(forKey: "notify_diff_apply") {
        didSet { UserDefaults.standard.set(notifyOnDiffApply, forKey: "notify_diff_apply") }
    }

    @Published var notifyOnError: Bool = {
        let v = UserDefaults.standard.object(forKey: "notify_error") as? Bool
        return v ?? true
    }() {
        didSet { UserDefaults.standard.set(notifyOnError, forKey: "notify_error") }
    }

    // ── Multimodal capability detection ──
    var isMultimodalModel: Bool {
        switch modelStatus {
        case .ollamaReady(let m):
            let mm = m.lowercased()
            return mm.contains("llava") || mm.contains("vision")
                || mm.contains("gemma") || mm.contains("qwen") && mm.contains("vl")
                || mm.contains("minicpm") || mm.contains("moondream")
                || mm.contains("bakllava") || mm.contains("cogvlm")
        case .mlxReady(let m):
            let mm = m.lowercased()
            return mm.contains("vision") || mm.contains("gemma-4")
                || mm.contains("qwen-vl") || mm.contains("llava") || mm.contains("llm3.2")
        default: return false
        }
    }

    enum ModelStatus: Equatable {
        case none
        case connecting
        case downloading(progress: Double)
        case ready(name: String)
        case ollamaReady(model: String)
        case anthropicReady(model: String, maskedKey: String)  // NEW: Anthropic API
        case mlxReady(model: String)          // ← MLX server running at localhost:8080
        case mlxDownloading(model: String)    // ← mlx_lm download in progress
        case error(String)
    }

    // Workspace manager (lazy)
    private let workspace = WorkspaceManager()
    let agent = AgentEngine()
    let terminal = TerminalRunner()
    let cortex = CortexEngine()
    let sessions = SessionStore()

    // MARK: - Dirty state (close/quit guard)

    /// True when there is active work that should be saved before quitting.
    var isDirty: Bool {
        (workspaceURL != nil && (pendingDiff != nil || messages.count > 2))
        || isGenerating
    }

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
        // Hint the Self-Evolution engine so it can find xcodeproj from here
        SelfEvolutionEngine.shared.setWorkspaceHint(url)
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

    // MARK: - Session management

    /// Save the current chat to the session store.
    func saveCurrentSession() {
        if sessions.activeSessionId == nil, messages.count > 1 {
            _ = sessions.newSession(messages: messages, workspacePath: workspaceURL?.path)
        } else {
            sessions.updateActiveSession(messages: messages, workspacePath: workspaceURL?.path)
        }
    }

    /// Start a fresh chat  (old session saved automatically).
    func newChatSession() {
        // Before clearing, archive the current session progressively
        if let currentId = sessions.activeSessionId,
           let current = sessions.sessions.first(where: { $0.id == currentId }),
           !current.messages.filter({ $0.role != .system }).isEmpty {
            SessionMemoryArchiver.shared.archiveProgressively(session: current)
        }

        saveCurrentSession()
        messages.removeAll()
        pendingDiff = nil
        showDiff    = false
        let newSession = sessions.newSession(messages: [], workspacePath: workspaceURL?.path)

        // ── Cross-session memory injection ───────────────────────────
        // Inject past sessions' JCross memory at the correct layer depth.
        let currentId = newSession.id
        let layer = sessions.activeSession?.activeLayer ?? .l2
        Task {
            let injection = SessionMemoryArchiver.shared.buildCrossSessionInjection(
                topK: 5,
                layer: layer,
                excludingSessionId: currentId
            )
            if !injection.isEmpty {
                await MainActor.run {
                    self.messages.insert(
                        ChatMessage(role: .system, content: injection),
                        at: 0
                    )
                    self.addSystemMessage("🧠 過去セッションの記憶を注入しました (\(layer.rawValue) レイヤー)")
                }
            }
        }
    }

    /// Restore a past session by its ID (loads messages + memory injection).
    func restoreSession(_ sessionId: UUID) {
        guard let session = sessions.sessions.first(where: { $0.id == sessionId }) else { return }
        saveCurrentSession()
        sessions.selectSession(sessionId)
        messages    = session.messages
        pendingDiff = nil
        showDiff    = false
        if let path = session.workspacePath {
            let url = URL(fileURLWithPath: path)
            if workspaceURL != url {
                workspaceURL = url
                terminal.workingDirectory = url
                refreshFiles()
            }
        }
        // Inject JCross memory for this session in background
        Task {
            let injection = await sessions.buildMemoryInjection(for: sessionId)
            if !injection.isEmpty {
                await MainActor.run {
                    self.messages.insert(ChatMessage(role: .system, content: injection), at: 0)
                }
            }
        }
        addSystemMessage("📂 セッション「\(session.title)」を復元しました")
    }

    // MARK: - Agent actions

    func sendMessage(with overrideText: String? = nil) {
        let text = (overrideText ?? inputText).trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAttachments = !attachedImages.isEmpty || !attachedFiles.isEmpty
        guard !text.isEmpty || hasAttachments, !isGenerating else { return }
        inputText = ""

        // Build the user message (with attachment summary if present)
        var displayContent = text
        if !attachedImages.isEmpty {
            displayContent += attachedImages.count == 1
                ? "\n📎 [Image: \(attachedImages[0].name)]"
                : "\n📎 [\(attachedImages.count) images attached]"
        }
        if !attachedFiles.isEmpty {
            for f in attachedFiles { displayContent += "\n📎 [File: \(f.lastPathComponent)]" }
        }

        let snapshotImages = attachedImages
        let snapshotFiles  = attachedFiles
        attachedImages.removeAll()
        attachedFiles.removeAll()

        messages.append(ChatMessage(role: .user, content: displayContent))
        isGenerating = true

        // Auto-create session if there isn't one yet
        if sessions.activeSessionId == nil {
            _ = sessions.newSession(messages: messages, workspacePath: workspaceURL?.path)
        }

        inferenceTask = Task {
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
                await runSinglePass(instruction: text,
                                    images: snapshotImages,
                                    files: snapshotFiles)
            }

            // Persist session after each exchange
            sessions.updateActiveSession(messages: messages, workspacePath: workspaceURL?.path)
        }
    }

    /// Cancel the currently running inference.
    func cancelGeneration() {
        inferenceTask?.cancel()
        inferenceTask = nil
        isGenerating = false
        addSystemMessage("⏹ 推論を中断しました")
    }

    // MARK: - Hybrid Engine (Privacy Shield / Cloud Direct)

    private func runHybrid(instruction: String) async {
        let context = selectedFileContent.isEmpty ? nil : selectedFileContent
        let contextFile = selectedFile
        await MainActor.run { self.privacySteps = [] }

        let snap_mode     = inferenceMode
        let snap_provider = cloudProvider
        let snap_model    = activeOllamaModel
        let snap_status   = modelStatus

        // ── Privacy Shield: PrivacyGateway (Phase 1 + Phase 2 + JCross) ──
        // cloudDirect: HybridEngine (マスキングなし、直接送信)
        if snap_mode == .privacyShield, let fileContent = context, let fileName = contextFile?.lastPathComponent {

            let snap_gemma = gemmaSemanticMaskingEnabled

            let gatewayResult = await PrivacyGateway.shared.processWithGateway(
                instruction: instruction,
                fileContent: fileContent,
                fileName: fileName,
                fileURL: contextFile,
                modelStatus: snap_status,
                activeModel: snap_model,
                provider: snap_provider,
                cortex: cortex,
                useGemmaSemanticMasking: snap_gemma
            ) { [weak self] step in
                guard let self else { return }
                await MainActor.run {
                    self.privacySteps.append(step)
                    self.messages.append(ChatMessage(role: .system, content: step))
                }
            }

            await MainActor.run {
                isGenerating = false
                // GatewayStats → MaskingStats 変換 (UI表示用)
                lastMaskingStats = MaskingStats(
                    functions: gatewayResult.maskingStats.phase1RegexMasked,
                    classes:   0,
                    variables: gatewayResult.maskingStats.phase2SemanticMasked,
                    strings:   gatewayResult.maskingStats.secretsBlocked,
                    paths:     gatewayResult.maskingStats.pathsProtected
                )
                messages.append(ChatMessage(role: .assistant, content: gatewayResult.explanation))
                if let code = gatewayResult.restoredCode, !code.isEmpty, let fileURL = contextFile {
                    let diff = FileDiff(
                        fileURL: fileURL,
                        originalContent: selectedFileContent,
                        modifiedContent: code,
                        hunks: DiffEngine.compute(original: selectedFileContent, modified: code)
                    )
                    if operationMode == .aiPriority { autoApplyDiff(diff) }
                    else { pendingDiff = diff; showDiff = true }
                }
            }
            return
        }

        // ── Cloud Direct (or no file selected in Shield mode): HybridEngine ──
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
            let rawContent = result.explanation
            // Strip artifact tags from chat display
            let displayContent = ArtifactParser.stripArtifactTags(from: rawContent)
            messages.append(ChatMessage(role: .assistant, content: displayContent))

            // Artifact detection
            if let artifact = ArtifactParser.extract(from: rawContent) {
                ingestArtifact(artifact)
            }

            if let code = result.modifiedCode, !code.isEmpty, let fileURL = contextFile {
                let diff = FileDiff(
                    fileURL: fileURL,
                    originalContent: selectedFileContent,
                    modifiedContent: code,
                    hunks: DiffEngine.compute(original: selectedFileContent, modified: code)
                )
                if operationMode == .aiPriority {
                    // AI Priority: auto-apply without confirmation
                    autoApplyDiff(diff)
                } else {
                    pendingDiff = diff
                    showDiff = true
                }
            }
        }
    }

    /// Apply a diff immediately (AI Priority mode — no confirmation).
    func autoApplyDiff(_ diff: FileDiff) {
        do {
            try diff.modifiedContent.write(to: diff.fileURL, atomically: true, encoding: .utf8)
            selectedFileContent = diff.modifiedContent
            addSystemMessage("⚡ [AI Priority] 差分を自動適用: \(diff.fileURL.lastPathComponent)")
        } catch {
            addSystemMessage("❌ 自動適用失敗: \(error.localizedDescription)")
        }
        pendingDiff = nil
        showDiff = false
    }

    /// Save artifact and show panel.
    func ingestArtifact(_ artifact: Artifact) {
        currentArtifact = artifact
        artifactHistory.insert(artifact, at: 0)
        showArtifactPanel = true
    }

    // MARK: - Agent Loop (multi-turn, scaffolding)

    private func runAgentLoop(instruction: String) async {
        let context = selectedFileContent.isEmpty ? nil : selectedFileContent
        let contextFile = selectedFile
        let snap_workspace = workspaceURL
        let snap_model = activeOllamaModel
        let snap_status = modelStatus

        // Capture and reset selfFixMode (one-shot per message)
        let snap_selfFix = selfFixMode
        selfFixMode = false

        let snap_isAIPriority = (operationMode == .aiPriority)

        await AgentLoop.shared.run(
            instruction: instruction,
            contextFile: context,
            contextFileName: contextFile?.lastPathComponent,
            workspaceURL: snap_workspace,
            modelStatus: snap_status,
            activeModel: snap_model,
            cortex: cortex,
            selfFixMode: snap_selfFix,
            isAIPriority: snap_isAIPriority,
            memoryLayer: sessions.activeSession?.activeLayer ?? .l2
        ) { [weak self] event in
            guard let self else { return }
            await MainActor.run {
                switch event {
                case .start:
                    break

                case .streamToken(let token):
                    // リアルタイムトークンを現在の assistant メッセージに追記
                    if let lastIdx = self.messages.indices.last,
                       self.messages[lastIdx].role == .assistant {
                        self.messages[lastIdx].content += token
                    } else {
                        self.messages.append(ChatMessage(role: .assistant, content: token))
                    }

                case .thinking(let t):
                    if t > 1 {
                        self.messages.append(ChatMessage(role: .system,
                            content: "🔄 Agent loop turn \(t)…"))
                    }

                case .aiMessage(let text):
                    if !text.isEmpty {
                        // Detect PATCH_FILE blocks → register in SelfEvolutionEngine
                        let patches = PatchFileParser.extract(from: text)
                        for (relPath, content) in patches {
                            SelfEvolutionEngine.shared.registerPatch(for: relPath, newContent: content)
                        }
                        // Detect <artifact> tags
                        if let artifact = ArtifactParser.extract(from: text) {
                            self.ingestArtifact(artifact)
                        }
                        // Strip patch/artifact markup from display text
                        let stripped = PatchFileParser.strip(from: ArtifactParser.stripArtifactTags(from: text))
                            .trimmingCharacters(in: .whitespacesAndNewlines)

                        if !stripped.isEmpty {
                            // ── Anti-duplicate guard ────────────────────────
                            // If streamToken already wrote a matching assistant msg,
                            // finalise it in-place instead of appending a second copy.
                            if let lastIdx = self.messages.indices.last,
                               self.messages[lastIdx].role == .assistant {
                                // Replace with the clean/stripped version
                                self.messages[lastIdx].content = stripped
                            } else {
                                // No streamed message yet → create new one
                                self.messages.append(ChatMessage(role: .assistant, content: stripped))
                            }
                        }
                        // Notify if patches detected
                        if !patches.isEmpty {
                            self.addSystemMessage("🧬 \(patches.count) 個のパッチを検出 — Self-Evolution パネルで確認できます")
                        }
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

    private func runSinglePass(instruction: String,
                               images: [AttachedImage] = [],
                               files: [URL] = []) async {
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
        switch snap_status {

        // ── Ollama path (unchanged) ─────────────────────────────────────────
        case .ollamaReady(let model):
            logProcess("Ollama/\(model)  temp=\(temperature)  maxTok=\(maxTokensOllama)", kind: .system)
            let msgId = UUID()
            messages.append(ChatMessage(id: msgId, role: .assistant, content: ""))
            let simpleMessages: [(role: String, content: String)] = [(role: "user", content: prompt)]
            let stream = OllamaClient.shared.streamGenerate(
                model: model,
                messages: simpleMessages,
                maxTokens: maxTokensOllama,
                temperature: temperature
            )
            do {
                for try await event in stream {
                    guard case .token(let token) = event else { continue }
                    tokenCount += 1; totalTokensGenerated += 1
                    if let idx = self.messages.firstIndex(where: { $0.id == msgId }) {
                        self.messages[idx].content += token
                    }
                    streamingText += token
                    let elapsed = Date().timeIntervalSince(startTime)
                    if elapsed > 0.1 { tokensPerSecond = Double(tokenCount) / elapsed }
                    if Date().timeIntervalSince(lastPerfLog) > 2 {
                        logProcess(String(format: "%.1f tok/s  │  %d tokens",
                                         Double(tokenCount)/max(elapsed,0.001), tokenCount), kind: .perf)
                        lastPerfLog = Date()
                    }
                }
            } catch { logProcess("stream error: \(error.localizedDescription)", kind: .system) }

            let elapsed1 = Date().timeIntervalSince(startTime)
            inferenceMs = Int(elapsed1 * 1000); tokensPerSecond = Double(tokenCount)/max(elapsed1,0.001)
            logProcess(String(format: "done  %.1f tok/s  │  %d tok  │  %.1fs",
                              tokensPerSecond, tokenCount, elapsed1), kind: .perf)
            let finalContent1 = messages.first(where: { $0.id == msgId })?.content ?? ""
            if agentLoopEnabled {
                let (toolCalls, _) = AgentToolParser.parse(from: finalContent1)
                let executor = AgentToolExecutor()
                for tool in toolCalls {
                    logProcess("\(tool)", kind: .tool)
                    let result = await executor.execute(tool, workspaceURL: workspaceURL)
                    if case .setWorkspace(let path) = tool {
                        let url = URL(fileURLWithPath: path)
                        workspaceURL = url; terminal.workingDirectory = url; refreshFiles()
                    }
                    addSystemMessage(result)
                }
            }

        // ── MLX direct in-process (new) ─────────────────────────────────────
        case .mlxReady:
            let m = activeMlxModel.components(separatedBy: "/").last ?? activeMlxModel
            logProcess("MLX/\(m) (direct)  temp=\(temperature)  maxTok=\(maxTokensMLX)", kind: .system)
            let msgId = UUID()
            messages.append(ChatMessage(id: msgId, role: .assistant, content: ""))
            // Nonisolated counter captured by ref via class box
            let counter = Counter()

            do {
                try await MLXRunner.shared.streamGenerateTokens(
                    prompt: prompt,
                    maxTokens: maxTokensMLX,
                    temperature: temperature,
                    onToken: { @Sendable [weak self] piece in
                        guard let self else { return }
                        counter.increment()
                        Task { @MainActor in
                            if let idx = self.messages.firstIndex(where: { $0.id == msgId }) {
                                self.messages[idx].content += piece
                            }
                            self.streamingText += piece
                            self.totalTokensGenerated += 1
                            let elapsed = Date().timeIntervalSince(startTime)
                            if elapsed > 0.1 {
                                self.tokensPerSecond = Double(counter.value) / elapsed
                            }
                        }
                    },
                    onFinish: { @Sendable [weak self] fullText in
                        guard let self else { return }
                        Task { @MainActor in
                            let elapsed = Date().timeIntervalSince(startTime)
                            self.inferenceMs = Int(elapsed * 1000)
                            self.tokensPerSecond = Double(counter.value) / max(elapsed, 0.001)
                            self.logProcess(String(format: "done  %.1f tok/s  │  %d tok  │  %.1fs",
                                                   self.tokensPerSecond, counter.value, elapsed), kind: .perf)
                            // Agent tool parsing (same as Ollama path)
                            if self.agentLoopEnabled {
                                let (toolCalls, _) = AgentToolParser.parse(from: fullText)
                                let executor = AgentToolExecutor()
                                for tool in toolCalls {
                                    self.logProcess("\(tool)", kind: .tool)
                                    let result = await executor.execute(tool, workspaceURL: self.workspaceURL)
                                    if case .setWorkspace(let path) = tool {
                                        let url = URL(fileURLWithPath: path)
                                        self.workspaceURL = url
                                        self.terminal.workingDirectory = url
                                        self.refreshFiles()
                                    }
                                    self.addSystemMessage(result)
                                }
                            }
                            self.isGenerating = false
                        }
                    }
                )
            } catch {
                logProcess("MLX error: \(error.localizedDescription)", kind: .system)
                messages.append(ChatMessage(role: .assistant,
                    content: "⚠️ MLX error: \(error.localizedDescription)"))
            }
            isGenerating = false
            return

        default:
            messages.append(ChatMessage(role: .assistant,
                content: "⚠️ No model loaded. Load an MLX model or connect Ollama first."))
            isGenerating = false
            return
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
        // Wire CI/CD error → agent auto-reply loop (once)
        registerCIErrorHook()
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

    // MARK: - CI/CD Auto-Reply Hook
    //
    // When CIValidationEngine detects a compile error after an AI-generated patch,
    // it broadcasts selfEvolutionCIError. We automatically feed the error digest
    // back to the agent as a new user message, so the agent self-corrects.

    func registerCIErrorHook() {
        NotificationCenter.default.addObserver(
            forName: .selfEvolutionCIError,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let digest = notification.userInfo?["digest"] as? String else { return }

            // Show in chat
            self.messages.append(ChatMessage(
                role: .system,
                content: "🔬 CI エラー検出 — AI が自動修正を試みます"
            ))

            // Auto-send to agent
            Task { @MainActor in
                await self.sendMessage(with: digest)
            }
        }
    }

    /// Subscribe to the [RESTART_IDE] agent event.
    /// Call from VerantyxApp.onAppear once.
    func registerRestartHook() {
        NotificationCenter.default.addObserver(
            forName: .agentRequestsRestart,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.showRestartAlert = true
        }
    }

    /// Apply pending patches then quit; rebuild.sh relaunches the app.
    func performRestart() {
        try? SelfEvolutionEngine.shared.applyAllPatches()
        let rebuildScript = NSHomeDirectory() + "/verantyx-cli/VerantyxIDE/rebuild.sh"
        if FileManager.default.fileExists(atPath: rebuildScript) {
            Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", "sleep 0.5 && bash '\(rebuildScript)'"]
                try? process.run()
            }
        }
        NSApplication.shared.terminate(nil)
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
        case .anthropicReady(let m, _):      return "Claude: \(m)"
        case .mlxReady(let m):              return "MLX: \(m.components(separatedBy: "/").last ?? m)"
        case .mlxDownloading(let m):        return "⏬ \(m.components(separatedBy: "/").last ?? m)"
        case .error(let e):                  return "Error: \(e)"
        }
    }

    var statusColor: Color {
        switch modelStatus {
        case .ready, .ollamaReady, .mlxReady, .anthropicReady: return .green
        case .error:                           return .red
        case .downloading, .connecting,
             .mlxDownloading:                  return .orange
        case .none:                            return .gray
        }
    }


    // MARK: - MLX Actions (Direct in-process — no HTTP server)

    func loadMLXModel(model: String? = nil) {
        let modelId = model ?? activeMlxModel
        modelStatus = .connecting
        mlxServerLogs.removeAll()

        Task {
            do {
                try await MLXRunner.shared.loadModel(id: modelId) { @Sendable log in
                    Task { @MainActor in
                        self.mlxServerLogs.append(log)
                        self.logProcess(log, kind: .system)
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
                        color: .orange, duration: 5
                    )
                }
            }
        }
    }

    /// Legacy alias so old call sites keep compiling.
    @available(*, deprecated, renamed: "loadMLXModel")
    func startMLXServer(model: String? = nil) { loadMLXModel(model: model) }

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
                        color: .green, duration: 4
                    )
                    self.loadMLXModel(model: repoId)
                }
            } catch {
                await MainActor.run {
                    self.modelStatus = .error("Download failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
