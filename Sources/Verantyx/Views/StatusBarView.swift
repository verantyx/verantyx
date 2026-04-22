import SwiftUI

// MARK: - StatusBarView
// VS Code-style bottom status bar

struct StatusBarView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var terminal: TerminalRunner

    var body: some View {
        HStack(spacing: 0) {
            // Left section — git branch / errors
            HStack(spacing: 8) {
                Image(systemName: "atom")
                    .font(.system(size: 11))
                Text("Verantyx v0.1")
                    .font(.system(size: 11, design: .monospaced))
            }
            .foregroundStyle(Color(red: 0.8, green: 0.8, blue: 0.85))
            .padding(.horizontal, 10)

            Divider().frame(height: 14).opacity(0.3)

            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 10))
                Text(app.workspaceURL?.lastPathComponent ?? "No workspace")
                    .font(.system(size: 11, design: .monospaced))
            }
            .foregroundStyle(Color(red: 0.6, green: 0.6, blue: 0.7))
            .padding(.horizontal, 8)

            Spacer()

            // Center — model + token rate
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 10))
                Text(modelLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color(red: 0.7, green: 0.9, blue: 0.7))

                if terminal.isRunning {
                    Text("•")
                    Text("running…")
                        .foregroundStyle(Color(red: 0.5, green: 0.9, blue: 0.5))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Color(red: 0.6, green: 0.6, blue: 0.7))
            .padding(.horizontal, 10)

            Spacer()

            // Right section — memory stats
            HStack(spacing: 8) {
                Group {
                    Text("JCross Nodes: 0")
                    Divider().frame(height: 14).opacity(0.3)
                    HStack(spacing: 3) {
                        Circle().fill(app.statusColor).frame(width: 6, height: 6)
                        Text(app.statusLabel)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(red: 0.6, green: 0.6, blue: 0.7))
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 22)
        .background(Color(red: 0.12, green: 0.12, blue: 0.16))
    }

    private var modelLabel: String {
        switch app.modelStatus {
        case .ollamaReady(let m): return "mlx-swift [\(m)]"
        case .ready(let n):        return "MLX [\(n)]"
        default:                   return "No model"
        }
    }
}
