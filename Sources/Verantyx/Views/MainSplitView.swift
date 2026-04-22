import SwiftUI

// MARK: - MainSplitView
// Verantyx layout (matches reference image):
//
//  ┌────┬──────────────────┬───────────────────────────────────────┐
//  │    │  Explorer        │  Center (Agent Chat)  │  Right Column  │
//  │ 🔍 │  > verantyx-cli  │  [Vibe WS][Think Log] │  before│after  │
//  │ 📁 │    > Sources     │  AntigravityAgent     │  diff lines    │
//  │ 🧪 │    > ...         │  <think>...</think>   │                │
//  │    │                  │  [model selector]     │ [Approve][Rej] │
//  │    │                  │  [input]              │                │
//  │    │                  ├───────────────────────│────────────────│
//  │    │                  │  README.md (preview)  │  Terminal      │
//  └────┴──────────────────┴───────────────────────┴────────────────┘
//  │ ● Verantyx v0.1    mlx-swift             JCross 0 nodes  │
//  └────────────────────────────────────────────────────────────────┘

struct MainSplitView: View {
    @EnvironmentObject var app: AppState
    @State private var activitySection: ActivityBarView.ActivitySection = .explorer
    @State private var showModelPicker = false

    var body: some View {
        VStack(spacing: 0) {
            // ── Main content ───────────────────────────────────────
            HStack(spacing: 0) {
                // ① Activity bar (leftmost icon strip)
                ActivityBarView(selectedSection: $activitySection)

                Divider().opacity(0.3)

                // ② File tree
                FileTreeView()
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)

                Divider().opacity(0.3)

                // ③ Center column: Chat + ProcessLog (bottom)
                VStack(spacing: 0) {
                    AgentChatView()
                        .frame(minHeight: 300)

                    if app.showProcessLog {
                        Divider().opacity(0.3)
                        ThinkingLogView()
                            .frame(height: 180)
                    }

                    if app.selectedFile != nil {
                        Divider().opacity(0.2)
                        FilePaneView()
                            .frame(minHeight: 80, maxHeight: 220)
                    }
                }
                .frame(minWidth: 340, idealWidth: 440, maxWidth: 620)

                Divider().opacity(0.3)

                // ④ Right column: Diff (top) + Terminal (bottom)
                VSplitView {
                    SideBySideDiffView()
                        .frame(minHeight: 250)

                    terminalSection
                        .frame(minHeight: 140, maxHeight: 280)
                }
                .frame(minWidth: 360)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // ── Status bar ─────────────────────────────────────────
            Divider().opacity(0.4)
            StatusBarView(terminal: app.terminal)
        }
        .background(Color(red: 0.11, green: 0.11, blue: 0.14))
        .toastOverlay()
        .toolbar { toolbarContent }
        .onAppear { app.connectOllama() }
    }

    // MARK: - Terminal section (right-bottom)

    private var terminalSection: some View {
        TerminalPanelView(terminal: app.terminal)
            .environmentObject(app)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                app.openWorkspace()
            } label: {
                Image(systemName: "folder.badge.plus")
                    .help("Open Folder")
            }
        }

        ToolbarItem(placement: .principal) {
            HStack(spacing: 7) {
                VXMarkView(size: 14,
                           color: Color(red: 0.88, green: 0.88, blue: 0.94))
                Text("Verantyx")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.85, green: 0.85, blue: 0.92))
            }
        }

        ToolbarItem(placement: .automatic) {
            Button {
                showModelPicker.toggle()
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(app.statusColor)
                        .frame(width: 7, height: 7)
                    Text(shortModelLabel)
                        .font(.system(size: 11, design: .monospaced))
                }
                .foregroundStyle(Color(red: 0.75, green: 0.75, blue: 0.88))
            }
            .popover(isPresented: $showModelPicker, arrowEdge: .bottom) {
                ModelPickerView()
                    .environmentObject(app)
                    .frame(width: 320)
            }
            .help("Model Picker")
        }

        ToolbarItem(placement: .primaryAction) {
            // Process log toggle
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    app.showProcessLog.toggle()
                }
            } label: {
                Image(systemName: "terminal")
                    .symbolVariant(app.showProcessLog ? .fill : .none)
                    .foregroundStyle(app.showProcessLog
                                     ? Color(red: 0.3, green: 1.0, blue: 0.5)
                                     : .secondary)
            }
            .help("Toggle Process Log")
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var shortModelLabel: String {
        switch app.modelStatus {
        case .ollamaReady(let m): return m.components(separatedBy: ":").first ?? m
        case .mlxReady(let m):   return "MLX:".appending(m.components(separatedBy: "/").last ?? m)
        case .connecting:         return "connecting…"
        case .error:              return "error"
        default:                  return "no model"
        }
    }
}
