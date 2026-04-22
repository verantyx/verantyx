import SwiftUI

// MARK: - SettingsView
// Settings panel: Cortex ON/OFF, context threshold, model defaults

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @State private var storageSizeStr: String = "…"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // ── CORTEX MEMORY ──────────────────────────────────────
                settingsSection(title: "🧠 Cortex Memory", icon: "brain") {
                    VStack(alignment: .leading, spacing: 16) {
                        // Master toggle
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Enable Cortex Memory")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.white)
                                Text("Prevents AI Alzheimer's by compressing old context\ninto persistent memory nodes (JCross-inspired).")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.7))
                                    .lineSpacing(2)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                            get: { app.cortex.isEnabled },
                            set: { app.cortex.isEnabled = $0 }
                        ))
                                .toggleStyle(.switch)
                                .scaleEffect(0.85)
                        }

                        if app.cortex.isEnabled {
                            Divider().opacity(0.2)

                            // Context threshold
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text("Compression threshold")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Color(red: 0.7, green: 0.7, blue: 0.85))
                                    Spacer()
                                    Text("\(app.cortex.contextThreshold) tokens")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(Color(red: 0.5, green: 0.8, blue: 0.5))
                                }
                                Slider(
                                    value: Binding(
                                        get: { Double(app.cortex.contextThreshold) },
                                        set: { app.cortex.contextThreshold = Int($0) }
                                    ),
                                    in: 500...8000, step: 500
                                )
                                .tint(Color(red: 0.4, green: 0.7, blue: 1.0))
                                Text("Lower = more aggressive compression. Recommended: 3000 for 8B models, 6000+ for 27B+")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color(red: 0.4, green: 0.4, blue: 0.6))
                            }

                            Divider().opacity(0.2)

                            // Memory stats
                            HStack(spacing: 20) {
                                statCard(
                                    label: "Nodes",
                                    value: "\(app.cortex.nodes.count)",
                                    icon: "square.stack.3d.up",
                                    color: Color(red: 0.4, green: 0.7, blue: 1.0)
                                )
                                statCard(
                                    label: "Compressions",
                                    value: "\(app.cortex.compressedCount)",
                                    icon: "arrow.compress",
                                    color: Color(red: 0.7, green: 0.5, blue: 1.0)
                                )
                                statCard(
                                    label: "Front/Near",
                                    value: "\(app.cortex.nodes.filter { $0.zone == .front || $0.zone == .near }.count)",
                                    icon: "bolt.fill",
                                    color: Color(red: 0.4, green: 0.9, blue: 0.5)
                                )
                            }

                            Divider().opacity(0.2)

                            // Memory node list
                            if !app.cortex.nodes.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Stored Memory Nodes")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.7))

                                    ForEach(app.cortex.nodes.prefix(20)) { node in
                                        memoryNodeRow(node)
                                    }
                                    if app.cortex.nodes.count > 20 {
                                        Text("… and \(app.cortex.nodes.count - 20) more")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Color.secondary)
                                    }
                                }
                            }

                            Divider().opacity(0.2)

                            // Clear button
                            Button {
                                app.cortex.clearAll()
                            } label: {
                                Label("Clear All Memory", systemImage: "trash")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(red: 0.9, green: 0.4, blue: 0.4))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(Color(red: 0.9, green: 0.4, blue: 0.4).opacity(0.4), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        } // end if isEnabled
                    }
                }

                // ── AGENT ───────────────────────────────────────────────
                settingsSection(title: "⚡ Agent Loop", icon: "bolt.circle") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Autonomous Mode")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color.white)
                                Text("Agent can create files, directories, and run commands without a workspace being open.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.7))
                            }
                            Spacer()
                            Toggle("", isOn: $app.agentLoopEnabled)
                                .toggleStyle(.switch)
                                .scaleEffect(0.85)
                        }

                        if app.agentLoopEnabled {
                            infoBlock("""
                            When enabled, you can say things like:
                            • "Create a new Python calculator app"
                            • "Scaffold a Rust CLI project called 'todo'"
                            • "Set up a React TypeScript project"
                            
                            The agent will create files, run commands,\nand open the workspace automatically.
                            """)
                        }
                    }
                }

                // ── MODEL ───────────────────────────────────────────────
                settingsSection(title: "🤖 Model", icon: "cpu") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Ollama endpoint")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(red: 0.7, green: 0.7, blue: 0.85))
                            Spacer()
                            Text("localhost:11434")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color(red: 0.5, green: 0.5, blue: 0.65))
                        }
                        HStack {
                            Text("Default model")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(red: 0.7, green: 0.7, blue: 0.85))
                            Spacer()
                            TextField("gemma4:26b", text: $app.activeOllamaModel)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 180)
                        }
                    }
                }

                Spacer(minLength: 20)
            }
            .padding(20)
        }
        .background(Color(red: 0.11, green: 0.11, blue: 0.14))
        .frame(minWidth: 480, minHeight: 500)
        .navigationTitle("Settings")
    }

    // MARK: - Components

    private func settingsSection<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.4, green: 0.7, blue: 1.0))
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.white)
            }
            content()
                .padding(14)
                .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5)
                )
        }
    }

    private func statCard(label: String, value: String, icon: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 0.5, green: 0.5, blue: 0.65))
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func memoryNodeRow(_ node: MemoryNode) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(zoneColor(node.zone))
                .frame(width: 6, height: 6)
            Text(node.key)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color(red: 0.7, green: 0.7, blue: 0.9))
                .frame(width: 140, alignment: .leading)
            Text(node.value.prefix(60) + (node.value.count > 60 ? "…" : ""))
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.7))
                .lineLimit(1)
            Spacer()
            Text(String(format: "%.1f", node.importance))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color(red: 0.4, green: 0.4, blue: 0.6))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.white.opacity(0.02), in: RoundedRectangle(cornerRadius: 4))
    }

    private func infoBlock(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color(red: 0.6, green: 0.75, blue: 0.9))
            .lineSpacing(3)
            .padding(10)
            .background(Color(red: 0.15, green: 0.22, blue: 0.30).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }

    private func zoneColor(_ zone: MemoryNode.Zone) -> Color {
        switch zone {
        case .front: return Color(red: 0.4, green: 0.9, blue: 0.5)
        case .near:  return Color(red: 0.4, green: 0.7, blue: 1.0)
        case .mid:   return Color(red: 0.8, green: 0.6, blue: 1.0)
        case .deep:  return Color(red: 0.5, green: 0.5, blue: 0.7)
        }
    }
}
