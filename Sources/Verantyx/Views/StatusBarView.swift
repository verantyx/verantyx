import SwiftUI

// MARK: - StatusBarView
// The bottom bar. The only number that matters: tok/s.

struct StatusBarView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var terminal: TerminalRunner

    var body: some View {
        HStack(spacing: 0) {

            // ── Left: version + workspace ─────────────────────────────
            HStack(spacing: 6) {
                Text("VX")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.6))
                Text("v0.1")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)

            divider

            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 9))
                Text(app.workspaceURL?.lastPathComponent ?? "no workspace")
                    .font(.system(size: 10, design: .monospaced))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)

            // ── Center: model label ───────────────────────────────────
            Spacer()

            HStack(spacing: 6) {
                Image(systemName: modelIcon)
                    .font(.system(size: 9))
                Text(modelLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(app.statusColor)
            }
            .padding(.horizontal, 10)

            Spacer()

            // ── Right: THE NUMBER ─────────────────────────────────────
            HStack(spacing: 12) {

                // tok/s — primary performance signal
                if app.isGenerating || app.tokensPerSecond > 0 {
                    HStack(spacing: 4) {
                        if app.isGenerating {
                            // Animated pulse while generating
                            Circle()
                                .fill(Color(red: 0.3, green: 1.0, blue: 0.5))
                                .frame(width: 5, height: 5)
                                .opacity(0.8)
                        }
                        Text(tokLabel)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(
                                app.tokensPerSecond > 20
                                    ? Color(red: 0.3, green: 1.0, blue: 0.4)   // fast — green
                                    : app.tokensPerSecond > 5
                                        ? Color(red: 1.0, green: 0.8, blue: 0.2)  // mid — yellow
                                        : Color(red: 0.7, green: 0.7, blue: 0.7)  // slow — gray
                            )
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))

                    divider
                }

                // Session total tokens
                if app.totalTokensGenerated > 0 {
                    Text("\(app.totalTokensGenerated) tok")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(red: 0.5, green: 0.5, blue: 0.6))
                    divider
                }

                // Terminal running
                if terminal.isRunning {
                    HStack(spacing: 3) {
                        Circle().fill(.orange).frame(width: 5, height: 5)
                        Text("exec")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.orange)
                    }
                    divider
                }

                // Model status dot
                HStack(spacing: 4) {
                    Circle().fill(app.statusColor).frame(width: 6, height: 6)
                    Text(app.statusLabel)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.trailing, 10)
            }
        }
        .frame(height: 22)
        .background(Color(red: 0.1, green: 0.1, blue: 0.13))
    }

    // MARK: - Computed

    private var tokLabel: String {
        if app.isGenerating {
            if app.tokensPerSecond < 0.5 { return "waiting…" }
            return String(format: "%.1f tok/s", app.tokensPerSecond)
        }
        // After generation: show final result
        if app.inferenceMs > 0 {
            return String(format: "%.1f tok/s  %dms", app.tokensPerSecond, app.inferenceMs)
        }
        return String(format: "%.1f tok/s", app.tokensPerSecond)
    }

    private var modelLabel: String {
        switch app.modelStatus {
        case .ollamaReady(let m):  return m.components(separatedBy: ":").first ?? m
        case .mlxReady(let m):     return (m.components(separatedBy: "/").last ?? m)
        case .ready(let n):        return n
        case .connecting:          return "connecting…"
        case .mlxDownloading(let m): return "↓ \(m.components(separatedBy: "/").last ?? m)"
        default:                   return "no model"
        }
    }

    private var modelIcon: String {
        switch app.modelStatus {
        case .mlxReady:   return "cpu"
        case .ollamaReady: return "externaldrive"
        default:           return "circle.dashed"
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.1))
            .frame(width: 1, height: 14)
    }
}
