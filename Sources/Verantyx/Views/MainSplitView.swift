import SwiftUI

// MARK: - MainSplitView
// Verantyx IDE layout — switches between:
//   • Human Mode   → 4-pane IDE (Activity + File Tree + Chat + Diff/Terminal)
//   • AI Priority  → Full-screen 2-pane (Chat | Artifact) — AIModeLayoutView

struct MainSplitView: View {
    @EnvironmentObject var app: AppState
    @State private var activitySection: ActivityBarView.ActivitySection = .explorer
    @State private var showModelPicker = false
    @State private var showSettings    = false

    /// True once any non-system message exists — locks the mode toggle
    private var chatStarted: Bool {
        app.messages.contains { $0.role != .system }
    }

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
        // ── Settings sheet ─────────────────────────────────────────────────
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(app)
        }
        // ── Open Settings sheet when gear is tapped ────────────────────────
        .onChange(of: activitySection) { section in
            if section == .settings {
                showSettings = true
                // Reset so the bar doesn't stay highlighted
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    activitySection = .explorer
                }
            }
        }
    } // end body

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
                        case .mcp:       MCPView()
                        case .evolution: SelfEvolutionView().environmentObject(app)
                        default:         FileTreeView()
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
                            // Artifact panel — has Diff tab built-in
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

            // ── Human Mode: pending approval banner ──────────────────
            if app.operationMode == .human, let diff = app.pendingDiff {
                humanApprovalBanner(diff: diff)
            }

            Divider().opacity(0.4)
            StatusBarView(terminal: app.terminal)
        }
        .background(Color(red: 0.11, green: 0.11, blue: 0.14))
        .toastOverlay()
    }

    // MARK: - Human Mode: approval banner

    private func humanApprovalBanner(diff: FileDiff) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(red: 1.0, green: 0.75, blue: 0.2))
                .font(.system(size: 13))

            VStack(alignment: .leading, spacing: 2) {
                Text("承認待ち: \(diff.fileURL.lastPathComponent)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.95, green: 0.88, blue: 0.60))
                Text("AIが変更を提案しています。Diffタブで内容を確認してください。")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.65, green: 0.65, blue: 0.75))
            }

            Spacer()

            // Quick Reject
            Button {
                app.pendingDiff = nil
                app.showDiff    = false
                app.addSystemMessage("↩️ 変更を却下しました")
            } label: {
                Text("却下")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.9, green: 0.4, blue: 0.4))
                    .padding(.horizontal, 16).padding(.vertical, 5)
                    .background(Color(red: 0.35, green: 0.12, blue: 0.12).opacity(0.6),
                                in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(red: 0.9, green: 0.4, blue: 0.4).opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)

            // Quick Approve
            Button {
                do {
                    try diff.modifiedContent.write(to: diff.fileURL, atomically: true, encoding: .utf8)
                    app.selectedFileContent = diff.modifiedContent
                    app.pendingDiff = nil
                    app.showDiff    = false
                    app.addSystemMessage("✅ 変更を承認・適用しました: \(diff.fileURL.lastPathComponent)")
                } catch {
                    app.addSystemMessage("❌ 書き込み失敗: \(error.localizedDescription)")
                }
            } label: {
                Text("承認")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.3, green: 0.9, blue: 0.45))
                    .padding(.horizontal, 16).padding(.vertical, 5)
                    .background(Color(red: 0.12, green: 0.30, blue: 0.18).opacity(0.7),
                                in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(red: 0.3, green: 0.9, blue: 0.45).opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(red: 0.16, green: 0.14, blue: 0.08))
        .overlay(Rectangle().fill(Color(red: 1.0, green: 0.75, blue: 0.2).opacity(0.3)).frame(height: 1),
                 alignment: .top)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.easeInOut(duration: 0.2), value: app.pendingDiff != nil)
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
                guard !chatStarted else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    app.operationMode = app.operationMode == .aiPriority ? .human : .aiPriority
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: app.operationMode.icon)
                        .font(.system(size: 11))
                    Text(app.operationMode.rawValue)
                        .font(.system(size: 11, weight: .semibold))
                    // Show lock once chat has started
                    if chatStarted {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .opacity(0.5)
                    }
                }
                .foregroundStyle(chatStarted
                                 ? app.operationMode.accentColor.opacity(0.45)
                                 : app.operationMode.accentColor)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(app.operationMode.accentColor.opacity(chatStarted ? 0.05 : 0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(app.operationMode.accentColor.opacity(chatStarted ? 0.15 : 0.35),
                                        lineWidth: 0.8)
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(chatStarted)
            .help(chatStarted
                  ? "モードはチャット開始後に変更できません（新しいセッションで切り替えてください）"
                  : "モード切替: \(app.operationMode == .aiPriority ? "Human Modeへ" : "AI Priorityへ")")
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
