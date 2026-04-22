import SwiftUI

// MARK: - SideBySideDiffView
// Right-top panel: "before" | "after" side-by-side diff
// Matches AntigravityIDE reference image layout

struct SideBySideDiffView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ───────────────────────────────────────────────
            panelHeader

            Divider().opacity(0.3)

            if let diff = app.pendingDiff {
                // ── Side-by-side columns ──────────────────────────────
                diffColumns(diff)

                Divider().opacity(0.3)

                // ── Approve / Reject bar ─────────────────────────────
                actionBar(diff)
            } else {
                emptyState
            }
        }
        .background(Color(red: 0.12, green: 0.12, blue: 0.15))
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack {
            Image(systemName: "arrow.left.arrow.right.square")
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 0.5, green: 0.5, blue: 0.65))
            Text("Response & Terminal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(red: 0.75, green: 0.75, blue: 0.85))
            Spacer()
            HStack(spacing: 8) {
                Button { } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(red: 0.45, green: 0.45, blue: 0.6))

                Button { } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color(red: 0.45, green: 0.45, blue: 0.6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(red: 0.15, green: 0.15, blue: 0.19))
    }

    // MARK: - Side-by-side columns

    private func diffColumns(_ diff: FileDiff) -> some View {
        let origLines  = diff.originalContent.components(separatedBy: "\n")
        let modiLines  = diff.modifiedContent.components(separatedBy: "\n")
        let lang       = SyntaxHighlighter.language(for: diff.fileURL)
        let maxLines   = max(origLines.count, modiLines.count)

        return ScrollView([.vertical, .horizontal]) {
            HStack(spacing: 0) {
                // ── Before ────────────────────────────────────────────
                VStack(spacing: 0) {
                    columnHeader("before", color: Color(red: 0.9, green: 0.35, blue: 0.35))
                    ForEach(0..<maxLines, id: \.self) { i in
                        let line = i < origLines.count ? origLines[i] : ""
                        let isRemoved = !modiLines.contains(line) && !line.isEmpty
                        diffLine(
                            number: i + 1,
                            text: line,
                            language: lang,
                            kind: isRemoved ? .removed : .unchanged
                        )
                    }
                }
                .frame(maxWidth: .infinity)

                Divider().opacity(0.4)

                // ── After ─────────────────────────────────────────────
                VStack(spacing: 0) {
                    columnHeader("after", color: Color(red: 0.35, green: 0.9, blue: 0.5))
                    ForEach(0..<maxLines, id: \.self) { i in
                        let line = i < modiLines.count ? modiLines[i] : ""
                        let isAdded = i < origLines.count ? (line != origLines[i]) && !line.isEmpty : !line.isEmpty
                        diffLine(
                            number: i + 1,
                            text: line,
                            language: lang,
                            kind: isAdded ? .added : .unchanged
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func columnHeader(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: title == "before" ? "minus.circle.fill" : "plus.circle.fill")
                .foregroundStyle(color)
                .font(.system(size: 10))
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.08))
    }

    enum LineKind { case added, removed, unchanged }

    private func diffLine(number: Int, text: String, language: SyntaxHighlighter.Language, kind: LineKind) -> some View {
        HStack(spacing: 0) {
            // Line number
            Text("\(number)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color(red: 0.3, green: 0.3, blue: 0.4))
                .frame(width: 28, alignment: .trailing)
                .padding(.trailing, 8)

            // Change indicator
            Text(kind == .added ? "+" : kind == .removed ? "-" : " ")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(kind == .added ? Color(red: 0.4, green: 0.9, blue: 0.5) : Color(red: 0.9, green: 0.4, blue: 0.4))
                .frame(width: 12)

            // Code
            Text(SyntaxHighlighter.highlight(text, language: language))
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
        }
        .padding(.vertical, 0.5)
        .padding(.horizontal, 6)
        .background(
            kind == .added   ? Color(red: 0.15, green: 0.35, blue: 0.20).opacity(0.5) :
            kind == .removed ? Color(red: 0.35, green: 0.12, blue: 0.12).opacity(0.5) :
            Color.clear
        )
    }

    // MARK: - Action bar

    private func actionBar(_ diff: FileDiff) -> some View {
        HStack(spacing: 12) {
            Text(diff.fileURL.lastPathComponent)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(red: 0.5, green: 0.5, blue: 0.65))
            Spacer()

            // Reject
            Button {
                app.pendingDiff = nil
                app.showDiff = false
                app.addSystemMessage("↩️ Changes rejected.")
            } label: {
                Text("Reject")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.9, green: 0.4, blue: 0.4))
                    .frame(minWidth: 80)
                    .padding(.vertical, 6)
                    .background(Color(red: 0.35, green: 0.12, blue: 0.12).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(red: 0.9, green: 0.4, blue: 0.4).opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)

            // Approve
            Button {
                applyDiff(diff)
            } label: {
                Text("Approve")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.3, green: 0.9, blue: 0.45))
                    .frame(minWidth: 80)
                    .padding(.vertical, 6)
                    .background(Color(red: 0.12, green: 0.30, blue: 0.18).opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(red: 0.3, green: 0.9, blue: 0.45).opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(red: 0.13, green: 0.13, blue: 0.16))
    }

    private func applyDiff(_ diff: FileDiff) {
        do {
            try diff.modifiedContent.write(to: diff.fileURL, atomically: true, encoding: .utf8)
            app.selectedFileContent = diff.modifiedContent
            app.pendingDiff = nil
            app.showDiff = false
            app.addSystemMessage("✅ Changes applied to \(diff.fileURL.lastPathComponent)")
        } catch {
            app.addSystemMessage("❌ Write failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "arrow.left.arrow.right.square")
                .font(.system(size: 32))
                .foregroundStyle(Color(red: 0.28, green: 0.28, blue: 0.38))
            Text("Diff will appear here")
                .font(.headline)
                .foregroundStyle(Color(red: 0.4, green: 0.4, blue: 0.55))
            Text("Select a file and ask the AI to make changes.\nThe diff will be shown here for review.")
                .font(.callout)
                .foregroundStyle(Color(red: 0.32, green: 0.32, blue: 0.45))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
