import SwiftUI

// MARK: - ThinkingLogView
// Raw process log — shows exactly what the AI is doing right now.
// This is the "brain exposure" panel. Hacker aesthetic: terminal-style, no decoration.
// Inspired by htop / gdb output. Every line tells a story.

struct ThinkingLogView: View {
    @EnvironmentObject var app: AppState
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ─────────────────────────────────────────────
            HStack(spacing: 8) {
                // Pulsing dot when active
                if app.isGenerating {
                    Circle()
                        .fill(Color(red: 0.3, green: 1.0, blue: 0.5))
                        .frame(width: 6, height: 6)
                        .opacity(0.9)
                }

                Text("PROCESS LOG")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.5, green: 0.9, blue: 0.6))

                if app.isGenerating {
                    Text("● LIVE")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color(red: 0.3, green: 1.0, blue: 0.5))
                }

                Spacer()

                // tok/s inline
                if app.tokensPerSecond > 0 {
                    Text(String(format: "%.1f tok/s", app.tokensPerSecond))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(tpsColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(tpsColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 3))
                }

                Button {
                    autoScroll.toggle()
                } label: {
                    Image(systemName: autoScroll ? "arrow.down.to.line" : "arrow.down.to.line.compact")
                        .font(.system(size: 10))
                        .foregroundStyle(autoScroll ? .green : .secondary)
                }
                .buttonStyle(.plain)

                Button {
                    app.clearProcessLog()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(red: 0.08, green: 0.10, blue: 0.12))

            Divider().opacity(0.3)

            // ── Log scroll ─────────────────────────────────────────
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(app.processLog) { entry in
                            LogRow(entry: entry)
                                .id(entry.id)
                        }
                        // Anchor for auto-scroll
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                }
                .onChange(of: app.processLog.count) { _ in
                    if autoScroll {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo("bottom")
                        }
                    }
                }
            }
        }
        .background(Color(red: 0.06, green: 0.08, blue: 0.10))
    }

    private var tpsColor: Color {
        app.tokensPerSecond > 20
            ? Color(red: 0.3, green: 1.0, blue: 0.4)
            : app.tokensPerSecond > 5
                ? Color(red: 1.0, green: 0.8, blue: 0.2)
                : Color(red: 0.6, green: 0.6, blue: 0.6)
    }
}

// MARK: - LogRow

private struct LogRow: View {
    let entry: AppState.ProcessLogEntry

    private var timeStr: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: entry.timestamp)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            // Timestamp
            Text(timeStr)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color(red: 0.4, green: 0.4, blue: 0.5))
                .frame(width: 86, alignment: .leading)

            // Kind prefix
            Text(entry.prefix)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(entry.color)
                .frame(width: 52, alignment: .leading)

            // Content
            Text(entry.text)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(entry.kind == .perf
                    ? Color(red: 0.3, green: 1.0, blue: 0.5)
                    : Color(red: 0.85, green: 0.85, blue: 0.9))
                .textSelection(.enabled)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
    }
}

// MARK: - ThinkingLogView preview helper

extension AppState {
    /// Emit a log entry from browser operations, JCross hits, etc.
    func logMemoryHit(_ nodeId: String, summary: String) {
        logProcess("\(nodeId)  \(summary)", kind: .memory)
    }

    func logBrowser(_ action: String, url: String) {
        logProcess("\(action)  \(url)", kind: .browser)
    }

    func logThinking(_ excerpt: String) {
        // Only show first 120 chars of thinking to avoid log spam
        logProcess(String(excerpt.prefix(120)), kind: .thinking)
    }
}
