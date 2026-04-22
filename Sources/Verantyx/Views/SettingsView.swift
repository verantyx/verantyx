import SwiftUI

// MARK: - SettingsView
// Functional settings — all controls are wired to live AppState values.
// Tabs: Model | API Keys | Tools | Agent | Memory | Privacy | MCP

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var selectedTab: SettingsTab = .model
    @State private var testingConnection = false
    @State private var connectionTestResult: String? = nil
    @State private var testingAnthropic = false
    @State private var anthropicTestResult: String? = nil
    @State private var showAnthropicKey = false
    @State private var showOpenAIKey = false

    enum SettingsTab: String, CaseIterable {
        case general = "General"
        case model   = "Model"
        case apiKeys = "API Keys"
        case tools   = "Tools"
        case agent   = "Agent"
        case memory  = "Memory"
        case privacy = "Privacy"
        case mcp     = "MCP"

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .model:   return "cpu"
            case .apiKeys: return "key.fill"
            case .tools:   return "puzzlepiece.extension"
            case .agent:   return "bolt.circle"
            case .memory:  return "brain"
            case .privacy: return "lock.shield"
            case .mcp:     return "network"
            }
        }

        var color: Color {
            switch self {
            case .general: return Color(red: 0.7, green: 0.7, blue: 0.8)
            case .model:   return Color(red: 0.4, green: 0.7, blue: 1.0)
            case .apiKeys: return Color(red: 0.9, green: 0.7, blue: 0.3)
            case .tools:   return Color(red: 0.6, green: 0.4, blue: 1.0)
            case .agent:   return Color(red: 0.3, green: 0.9, blue: 0.6)
            case .memory:  return Color(red: 0.8, green: 0.5, blue: 1.0)
            case .privacy: return Color(red: 0.4, green: 0.9, blue: 0.5)
            case .mcp:     return Color(red: 0.3, green: 0.8, blue: 1.0)
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {

            // ── Sidebar ───────────────────────────────────────────────
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
                                .foregroundStyle(selectedTab == tab ? tab.color : .secondary)
                            Text(tab.rawValue)
                                .font(.system(size: 12, weight: .medium))

                            // Badge for API Keys
                            if tab == .apiKeys &&
                               (app.anthropicApiKey.isEmpty || app.activeAnthropicModel.isEmpty) {
                                Spacer()
                                Circle()
                                    .fill(Color(red: 0.9, green: 0.4, blue: 0.2))
                                    .frame(width: 6, height: 6)
                            }
                        }
                        .foregroundStyle(selectedTab == tab ? .white : Color(red: 0.6, green: 0.6, blue: 0.7))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            selectedTab == tab
                                ? tab.color.opacity(0.15)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .overlay(
                            selectedTab == tab
                                ? RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(tab.color.opacity(0.3), lineWidth: 0.5)
                                : nil
                        )
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 6)
                }

                Spacer()

                // Bottom: version info
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
            .frame(width: 155)
            .background(Color(red: 0.09, green: 0.09, blue: 0.12))

            Divider().opacity(0.3)

            // ── Content area ──────────────────────────────────────────
            Group {
                if selectedTab == .mcp {
                    // MCP uses its own full view
                    MCPView()
                        .environmentObject(app)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            switch selectedTab {
                            case .general: generalSettings
                            case .model:   modelSettings
                            case .apiKeys: apiKeysSettings
                            case .tools:   toolsSettings
                            case .agent:   agentSettings
                            case .memory:  memorySettings
                            case .privacy: privacySettings
                            case .mcp:     EmptyView()
                            }
                        }
                        .padding(24)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(red: 0.11, green: 0.11, blue: 0.15))
        }
        .frame(minWidth: 650, minHeight: 520)
    }

    // MARK: - General Settings (Language, Appearance)

    private var generalSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Language / 言語", icon: "globe")

            settingsCard {
                VStack(alignment: .leading, spacing: 16) {
                    // Language selector - big cards
                    HStack(spacing: 10) {
                        ForEach(AppState.UILanguage.allCases, id: \.self) { lang in
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    app.appLanguage = lang
                                }
                            } label: {
                                VStack(spacing: 8) {
                                    Text(lang.flag)
                                        .font(.system(size: 28))
                                    Text(lang.rawValue)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(app.appLanguage == lang ? .white : Color(red: 0.55, green: 0.55, blue: 0.7))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    app.appLanguage == lang
                                        ? Color(red: 0.25, green: 0.35, blue: 0.60).opacity(0.7)
                                        : Color.white.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .strokeBorder(
                                            app.appLanguage == lang
                                                ? Color(red: 0.4, green: 0.6, blue: 1.0).opacity(0.6)
                                                : Color.white.opacity(0.06),
                                            lineWidth: 1
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if app.appLanguage == .system {
                        HStack(spacing: 6) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text("System language: \(Locale.current.localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en") ?? "Unknown")")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            sectionHeader("Appearance", icon: "paintbrush")

            settingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    rowLabel("Theme") {
                        Text("Dark (fixed)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text("Verantyx uses a fixed high-contrast dark theme optimised for code editing.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)

                    Divider().opacity(0.2)

                    rowLabel("Font size (code)") {
                        Text("\(app.codeFontSize)pt")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Color(red: 0.4, green: 0.8, blue: 0.5))
                            .frame(width: 40)
                    }
                    Slider(value: Binding(
                        get: { Double(app.codeFontSize) },
                        set: { app.codeFontSize = Int($0) }
                    ), in: 9...18, step: 1)
                    .tint(Color(red: 0.4, green: 0.7, blue: 1.0))
                }
            }

            sectionHeader("Notifications", icon: "bell")

            settingsCard {
                VStack(alignment: .leading, spacing: 0) {
                    toolToggleRow(
                        icon: "checkmark.circle.fill",
                        iconColor: Color(red: 0.3, green: 0.9, blue: 0.5),
                        title: "Diff applied",
                        description: "Notify when AI changes are applied to a file",
                        isOn: $app.notifyOnDiffApply
                    )
                    Divider().opacity(0.15)
                    toolToggleRow(
                        icon: "exclamationmark.triangle.fill",
                        iconColor: Color(red: 0.9, green: 0.7, blue: 0.2),
                        title: "Agent errors",
                        description: "Notify when the agent loop encounters an error",
                        isOn: $app.notifyOnError
                    )
                }
            }
        }
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

                    rowLabel("Ollama endpoint") {
                        TextField("http://localhost:11434", text: $app.ollamaEndpoint)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(width: 200)
                            .onSubmit { app.connectOllama() }
                    }

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
                                .onChange(of: app.activeOllamaModel) { _ in app.connectOllama() }
                            }
                            Button("↺") { testConnection() }
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
                            Text("0 = deterministic").font(.system(size: 9)).foregroundStyle(.tertiary)
                            Spacer()
                            Text("0.1–0.3 = coding  ·  0.7–1.0 = creative").font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }

                    Divider().opacity(0.2)

                    VStack(alignment: .leading, spacing: 6) {
                        rowLabel("Max tokens (Ollama)") {
                            Text("\(app.maxTokensOllama)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 48)
                        }
                        Slider(value: Binding(get: { Double(app.maxTokensOllama) }, set: { app.maxTokensOllama = Int($0) }), in: 256...8192, step: 256)
                            .tint(Color(red: 0.4, green: 0.7, blue: 1.0))
                    }

                    Divider().opacity(0.2)

                    VStack(alignment: .leading, spacing: 6) {
                        rowLabel("Max tokens (MLX)") {
                            Text("\(app.maxTokensMLX)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 48)
                        }
                        Slider(value: Binding(get: { Double(app.maxTokensMLX) }, set: { app.maxTokensMLX = Int($0) }), in: 512...16384, step: 512)
                            .tint(Color(red: 0.4, green: 0.9, blue: 0.6))
                    }

                    Divider().opacity(0.2)

                    rowLabel("Streaming output") {
                        Toggle("", isOn: $app.streamingEnabled).toggleStyle(.switch).scaleEffect(0.8)
                    }
                    Text("Token-by-token streaming display. Disable only for debugging.")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }

            sectionHeader("System Prompt", icon: "text.bubble")

            settingsCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Injected at the start of every request").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset") {
                            app.systemPrompt = "You are Verantyx, an expert AI coding assistant running on Apple Silicon. Be concise and precise. Prefer code over prose."
                        }
                        .buttonStyle(.bordered).controlSize(.small)
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

    // MARK: - API Keys Settings

    private var apiKeysSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Cloud API Keys", icon: "key.fill")

            infoBlock("🔐 API keys are stored in UserDefaults (sandboxed local storage). They are never sent to any server other than the respective API endpoint.")

            // ── Anthropic ──────────────────────────────────────────────
            settingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(red: 0.9, green: 0.6, blue: 0.3).opacity(0.15))
                                .frame(width: 32, height: 32)
                            Text("A")
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(red: 0.9, green: 0.6, blue: 0.3))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Anthropic").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            Text("Claude 3.5 / 3.7 Sonnet, claude-opus-4-5")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !app.anthropicApiKey.isEmpty {
                            Text("✓ Configured")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color(red: 0.3, green: 0.9, blue: 0.5))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color(red: 0.3, green: 0.9, blue: 0.5).opacity(0.1), in: Capsule())
                        }
                    }

                    Divider().opacity(0.2)

                    rowLabel("API Key") {
                        HStack(spacing: 6) {
                            if showAnthropicKey {
                                TextField("sk-ant-...", text: $app.anthropicApiKey)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 220)
                            } else {
                                SecureField("sk-ant-...", text: $app.anthropicApiKey)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 220)
                            }
                            Button {
                                showAnthropicKey.toggle()
                            } label: {
                                Image(systemName: showAnthropicKey ? "eye.slash" : "eye")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }

                    rowLabel("Model") {
                        Picker("", selection: $app.activeAnthropicModel) {
                            Text("claude-sonnet-4-5").tag("claude-sonnet-4-5")
                            Text("claude-3-7-sonnet-20250219").tag("claude-3-7-sonnet-20250219")
                            Text("claude-opus-4-5").tag("claude-opus-4-5")
                            Text("claude-3-5-haiku-20241022").tag("claude-3-5-haiku-20241022")
                        }
                        .frame(width: 240)
                    }

                    HStack(spacing: 8) {
                        Button {
                            testAnthropic()
                        } label: {
                            if testingAnthropic {
                                HStack(spacing: 4) {
                                    ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                                    Text("Testing…")
                                }
                            } else {
                                Label("Test Connection", systemImage: "network")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(app.anthropicApiKey.isEmpty || testingAnthropic)

                        if let result = anthropicTestResult {
                            Text(result)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(result.contains("✓") ? .green : .red)
                        }
                    }
                }
            }

            // ── OpenAI ─────────────────────────────────────────────────
            settingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color(red: 0.4, green: 0.9, blue: 0.6).opacity(0.15))
                                .frame(width: 32, height: 32)
                            Image(systemName: "sparkle")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.6))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("OpenAI").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                            Text("GPT-4o, GPT-4 Turbo, o1, o3-mini")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let key = UserDefaults.standard.string(forKey: "openai_api_key"), !key.isEmpty {
                            Text("✓ Configured")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color(red: 0.3, green: 0.9, blue: 0.5))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color(red: 0.3, green: 0.9, blue: 0.5).opacity(0.1), in: Capsule())
                        }
                    }

                    Divider().opacity(0.2)

                    rowLabel("API Key") {
                        HStack(spacing: 6) {
                            let binding = Binding<String>(
                                get: { UserDefaults.standard.string(forKey: "openai_api_key") ?? "" },
                                set: { UserDefaults.standard.set($0, forKey: "openai_api_key") }
                            )
                            if showOpenAIKey {
                                TextField("sk-...", text: binding)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 220)
                            } else {
                                SecureField("sk-...", text: binding)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 220)
                            }
                            Button { showOpenAIKey.toggle() } label: {
                                Image(systemName: showOpenAIKey ? "eye.slash" : "eye")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // ── Usage tip ──────────────────────────────────────────────
            settingsCard {
                HStack(spacing: 12) {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(Color(red: 0.9, green: 0.8, blue: 0.3))
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Cloud provider selection")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        Text("Switch between providers in Privacy → Cloud provider. Each provider uses the API key configured above.")
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(2)
                    }
                }
            }
        }
    }

    // MARK: - Tools Settings

    private var toolsSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Tool Toggles", icon: "puzzlepiece.extension")
            Text("Enable or disable each tool the AI can use. Changes take effect on the next request.")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            settingsCard {
                VStack(alignment: .leading, spacing: 0) {
                    toolToggleRow(icon: "globe",          iconColor: Color(red: 0.3, green: 0.7, blue: 1.0),
                                  title: "Web Browser",   description: "AI can browse URLs using the Rust browser engine or system browser",
                                  isOn: $app.toolBrowserEnabled)
                    Divider().opacity(0.15)
                    toolToggleRow(icon: "magnifyingglass", iconColor: Color(red: 0.4, green: 0.9, blue: 0.6),
                                  title: "Web Search",    description: "AI can search the web for documentation, code examples, and answers",
                                  isOn: $app.toolWebSearchEnabled)
                    Divider().opacity(0.15)
                    toolToggleRow(icon: "terminal",       iconColor: Color(red: 0.9, green: 0.6, blue: 0.2),
                                  title: "Terminal",      description: "AI can run shell commands, build scripts, and tests",
                                  isOn: $app.toolTerminalEnabled)
                    Divider().opacity(0.15)
                    toolToggleRow(icon: "arrow.left.arrow.right", iconColor: Color(red: 0.7, green: 0.4, blue: 1.0),
                                  title: "Diff & Apply",  description: "AI can propose file changes via side-by-side diff viewer",
                                  isOn: $app.toolDiffEnabled)
                    Divider().opacity(0.15)
                    toolToggleRow(icon: "brain",          iconColor: Color(red: 0.4, green: 0.9, blue: 0.6),
                                  title: "JCross Memory", description: "AI can read/write long-term memory nodes (JCross spatial index)",
                                  isOn: $app.toolJCrossEnabled)
                }
            }

            settingsCard {
                HStack(spacing: 12) {
                    Button("Enable All") {
                        app.toolBrowserEnabled = true; app.toolWebSearchEnabled = true
                        app.toolTerminalEnabled = true; app.toolDiffEnabled = true; app.toolJCrossEnabled = true
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)

                    Button("Disable All") {
                        app.toolBrowserEnabled = false; app.toolWebSearchEnabled = false
                        app.toolTerminalEnabled = false; app.toolDiffEnabled = false; app.toolJCrossEnabled = false
                    }
                    .buttonStyle(.bordered).controlSize(.small).tint(.red)

                    Spacer()

                    let n = [app.toolBrowserEnabled, app.toolWebSearchEnabled,
                             app.toolTerminalEnabled, app.toolDiffEnabled, app.toolJCrossEnabled]
                        .filter { $0 }.count
                    Text("\(n)/5 tools enabled")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
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
                        Toggle("", isOn: $app.agentLoopEnabled).toggleStyle(.switch).scaleEffect(0.85)
                    }
                    Text("Agent can create files, scaffold projects, run build commands, and fix errors autonomously across multiple turns.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(2)

                    if app.agentLoopEnabled {
                        Divider().opacity(0.2)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Example prompts:")
                                .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                            Group {
                                Text("• \"Create a new Python calculator app\"")
                                Text("• \"Scaffold a Rust CLI project called 'todo'\"")
                                Text("• \"Set up a React TypeScript project\"")
                                Text("• \"Fix all build errors and run tests\"")
                            }
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
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
                        .toggleStyle(.switch).scaleEffect(0.85)
                    }
                    Text("Prevents context overflow by compressing old conversation turns into persistent memory nodes.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)

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
                            Text("Lower = more aggressive. Recommended: 3000 for 8B, 6000 for 27B+")
                                .font(.system(size: 9)).foregroundStyle(.tertiary)
                        }

                        Divider().opacity(0.2)

                        HStack(spacing: 16) {
                            statCard("Nodes",     value: "\(app.cortex.nodes.count)",
                                     icon: "square.stack.3d.up", color: Color(red: 0.4, green: 0.7, blue: 1.0))
                            statCard("Compressed", value: "\(app.cortex.compressedCount)",
                                     icon: "arrow.compress", color: Color(red: 0.7, green: 0.5, blue: 1.0))
                            statCard("Active",    value: "\(app.cortex.nodes.filter { $0.zone == .front || $0.zone == .near }.count)",
                                     icon: "bolt.fill", color: Color(red: 0.4, green: 0.9, blue: 0.5))
                        }

                        if !app.cortex.nodes.isEmpty {
                            Divider().opacity(0.2)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Memory nodes")
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                                ForEach(app.cortex.nodes.prefix(15)) { node in memoryNodeRow(node) }
                                if app.cortex.nodes.count > 15 {
                                    Text("… and \(app.cortex.nodes.count - 15) more")
                                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                                }
                            }
                        }

                        Divider().opacity(0.2)

                        Button(role: .destructive) { app.cortex.clearAll() } label: {
                            Label("Clear All Memory", systemImage: "trash").font(.system(size: 11))
                        }
                        .buttonStyle(.bordered).controlSize(.small).tint(.red)
                    }
                }
            }
        }
    }

    // MARK: - Privacy Settings

    private var privacySettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader("Privacy & Mode", icon: "lock.shield")

            // ── Inference mode ─────────────────────────────────────────
            settingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    rowLabel("Inference mode") {
                        Picker("", selection: $app.inferenceMode) {
                            Text("Local Only").tag(InferenceMode.localOnly)
                            Text("Privacy Shield").tag(InferenceMode.privacyShield)
                            Text("Cloud Direct").tag(InferenceMode.cloudDirect)
                        }
                        .pickerStyle(.segmented).frame(width: 260)
                    }

                    switch app.inferenceMode {
                    case .localOnly:
                        infoBlock("🔒 100% offline. No data leaves your machine. Runs on Apple Silicon via Ollama or MLX.")
                    case .privacyShield:
                        infoBlock("🛡 Code is anonymized before being sent to cloud. Real identifiers stay on your Mac. Cloud only sees abstract logic.")
                    case .cloudDirect:
                        infoBlock("☁️ Direct cloud inference. Fastest responses, but code is sent as-is to the provider.")
                    }

                    if app.inferenceMode != .localOnly {
                        Divider().opacity(0.2)
                        rowLabel("Cloud provider") {
                            Picker("", selection: $app.cloudProvider) {
                                Text("Claude").tag(CloudProvider.claude)
                                Text("GPT-4").tag(CloudProvider.openai)
                                Text("Gemini").tag(CloudProvider.gemini)
                            }
                            .pickerStyle(.segmented).frame(width: 160)
                        }
                    }
                }
            }

            // ── Privacy Gateway settings (Privacy Shield only) ─────────
            if app.inferenceMode == .privacyShield {
                sectionHeader("Privacy Gateway Configuration", icon: "shield.lefthalf.filled")

                settingsCard {
                    VStack(alignment: .leading, spacing: 0) {
                        // Phase 1: Always on
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color(red: 0.4, green: 0.9, blue: 0.5).opacity(0.15))
                                    .frame(width: 32, height: 32)
                                Text("P1")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.5))
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text("Regex Masking")
                                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                                    Text("Always ON")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.5))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color(red: 0.4, green: 0.9, blue: 0.5).opacity(0.1), in: Capsule())
                                }
                                Text("Detects FUNC_xxx, CLASS_xxx, VAR_xxx, secrets via regex patterns. Fast, deterministic.")
                                    .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(2)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 12)

                        Divider().opacity(0.15)

                        // Phase 2: Togglable
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(app.gemmaSemanticMaskingEnabled
                                          ? Color(red: 0.8, green: 0.5, blue: 1.0).opacity(0.15)
                                          : Color.white.opacity(0.05))
                                    .frame(width: 32, height: 32)
                                Text("P2")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(app.gemmaSemanticMaskingEnabled
                                                     ? Color(red: 0.8, green: 0.5, blue: 1.0)
                                                     : .secondary)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Gemma Semantic Scan")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(app.gemmaSemanticMaskingEnabled ? .white : .secondary)
                                Text("Local Gemma LLM detects domain-specific identifiers missed by regex (e.g. paymentGatewayURL → SEMID_000). Slower but more thorough.")
                                    .font(.system(size: 10)).foregroundStyle(.secondary).lineSpacing(2)
                            }
                            Spacer()
                            Toggle("", isOn: $app.gemmaSemanticMaskingEnabled)
                                .toggleStyle(.switch).scaleEffect(0.85)
                        }
                        .padding(.vertical, 12)
                        .opacity(app.gemmaSemanticMaskingEnabled ? 1.0 : 0.6)
                        .animation(.easeInOut(duration: 0.15), value: app.gemmaSemanticMaskingEnabled)

                        if !app.gemmaSemanticMaskingEnabled {
                            infoBlock("⚡️ Regex-only mode: ~3× faster. Recommended when Ollama is not loaded or for large files. Some domain-specific identifiers may not be masked.")
                        }
                    }
                }

                // Processing pipeline visual
                settingsCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Processing Pipeline")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)

                        HStack(spacing: 4) {
                            pipelineStep("JCross\nQuery",   color: Color(red: 0.8, green: 0.5, blue: 1.0), number: 1)
                            pipelineArrow()
                            pipelineStep("Regex\nMask",     color: Color(red: 0.4, green: 0.9, blue: 0.5), number: 2)
                            pipelineArrow()
                            if app.gemmaSemanticMaskingEnabled {
                                pipelineStep("Gemma\nScan", color: Color(red: 0.9, green: 0.6, blue: 0.2), number: 3)
                                pipelineArrow()
                            }
                            pipelineStep("Cloud\nAPI",      color: Color(red: 0.4, green: 0.7, blue: 1.0), number: app.gemmaSemanticMaskingEnabled ? 4 : 3)
                            pipelineArrow()
                            pipelineStep("Gemma\nRestore",  color: Color(red: 0.9, green: 0.4, blue: 0.4), number: app.gemmaSemanticMaskingEnabled ? 5 : 4)
                        }
                        .animation(.easeInOut(duration: 0.2), value: app.gemmaSemanticMaskingEnabled)

                        Text("★ Your real code never reaches external APIs — only abstract logic identifiers.")
                            .font(.system(size: 10)).foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.5))
                            .padding(.top, 4)
                    }
                }
            }

            // ── Airplane mode indicator ────────────────────────────────
            settingsCard {
                HStack(spacing: 12) {
                    Image(systemName: "airplane")
                        .font(.system(size: 20))
                        .foregroundStyle(app.inferenceMode == .localOnly
                                         ? Color(red: 0.3, green: 1.0, blue: 0.5) : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.inferenceMode == .localOnly ? "Airplane-mode capable ✓" : "Requires internet connection")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(app.inferenceMode == .localOnly ? .white : .secondary)
                        Text("Local Only mode works with Wi-Fi completely disabled")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
            }
        }
    }

    // MARK: - Pipeline step helpers

    private func pipelineStep(_ label: String, color: Color, number: Int) -> some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().fill(color.opacity(0.2)).frame(width: 28, height: 28)
                Text("\(number)").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(color)
            }
            Text(label)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(minWidth: 36)
    }

    private func pipelineArrow() -> some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 8))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
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
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
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
                Text(title).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isOn.wrappedValue ? .white : .secondary)
                Text(description).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(2)
            }
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).scaleEffect(0.8)
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
        .frame(maxWidth: .infinity).padding(10)
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
                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
    }

    private func infoBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color(red: 0.6, green: 0.75, blue: 0.9))
            .lineSpacing(3).padding(10)
            .background(Color(red: 0.12, green: 0.20, blue: 0.30).opacity(0.8),
                        in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: - Actions

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
                    connectionTestResult = "✓ \(models.count) model(s): \(models.prefix(3).joined(separator: ", "))"
                    app.ollamaModels = models
                    if models.contains(app.activeOllamaModel) {
                        app.modelStatus = .ollamaReady(model: app.activeOllamaModel)
                    }
                }
            }
        }
    }

    private func testAnthropic() {
        testingAnthropic = true
        anthropicTestResult = nil
        Task {
            AnthropicClient.shared.configure(apiKey: app.anthropicApiKey)
            // Send a minimal ping request
            let stream = AnthropicClient.shared.streamGenerate(
                model: app.activeAnthropicModel,
                systemPrompt: "You are a test assistant.",
                messages: [("user", "Respond with exactly: OK")],
                maxTokens: 10
            )
            var result = ""
            do {
                for try await event in stream {
                    if case .token(let t) = event { result += t }
                    if case .done = event { break }
                    if case .error(let e) = event { result = "ERROR: \(e)"; break }
                }
            } catch {
                result = "ERROR: \(error.localizedDescription)"
            }
            await MainActor.run {
                testingAnthropic = false
                if result.lowercased().contains("ok") || result.lowercased().contains("error") == false {
                    anthropicTestResult = "✓ Connected (\(app.activeAnthropicModel))"
                    app.modelStatus = .anthropicReady(model: app.activeAnthropicModel, maskedKey: "sk-ant-***")
                } else {
                    anthropicTestResult = "✗ \(result.prefix(60))"
                }
            }
        }
    }
}
