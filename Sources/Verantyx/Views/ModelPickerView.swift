import SwiftUI

// MARK: - ModelPickerView
// Popover for selecting Ollama model or entering HuggingFace Repo ID.

struct ModelPickerView: View {
    @EnvironmentObject var app: AppState
    @State private var tab: Tab = .ollama

    enum Tab: String, CaseIterable {
        case ollama = "Ollama"
        case huggingface = "HuggingFace"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Tab picker
            Picker("Source", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)

            Divider()

            switch tab {
            case .ollama:  ollamaTab
            case .huggingface: huggingFaceTab
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Ollama tab

    private var ollamaTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Status
            HStack {
                Circle()
                    .fill(app.statusColor)
                    .frame(width: 8, height: 8)
                Text(app.statusLabel)
                    .font(.callout)
                Spacer()
                Button("Refresh") {
                    Task { await OllamaClient.shared.resetAvailability() }
                    app.connectOllama()
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }

            if app.ollamaModels.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No models found. Install Ollama and run:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("ollama pull gemma4:26b")
                        .font(.system(.caption, design: .monospaced))
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                }
            } else {
                Text("Installed models:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(app.ollamaModels, id: \.self) { model in
                    Button {
                        app.activeOllamaModel = model
                        app.modelStatus = .ollamaReady(model: model)
                        app.addSystemMessage("🟢 Switched to \(model)")
                    } label: {
                        HStack {
                            Image(systemName: app.activeOllamaModel == model
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(app.activeOllamaModel == model ? Color.accentColor : Color.secondary)
                            Text(model)
                                .font(.system(.callout, design: .monospaced))
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Button {
                app.connectOllama()
            } label: {
                Label("Connect Ollama", systemImage: "link")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(12)
    }

    // MARK: - HuggingFace tab

    private var huggingFaceTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Enter a HuggingFace MLX model Repo ID to download and use locally.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
                      text: $app.customHFRepoId)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))

            // Popular models quick-pick
            VStack(alignment: .leading, spacing: 6) {
                Text("Popular models:")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                ForEach(popularModels, id: \.self) { repo in
                    Button {
                        app.customHFRepoId = repo
                    } label: {
                        HStack {
                            Image(systemName: "cube.box")
                                .font(.caption)
                            Text(repo.components(separatedBy: "/").last ?? repo)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            if case .downloading(let p) = app.modelStatus {
                ProgressView(value: p)
                    .tint(Color.accentColor)
                Text("Downloading… \(Int(p * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                downloadModel()
            } label: {
                Label(
                    downloadLabel,
                    systemImage: "arrow.down.circle"
                )
                .frame(maxWidth: .infinity)
                .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .disabled(app.customHFRepoId.isEmpty || {
                if case .downloading = app.modelStatus { return true }
                return false
            }())
        }
        .padding(12)
    }

    private var downloadLabel: String {
        if case .downloading(let p) = app.modelStatus { return "Downloading \(Int(p * 100))%" }
        return "Download & Use"
    }

    private func downloadModel() {
        let repoId = app.customHFRepoId.trimmingCharacters(in: .whitespaces)
        guard !repoId.isEmpty else { return }
        app.addSystemMessage("⬇️ Downloading \(repoId)…")
        app.modelStatus = .downloading(progress: 0)

        // TODO: wire MLXModelDownloader in Phase 2
        // For now, show a placeholder
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            await MainActor.run {
                app.modelStatus = .error("MLX download: connect ModelDownloader in Phase 2")
                app.addSystemMessage("ℹ️ Use Ollama for now — MLX download coming in v0.2")
            }
        }
    }

    private let popularModels = [
        "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
        "mlx-community/gemma-3-12b-it-4bit",
        "mlx-community/Phi-4-mini-instruct-4bit",
        "mlx-community/Mistral-7B-Instruct-v0.3-4bit",
    ]
}
