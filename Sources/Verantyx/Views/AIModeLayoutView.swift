import SwiftUI

// MARK: - AIModeLayoutView
// Full-screen 2-pane layout for AI Priority mode.
//
//  ┌─────────────────────────────┬──────────────────────────────┐
//  │  AI Chat (left)             │  Artifact Preview (right)    │
//  │  Gemini-style               │  HTML / Mermaid / Code / MD  │
//  │  full chat history          │  WKWebView live render       │
//  │  no file tree, no IDE       │  + Diff view tab             │
//  └─────────────────────────────┴──────────────────────────────┘
//
// Red banner at top announces AI Priority mode is active.
// Switch back to Human mode via the banner button or toolbar.

struct AIModeLayoutView: View {
    @EnvironmentObject var app: AppState
    @State private var showModelPicker = false

    var body: some View {
        VStack(spacing: 0) {

            // ── AI Priority banner ────────────────────────────────────
            aiPriorityBanner

            Divider()
                .overlay(Color(red: 1.0, green: 0.35, blue: 0.20).opacity(0.7))

            // ── 2-pane: Chat | Artifact ───────────────────────────────
            ResizableHSplit(
                minLeft: 340, maxLeft: 900, minRight: 300, initialLeft: 520
            ) {
                // Left: Full-screen chat
                fullChatPanel
            } right: {
                // Right: Artifact + Terminal stack
                VStack(spacing: 0) {
                    ArtifactPanelView()
                        .environmentObject(app)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if app.showProcessLog {
                        Divider().opacity(0.4)
                        TerminalPanelView(terminal: app.terminal)
                            .environmentObject(app)
                            .frame(height: 180)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // ── Status bar ─────────────────────────────────────────────
            Divider().opacity(0.4)
            StatusBarView(terminal: app.terminal)
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        .toastOverlay()
    }

    // MARK: - AI Priority Banner

    private var aiPriorityBanner: some View {
        HStack(spacing: 10) {
            // Mode indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(red: 1.0, green: 0.3, blue: 0.2))
                    .frame(width: 7, height: 7)
                    .overlay(
                        Circle()
                            .stroke(Color(red: 1.0, green: 0.3, blue: 0.2).opacity(0.5), lineWidth: 3)
                            .blur(radius: 2)
                    )
                Text("AI PRIORITY MODE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.30))
            }

            Text("—")
                .foregroundStyle(Color(red: 0.5, green: 0.3, blue: 0.25))

            Text("承認なし · MCP無制限 · 自動Diff適用")
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 0.75, green: 0.45, blue: 0.35))

            Spacer()

            // Model chip
            Button {
                showModelPicker.toggle()
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(app.statusColor).frame(width: 6, height: 6)
                    Text(shortModel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(red: 0.75, green: 0.75, blue: 0.88))
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showModelPicker, arrowEdge: .bottom) {
                ModelPickerView().environmentObject(app).frame(width: 300)
            }

            // Switch to Human mode
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    app.operationMode = .human
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 10))
                    Text("Human Mode へ")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(Color(red: 0.88, green: 0.88, blue: 0.96))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                        )
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.22, green: 0.08, blue: 0.06),
                    Color(red: 0.12, green: 0.09, blue: 0.10)
                ],
                startPoint: .leading, endPoint: .trailing
            )
        )
    }

    // MARK: - Full Chat Panel (left side)

    private var fullChatPanel: some View {
        VStack(spacing: 0) {
            // Minimal chat header
            HStack(spacing: 8) {
                Image(systemName: "atom")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.4, green: 0.7, blue: 1.0))
                Text("VerantyxAgent")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.85, green: 0.85, blue: 0.92))
                Spacer()

                // Artifact panel toggle
                Button {
                    withAnimation { app.showArtifactPanel.toggle() }
                } label: {
                    Image(systemName: "rectangle.portrait.righthalf.inset.filled")
                        .font(.system(size: 11))
                        .foregroundStyle(app.showArtifactPanel
                                         ? Color(red: 0.4, green: 0.8, blue: 0.5)
                                         : Color(red: 0.4, green: 0.4, blue: 0.55))
                }
                .buttonStyle(.plain)
                .help("Artifact パネル切替")

                // Terminal toggle
                Button {
                    withAnimation { app.showProcessLog.toggle() }
                } label: {
                    Image(systemName: "terminal")
                        .symbolVariant(app.showProcessLog ? .fill : .none)
                        .font(.system(size: 11))
                        .foregroundStyle(app.showProcessLog
                                         ? Color(red: 0.3, green: 1.0, blue: 0.5)
                                         : .secondary)
                }
                .buttonStyle(.plain)
                .help("ターミナル")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(red: 0.11, green: 0.11, blue: 0.15))

            Divider().opacity(0.3)

            // Chat messages fill the space
            AgentChatView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var shortModel: String {
        switch app.modelStatus {
        case .ollamaReady(let m): return m.components(separatedBy: ":").first ?? m
        case .mlxReady(let m):   return "MLX/" + (m.components(separatedBy: "/").last ?? m)
        default:                  return "no model"
        }
    }
}
