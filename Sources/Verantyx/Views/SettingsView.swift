import SwiftUI

// MARK: - SettingsView
// Functional settings — all controls are wired to live AppState values.
// Tab-based: Model | Tools | Memory | Agent | Privacy

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var selectedTab: SettingsTab = .model
    @State private var testingConnection = false
    @State private var connectionTestResult: String? = nil

    enum SettingsTab: String, CaseIterable {
        case model   = "Model"
        case tools   = "Tools"
        case agent   = "Agent"
        case memory  = "Memory"
        case privacy = "Privacy"

        var icon: String {
            switch self {
            case .model:   return "cpu"
            case .tools:   return "puzzlepiece.extension"
            case .agent:   return "bolt.circle"
            case .memory:  return "brain"
            case .privacy: return "lock.shield"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {

            // ── Sidebar tabs ──────────────────────────────────────────
            VStack(alignment: .leading, spacing: 2) {
                Text("SETTINGS")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.top, 16)
                    .padding(.bottom, 8)

                ForEach(SettingsTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) { selectedTab = tab }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 11))
                                .frame(width: 16)
                            Text(tab.rawValue)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(selectedTab == tab ? .white : Color(red: 0.6, green: 0.6, blue: 0.7))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            selectedTab == tab
                                ? Color(red: 0.25, green: 0.35, blue: 0.55).opacity(0.5)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6)
                }

                Spacer()

                // Version info at bottom of sidebar
                VStack(alignment: .leading, spacing: 2) {
                    Text("Verantyx v0.1")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Text("Apple Silicon native")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.quaternary)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
            }
            .frame(width: 150)
            .background(Color(red: 0.09, green: 0.09, blue: 0.12))

            Divider().opacity(0.3)

            // ── Content area ──────────────────────────────────────────
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selectedTab {
                    case .model:   modelSettings
                    case .tools:   toolsSettings
                    case .agent:   agentSettings
                    case .memory:  memorySettings
                    case .privacy: privacySettings
                    }
                }
                .padding(24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.11, green: 0.11, blue: 0.15))
        }
        .frame(minWidth: 580, minHeight: 480)
    }

    // MARK: - Model Settings

    private var modelSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Model Configuration", icon: "cpu")

            // Active backend status
            settingsCard {
                VStack(alignment: .leading, spacing: 12) {
                    rowLabel("Active backend") {
                        HStack(spacing: 6) {
                            Circle().fill(app.statusColor).frame(width: 7, height: 7)
                            Text(app.statusLabel)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider().opacity(0.2)

                    // Ollama endpoint
                    rowLabel("Ollama endpoint") {
                        TextField("http://localhost:11434", text: $app.ollamaEndpoint)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 200)
                            .onSubmit { app.connectOllama() }
                    }

                    // Active Ollama model
                    rowLabel("Ollama model") {
                        HStack(spacing: 6) {
                            if app.ollamaModels.isEmpty {
                                TextField("gemma4:26b", text: $app.activeOllamaModel)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 200)
                            } else {
                                Picker("", selection: $app.activeOllamaModel) {
                                    ForEach(app.ollamaModels, id: \.self) { m in
                                        Text(m).tag(m)
                                    }
                                }
                                .frame(width: 200)
                                .onChange(of: app.activeOllamaModel) { _ in
                                    app.connectOllama()
                                }
                            }
                            Button("↺") {
                                testConnection()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(testingConnection)
                        }
                    }

                    if let result = connectionTestResult {
                        Text(result)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(result.contains("✓") ? .green : .red)
                    }

                    Divider().opacity(0.2)

                    // MLX model
                    rowLabel("MLX model") {
                        TextField("mlx-community/...", text: $app.activeMlxModel)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 260)
                    }
                }
            }

            sectionHeader("Inference Parameters", icon: "slider.horizontal.3")

            settingsCard {
                VStack(alignment: .leading, spacing: 14) {

                    // Temperature
                    VStack(alignment: .leading, spacing: 6) {
                        rowLabel("Temperature") {
                            Text(String(format: "%.2f", app.temperature))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(tempColor)
                                .frame(width: 40)
                        }
                        Slider(value: $app.temperature, in: 0...1.5, step: 0.05)
                            .tint(tempColor)
                        HStack {
                            Text("0 = deterministic")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Text("0.1–0.3 = coding  ·  0.7–1.0 = creative")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Divider().opacity(0.2)

                    // Max tokens — Ollama
                    VStack(alignment: .leading, spacing: 6) {
                        rowLabel("Max tokens (Ollama)") {
                            Text("\(app.maxTokensOllama)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 48)
                        }
                        Slider(value: Binding(
                            get: { Double(app.maxTokensOllama) },
                            set: { app.maxTokensOllama = Int($0) }
                        ), in: 256...8192, step: 256)
                        .tint(Color(red: 0.4, green: 0.7, blue: 1.0))
                    }

                    Divider().opacity(0.2)

                    // Max tokens — MLX
                    VStack(alignment: .leading, spacing: 6) {
                        rowLabel("Max tokens (MLX)") {
                            Text("\(app.maxTokensMLX)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 48)
                        }
                        Slider(value: Binding(
                            get: { Double(app.maxTokensMLX) },
                            set: { app.maxTokensMLX = Int($0) }
                        ), in: 512...16384, step: 512)
                        .tint(Color(red: 0.4, green: 0.9, blue: 0.6))
                    }

                    Divider().opacity(0.2)

                    // Streaming
                    rowLabel("Streaming output") {
                        Toggle("", isOn: $app.streamingEnabled)
                            .toggleStyle(.switch)
                            .scaleEffect(0.8)
                    }
                    Text("Token-by-token streaming display. Disable only for debugging.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            sectionHeader("System Prompt", icon: "text.bubble")

            settingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Injected at the start of every request")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset") {
                            app.systemPrompt = "You are Verantyx, an expert AI coding assistant running on Apple Silicon. Be concise and precise. Prefer code over prose."
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    TextEditor(text: $app.systemPrompt)
                        .font(.system(size: 11, design: .monospaced))
                        .frame(minHeight: 80, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .background(Color(red: 0.08, green: 0.08, blue: 0.12))
                        .cornerRadius(6)
                }
            }
        }
    }

    // MARK: - Tools Settings

    private var toolsSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Tool Toggles", icon: "puzzlepiece.extension")
            Text("Enable or disable each tool the AI can use. Changes take effect on the next request.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            settingsCard {
                VStack(alignment: .leading, spacing: 0) {
                    toolToggleRow(
                        icon: "globe",
                        iconColor: Color(red: 0.3, green: 0.7, blue: 1.0),
                        title: "Web Browser",
                        description: "AI can browse URLs using the Rust browser engine or system browser",
                        isOn: $app.toolBrowserEnabled
                    )
                    Divider().opacity(0.15)
                    toolToggleRow(
                        icon: "magnifyingglass",
                        iconColor: Color(red: 0.4, green: 0.9, blue: 0.6),
                        title: "Web Search",
                        description: "AI can search the web for documentation, code examples, and answers",
                        isOn: $app.toolWebSearchEnabled
                    )
                    Divider().opacity(0.15)
                    toolToggleRow(
                        icon: "terminal",
                        iconColor: Color(red: 0.9, green: 0.6, blue: 0.2),
                        title: "Terminal Execution",
                        description: "AI can run shell commands, build scripts, and tests",
                        isOn: $app.toolTerminalEnabled
                    )
                    Divider().opacity(0.15)
                    toolToggleRow(
                        icon: "arrow.left.arrow.right",
                        iconColor: Color(red: 0.7, green: 0.4, blue: 1.0),
                        title: "Diff & Apply",
                        description: "AI can propose file changes via side-by-side diff viewer",
                        isOn: $app.toolDiffEnabled
                    )
                    Divider().opacity(0.15)
                    toolToggleRow(
                        icon: "brain",
                        iconColor: Color(red: 0.4, green: 0.9, blue: 0.6),
                        title: "JCross Memory",
                        description: "AI can read/write long-term memory nodes (JCross spatial index)",
                        isOn: $app.toolJCrossEnabled
                    )
                }
            }

            settingsCard {
                HStack(spacing: 12) {
                    Button("Enable All") {
                        app.toolBrowserEnabled   = true
                        app.toolWebSearchEnabled = true
                        app.toolTerminalEnabled  = true
                        app.toolDiffEnabled      = true
                        app.toolJCrossEnabled    = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Disable All") {
                        app.toolBrowserEnabled   = false
                        app.toolWebSearchEnabled = false
                        app.toolTerminalEnabled  = false
                        app.toolDiffEnabled      = false
                        app.toolJCrossEnabled    = false
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)

                    Spacer()

                    let enabledCount = [app.toolBrowserEnabled, app.toolWebSearchEnabled,
                                        app.toolTerminalEnabled, app.toolDiffEnabled, app.toolJCrossEnabled]
                        .filter { $0 }.count
                    Text("\(enabledCount)/5 tools enabled")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Agent Settings

    private var agentSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Agent Loop", icon: "bolt.circle")

            settingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    rowLabel("Autonomous Mode") {
                        Toggle("", isOn: $app.agentLoopEnabled)
                            .toggleStyle(.switch)
                            .scaleEffect(0.85)
                    }
                    Text("Agent can create files, scaffold projects, run build commands, and fix errors autonomously across multiple turns.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)

                    if app.agentLoopEnabled {
                        Divider().opacity(0.2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Example prompts:")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            Group {
                                Text("• \"Create a new Python calculator app\"")
                                Text("• \"Scaffold a Rust CLI project called 'todo'\"")
                                Text("• \"Set up a React TypeScript project\"")
                                Text("• \"Fix all build errors and run tests\"")
                            }
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Memory Settings

    private var memorySettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Cortex Memory", icon: "brain")

            settingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    rowLabel("Enable Cortex") {
                        Toggle("", isOn: Binding(
                            get: { app.cortex.isEnabled },
                            set: { app.cortex.isEnabled = $0 }
                        ))
                        .toggleStyle(.switch)
                        .scaleEffect(0.85)
                    }
                    Text("Prevents context overflow by compressing old conversation turns into persistent memory nodes.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    if app.cortex.isEnabled {
                        Divider().opacity(0.2)

                        VStack(alignment: .leading, spacing: 6) {
                            rowLabel("Compression threshold") {
                                Text("\(app.cortex.contextThreshold) tokens")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.5))
                                    .frame(width: 80)
                            }
                            Slider(value: Binding(
                                get: { Double(app.cortex.contextThreshold) },
                                set: { app.cortex.contextThreshold = Int($0) }
                            ), in: 500...8000, step: 500)
                            .tint(Color(red: 0.4, green: 0.7, blue: 1.0))
                            Text("Lower = more aggressive compression. Recommended: 3000 for 8B, 6000 for 27B+")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }

                        Divider().opacity(0.2)

                        HStack(spacing: 16) {
                            statCard("Nodes",        value: "\(app.cortex.nodes.count)",
                                     icon: "square.stack.3d.up",
                                     color: Color(red: 0.4, green: 0.7, blue: 1.0))
                            statCard("Compressed",   value: "\(app.cortex.compressedCount)",
                                     icon: "arrow.compress",
                                     color: Color(red: 0.7, green: 0.5, blue: 1.0))
                            statCard("Active",
                                     value: "\(app.cortex.nodes.filter { $0.zone == .front || $0.zone == .near }.count)",
                                     icon: "bolt.fill",
                                     color: Color(red: 0.4, green: 0.9, blue: 0.5))
                        }

                        if !app.cortex.nodes.isEmpty {
                            Divider().opacity(0.2)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Memory nodes")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                ForEach(app.cortex.nodes.prefix(15)) { node in
                                    memoryNodeRow(node)
                                }
                                if app.cortex.nodes.count > 15 {
                                    Text("… and \(app.cortex.nodes.count - 15) more")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }

                        Divider().opacity(0.2)

                        Button(role: .destructive) {
                            app.cortex.clearAll()
                        } label: {
                            Label("Clear All Memory", systemImage: "trash")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(.red)
                    }
                }
            }
        }
    }

    // MARK: - Privacy Settings

    private var privacySettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Privacy & Mode", icon: "lock.shield")

            settingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    rowLabel("Inference mode") {
                        Picker("", selection: $app.inferenceMode) {
                            Text("Local Only").tag(InferenceMode.localOnly)
                            Text("Privacy Shield").tag(InferenceMode.privacyShield)
                            Text("Cloud Direct").tag(InferenceMode.cloudDirect)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 260)
                    }

                    switch app.inferenceMode {
                    case .localOnly:
                        infoBlock("🔒 100% offline. No data leaves your machine. Runs on Apple Silicon via Ollama or MLX.")
                    case .privacyShield:
                        infoBlock("🛡 Code is anonymized before being sent to cloud. PII, secrets, and identifiers are masked.")
                    case .cloudDirect:
                        infoBlock("☁️ Direct cloud inference. Fastest responses, but data is sent as-is to the provider.")
                    }

                    if app.inferenceMode != .localOnly {
                        Divider().opacity(0.2)
                        rowLabel("Cloud provider") {
                            Picker("", selection: $app.cloudProvider) {
                                Text("Claude").tag(CloudProvider.claude)
                                Text("GPT-4").tag(CloudProvider.openai)
                                Text("Gemini").tag(CloudProvider.gemini)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 160)
                        }
                    }
                }
            }

            // Airplane mode indicator
            settingsCard {
                HStack(spacing: 12) {
                    Image(systemName: "airplane")
                        .font(.system(size: 20))
                        .foregroundStyle(app.inferenceMode == .localOnly
                                         ? Color(red: 0.3, green: 1.0, blue: 0.5)
                                         : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.inferenceMode == .localOnly
                             ? "Airplane-mode capable ✓"
                             : "Requires internet connection")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(app.inferenceMode == .localOnly ? .white : .secondary)
                        Text("Local Only mode works with Wi-Fi completely disabled")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Components

    private func sectionHeader(_ title: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 0.4, green: 0.7, blue: 1.0))
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
    }

    private func rowLabel<Content: View>(_ label: String, @ViewBuilder trailing: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 0.75, green: 0.75, blue: 0.88))
            Spacer()
            trailing()
        }
    }

    private func toolToggleRow(icon: String, iconColor: Color, title: String,
                                description: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(isOn.wrappedValue ? iconColor : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isOn.wrappedValue ? .white : .secondary)
                Text(description)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }

            Spacer()

            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .scaleEffect(0.8)
        }
        .padding(.vertical, 10)
        .opacity(isOn.wrappedValue ? 1.0 : 0.6)
        .animation(.easeInOut(duration: 0.15), value: isOn.wrappedValue)
    }

    private func statCard(_ label: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(color)
            Text(value).font(.system(size: 16, weight: .bold, design: .monospaced)).foregroundStyle(.white)
            Text(label).font(.system(size: 9)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
    }

    private func memoryNodeRow(_ node: MemoryNode) -> some View {
        HStack(spacing: 8) {
            Circle().fill(zoneColor(node.zone)).frame(width: 5, height: 5)
            Text(node.key)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(red: 0.7, green: 0.7, blue: 0.9))
                .frame(width: 130, alignment: .leading)
            Text(node.value.prefix(60) + (node.value.count > 60 ? "…" : ""))
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    private func infoBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color(red: 0.6, green: 0.75, blue: 0.9))
            .lineSpacing(3)
            .padding(10)
            .background(Color(red: 0.12, green: 0.20, blue: 0.30).opacity(0.8),
                        in: RoundedRectangle(cornerRadius: 6))
    }

    private func zoneColor(_ zone: MemoryNode.Zone) -> Color {
        switch zone {
        case .front: return Color(red: 0.4, green: 0.9, blue: 0.5)
        case .near:  return Color(red: 0.4, green: 0.7, blue: 1.0)
        case .mid:   return Color(red: 0.8, green: 0.6, blue: 1.0)
        case .deep:  return Color(red: 0.5, green: 0.5, blue: 0.7)
        }
    }

    private var tempColor: Color {
        app.temperature < 0.3 ? Color(red: 0.3, green: 0.9, blue: 0.5)
        : app.temperature < 0.7 ? Color(red: 0.9, green: 0.8, blue: 0.3)
        : Color(red: 0.9, green: 0.5, blue: 0.3)
    }

    /// Test Ollama connection and update modelStatus
    private func testConnection() {
        testingConnection = true
        connectionTestResult = nil
        Task {
            let models = await OllamaClient.shared.listModels()
            await MainActor.run {
                testingConnection = false
                if models.isEmpty {
                    connectionTestResult = "✗ No models found at \(app.ollamaEndpoint)"
                } else {
                    connectionTestResult = "✓ \(models.count) model(s) found: \(models.prefix(3).joined(separator: ", "))"
                    app.ollamaModels = models
                    if models.contains(app.activeOllamaModel) {
                        app.modelStatus = .ollamaReady(model: app.activeOllamaModel)
                    }
                }
            }
        }
    }
}
