import Foundation
import SwiftUI
import AppKit

// MARK: - Core data models

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    var role: Role
    var content: String
    var timestamp = Date()

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

    // Diff
    @Published var pendingDiff: FileDiff?
    @Published var showDiff = false

    enum ModelStatus: Equatable {
        case none
        case connecting
        case downloading(progress: Double)
        case ready(name: String)
        case ollamaReady(model: String)
        case error(String)
    }

    // Workspace manager (lazy)
    private let workspace = WorkspaceManager()
    let agent = AgentEngine()
    let terminal = TerminalRunner()

    // MARK: - Workspace actions

    func openWorkspace() {
        guard let url = workspace.pickFolder() else { return }
        workspaceURL = url
        terminal.workingDirectory = url
        refreshFiles()
        addSystemMessage("📂 Workspace opened: \(url.lastPathComponent)")
    }

    func refreshFiles() {
        guard let root = workspaceURL else { return }
        workspaceFiles = workspace.listFiles(in: root,
            extensions: ["swift","py","ts","js","go","rs","kt","java","c","cpp","h","md","json","yaml","toml"])
    }

    func selectFile(_ url: URL) {
        selectedFile = url
        selectedFileContent = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        addSystemMessage("📄 Context: \(url.lastPathComponent)")
    }

    // MARK: - Agent actions

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isGenerating else { return }
        inputText = ""

        messages.append(ChatMessage(role: .user, content: text))
        isGenerating = true

        Task {
            let context = selectedFileContent.isEmpty ? nil : selectedFileContent
            let contextFile = selectedFile

            let result = await agent.process(
                instruction: text,
                contextFileContent: context,
                contextFileName: contextFile?.lastPathComponent,
                modelStatus: modelStatus,
                activeOllamaModel: activeOllamaModel,
                hasTerminal: workspaceURL != nil,
                workspaceURL: workspaceURL
            )

            await MainActor.run {
                messages.append(ChatMessage(role: .assistant, content: result.explanation))
                isGenerating = false

                if let diff = result.diff, !selectedFileContent.isEmpty, let fileURL = contextFile {
                    pendingDiff = FileDiff(
                        fileURL: fileURL,
                        originalContent: selectedFileContent,
                        modifiedContent: diff,
                        hunks: DiffEngine.compute(original: selectedFileContent, modified: diff)
                    )
                    showDiff = true
                }
            }

            // Execute [RUN: cmd] commands found in AI response (on MainActor via TerminalRunner)
            if !result.ranCommands.isEmpty {
                for cmd in result.ranCommands {
                    let termResult = await terminal.run(cmd, in: workspaceURL, initiatedByAI: true)

                    // Auto-fix loop: if build fails and we have a context file
                    if !termResult.succeeded, let fileContent = context, let fileName = contextFile?.lastPathComponent {
                        await MainActor.run {
                            self.addSystemMessage("🔧 Build failed — asking AI to auto-fix…")
                        }
                        let firstAIResponse = result.explanation + (result.diff ?? "")
                        let fixResult = await agent.fixWithErrorOutput(
                            originalAIResponse: firstAIResponse,
                            errorOutput: termResult.combinedForAI,
                            contextFileContent: fileContent,
                            contextFileName: fileName,
                            activeOllamaModel: activeOllamaModel
                        )
                        await MainActor.run {
                            messages.append(ChatMessage(role: .assistant, content: fixResult.explanation))
                            if let fixDiff = fixResult.diff, let fileURL = contextFile {
                                pendingDiff = FileDiff(
                                    fileURL: fileURL,
                                    originalContent: selectedFileContent,
                                    modifiedContent: fixDiff,
                                    hunks: DiffEngine.compute(original: selectedFileContent, modified: fixDiff)
                                )
                                showDiff = true
                            }
                        }
                    }
                }
            }
        }
    }

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
            let models = await OllamaClient.shared.listModels()
            await MainActor.run {
                ollamaModels = models
                if models.contains("gemma4:26b") || models.contains(activeOllamaModel) {
                    let m = models.contains(activeOllamaModel) ? activeOllamaModel : models.first!
                    modelStatus = .ollamaReady(model: m)
                    activeOllamaModel = m
                    addSystemMessage("🟢 Ollama ready: \(m)")
                } else if !models.isEmpty {
                    let m = models.first!
                    activeOllamaModel = m
                    modelStatus = .ollamaReady(model: m)
                    addSystemMessage("🟢 Ollama ready: \(m)")
                } else {
                    modelStatus = .error("No Ollama models found. Run: ollama pull gemma4:26b")
                }
            }
        }
    }

    // MARK: - Helpers

    func addSystemMessage(_ text: String) {
        messages.append(ChatMessage(role: .system, content: text))
    }

    var isReady: Bool {
        switch modelStatus {
        case .ready, .ollamaReady: return true
        default: return false
        }
    }

    var statusLabel: String {
        switch modelStatus {
        case .none:                    return "No model"
        case .connecting:              return "Connecting…"
        case .downloading(let p):      return "Downloading \(Int(p * 100))%"
        case .ready(let n):            return n
        case .ollamaReady(let m):      return "Ollama: \(m)"
        case .error(let e):            return "Error: \(e)"
        }
    }

    var statusColor: Color {
        switch modelStatus {
        case .ready, .ollamaReady:     return .green
        case .error:                   return .red
        case .downloading, .connecting: return .orange
        case .none:                    return .gray
        }
    }
}
