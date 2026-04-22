import SwiftUI

// MARK: - MainSplitView
// AntigravityIDE layout (matches reference image):
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
//  │ ● AntigravityIDE v0.1    mlx-swift             JCross 0 nodes  │
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

                // ③ Center column: Chat (top) + File preview (bottom)
                VSplitView {
                    AgentChatView()
                        .frame(minHeight: 300)

                    if app.selectedFile != nil {
                        FilePaneView()
                            .frame(minHeight: 100, maxHeight: 260)
                    }
                }
                .frame(minWidth: 340, idealWidth: 440, maxWidth: 600)

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
            HStack(spacing: 8) {
                Image(systemName: "atom")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.4, green: 0.7, blue: 1.0))
                Text("AntigravityIDE")
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
            Button {
                NSApp.terminate(nil)
            } label: {
                Text("Restart to Update ++")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private var shortModelLabel: String {
        switch app.modelStatus {
        case .ollamaReady(let m): return "● \(m)"
        case .connecting:         return "● Connecting…"
        case .error:              return "● Error"
        default:                  return "● No model"
        }
    }
}
