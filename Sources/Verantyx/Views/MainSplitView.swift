import SwiftUI

// MARK: - MainSplitView
// Verantyx IDE layout — switches between:
//   • Human Mode   → 4-pane IDE (Activity + File Tree + Chat + Diff/Terminal)
//   • AI Priority  → Full-screen 2-pane (Chat | Artifact) — AIModeLayoutView

struct MainSplitView: View {
    @EnvironmentObject var app: AppState
    @State private var activitySection: ActivityBarView.ActivitySection = .explorer
    @State private var showModelPicker = false

    var body: some View {
        Group {
            if app.operationMode == .aiPriority {
                // ── AI Priority: Gemini + Artifact layout ──────────────
                AIModeLayoutView()
                    .environmentObject(app)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal:   .move(edge: .trailing).combined(with: .opacity)
                    ))
            } else {
                // ── Human Mode: standard 4-pane IDE ───────────────────
                humanModeLayout
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal:   .move(edge: .leading).combined(with: .opacity)
                    ))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: app.operationMode)
        .toolbar { toolbarContent }
        .onAppear { app.connectOllama() }
    }

    // MARK: - Human Mode (4-pane IDE)

    private var humanModeLayout: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {

                // ① Activity bar (fixed 48pt)
                ActivityBarView(selectedSection: $activitySection)
                    .frame(width: 48)

                // ② Left + Center + Right
                ResizableHSplit(
                    minLeft: 160, maxLeft: 480, minRight: 600, initialLeft: 240
                ) {
                    // ── Left pane ─────────────────────────────────────
                    Group {
                        switch activitySection {
                        case .mcp:  MCPView()
                        default:    FileTreeView()
                        }
                    }
                    .frame(maxHeight: .infinity)
                } right: {
                    ResizableHSplit(
                        minLeft: 300, maxLeft: 700, minRight: 300, initialLeft: 420
                    ) {
                        // ── Center: Chat ───────────────────────────────
                        VStack(spacing: 0) {
                            AgentChatView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                            if app.showProcessLog {
                                ResizableVSplit(
                                    minTop: 200, maxTop: 99999, minBottom: 80, initialTop: 9999
                                ) {
                                    EmptyView()
                                } bottom: {
                                    ThinkingLogView()
                                }
                                .frame(height: 180)
                            }
                        }
                    } right: {
                        // ── Right: Artifact/Diff (top) + Terminal (bottom) ──
                        ResizableVSplit(
                            minTop: 200, maxTop: 99999, minBottom: 100, initialTop: 400
                        ) {
                            // Artifact panel replaces / augments Diff view
                            ArtifactPanelView()
                                .environmentObject(app)
                        } bottom: {
                            TerminalPanelView(terminal: app.terminal)
                                .environmentObject(app)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().opacity(0.4)
            StatusBarView(terminal: app.terminal)
        }
        .background(Color(red: 0.11, green: 0.11, blue: 0.14))
        .toastOverlay()
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { app.openWorkspace() } label: {
                Image(systemName: "folder.badge.plus").help("Open Folder")
            }
        }

        ToolbarItem(placement: .principal) {
            HStack(spacing: 7) {
                VXMarkView(size: 14, color: Color(red: 0.88, green: 0.88, blue: 0.94))
                Text("Verantyx")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.85, green: 0.85, blue: 0.92))
            }
        }

        // ── Operation Mode switcher ─────────────────────────────────
        ToolbarItem(placement: .automatic) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    app.operationMode = app.operationMode == .aiPriority ? .human : .aiPriority
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: app.operationMode.icon)
                        .font(.system(size: 11))
                    Text(app.operationMode.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(app.operationMode.accentColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(app.operationMode.accentColor.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(app.operationMode.accentColor.opacity(0.35), lineWidth: 0.8)
                        )
                )
            }
            .buttonStyle(.plain)
            .help("モード切替: \(app.operationMode == .aiPriority ? "Human Modeへ" : "AI Priorityへ")")
        }

        ToolbarItem(placement: .automatic) {
            Button { showModelPicker.toggle() } label: {
                HStack(spacing: 4) {
                    Circle().fill(app.statusColor).frame(width: 7, height: 7)
                    Text(shortModelLabel)
                        .font(.system(size: 11, design: .monospaced))
                }
                .foregroundStyle(Color(red: 0.75, green: 0.75, blue: 0.88))
            }
            .popover(isPresented: $showModelPicker, arrowEdge: .bottom) {
                ModelPickerView().environmentObject(app).frame(width: 320)
            }
            .help("Model Picker")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { app.showProcessLog.toggle() }
            } label: {
                Image(systemName: "terminal")
                    .symbolVariant(app.showProcessLog ? .fill : .none)
                    .foregroundStyle(app.showProcessLog
                                     ? Color(red: 0.3, green: 1.0, blue: 0.5)
                                     : .secondary)
            }
            .help("Toggle Terminal (⌘⇧L)")
        }

        ToolbarItem(placement: .primaryAction) {
            Button { NSApp.terminate(nil) } label: {
                Text("Quit").font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var shortModelLabel: String {
        switch app.modelStatus {
        case .ollamaReady(let m): return m.components(separatedBy: ":").first ?? m
        case .mlxReady(let m):   return "MLX:" + (m.components(separatedBy: "/").last ?? m)
        case .connecting:         return "connecting…"
        case .error:              return "error"
        default:                  return "no model"
        }
    }
}
