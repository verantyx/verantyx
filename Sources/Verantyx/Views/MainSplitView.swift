import SwiftUI

// MARK: - MainSplitView
// Verantyx IDE layout — all panels freely resizable with drag dividers.
//
//  ┌────┬─────────────────┬──────────────────────┬──────────────────────┐
//  │    │  Left panel     │  Center chat/log      │  Right: Diff+Term    │
//  │ 🔍 │  (Explorer/MCP) │  AgentChatView        │  SideBySideDiffView  │
//  │ 📁 │                 │  ThinkingLogView       │  ─────────────────── │
//  │ ⬡  │                 │                        │  TerminalPanelView   │
//  └────┴─────────────────┴──────────────────────┴──────────────────────┘
//  ← 48 →←  160–480  →←    300–700      →←    min 300          →
//
// Constraints (prevent panels from disappearing):
//   Left     min 160  max 480
//   Center   min 300  max 700
//   Right    min 300  (fills rest)
//   Diff/Term split: top min 200  bottom min 120

struct MainSplitView: View {
    @EnvironmentObject var app: AppState
    @State private var activitySection: ActivityBarView.ActivitySection = .explorer
    @State private var showModelPicker = false

    var body: some View {
        VStack(spacing: 0) {
            // ── Main content area ──────────────────────────────────────
            HStack(spacing: 0) {

                // ① Activity bar (fixed 48pt)
                ActivityBarView(selectedSection: $activitySection)
                    .frame(width: 48)

                // ② Left + Center + Right — three-pane resizable layout
                ResizableHSplit(
                    minLeft: 160, maxLeft: 480, minRight: 600, initialLeft: 240
                ) {
                    // ── Left pane ──────────────────────────────────────
                    Group {
                        switch activitySection {
                        case .mcp:      MCPView()
                        default:        FileTreeView()
                        }
                    }
                    .frame(maxHeight: .infinity)
                } right: {
                    // ── Center + Right (another horizontal split) ──────
                    ResizableHSplit(
                        minLeft: 300, maxLeft: 700, minRight: 300, initialLeft: 420
                    ) {
                        // ── Center: Chat + Process Log ─────────────────
                        VStack(spacing: 0) {
                            AgentChatView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)

                            if app.showProcessLog {
                                ResizableVSplit(
                                    minTop: 200, maxTop: 99999, minBottom: 80, initialTop: 9999
                                ) {
                                    EmptyView()  // spacer — chat fills top
                                } bottom: {
                                    ThinkingLogView()
                                }
                                .frame(height: 180)
                            }
                        }
                    } right: {
                        // ── Right: Diff (top) + Terminal (bottom) ──────
                        ResizableVSplit(
                            minTop: 200, maxTop: 99999, minBottom: 100, initialTop: 400
                        ) {
                            SideBySideDiffView()
                        } bottom: {
                            TerminalPanelView(terminal: app.terminal)
                                .environmentObject(app)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // ── Status bar ─────────────────────────────────────────────
            Divider().opacity(0.4)
            StatusBarView(terminal: app.terminal)
        }
        .background(Color(red: 0.11, green: 0.11, blue: 0.14))
        .toastOverlay()
        .toolbar { toolbarContent }
        .onAppear { app.connectOllama() }
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
            .help("Toggle Process Log (⌘⇧L)")
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
