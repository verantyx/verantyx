import SwiftUI

// MARK: - CodeView
// Syntax-highlighted, scrollable code viewer with line numbers.
// Used for: selected file preview, diff context.

struct CodeView: View {
    let content: String
    let language: SyntaxHighlighter.Language
    var showLineNumbers: Bool = true
    var highlightLines: Set<Int> = []   // for diff context

    // Pre-tokenize per line
    private var lines: [(Int, AttributedString)] {
        let rawLines = content.components(separatedBy: "\n")
        return rawLines.enumerated().map { (i, line) in
            (i + 1, SyntaxHighlighter.highlight(line, language: language))
        }
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines, id: \.0) { (lineNum, highlighted) in
                    HStack(alignment: .top, spacing: 0) {
                        // Line number
                        if showLineNumbers {
                            Text("\(lineNum)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Color(red: 0.4, green: 0.4, blue: 0.5))
                                .frame(width: lineNumberWidth, alignment: .trailing)
                                .padding(.trailing, 12)
                        }

                        // Highlighted line
                        Text(highlighted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                highlightLines.contains(lineNum)
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.clear
                            )
                    }
                    .padding(.vertical, 0.5)
                    .background(lineNum % 2 == 0
                        ? Color.white.opacity(0.01)
                        : Color.clear)
                }
            }
            .padding(12)
        }
        .background(Color(red: 0.1, green: 0.1, blue: 0.12))
    }

    private var lineNumberWidth: CGFloat {
        let digits = max(2, String(lines.count).count)
        return CGFloat(digits) * 8 + 4
    }
}

// MARK: - FilePaneView
// The "selected file" preview in the middle column (below chat or as tab).

struct FilePaneView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var gatekeeper = GatekeeperModeState.shared
    @State private var viewMode: ViewMode = .code

    enum ViewMode: String, CaseIterable {
        case code = "Code"
        case raw  = "Raw"
    }

    var body: some View {
        if let file = app.selectedFile, !app.selectedFileContent.isEmpty {
            VStack(spacing: 0) {
                // Tab bar
                HStack {
                    Image(systemName: "doc.text.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(file.lastPathComponent)
                        .font(.system(.caption, design: .monospaced))
                        .fontWeight(.medium)
                    Spacer()

                    if gatekeeper.isEnabled {
                        Picker("Gatekeeper View", selection: $app.showGatekeeperRawCode) {
                            Text("JCross IR").tag(false)
                            Text("Source File").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 150)
                        
                        Divider()
                            .frame(height: 16)
                            .padding(.horizontal, 4)
                    }

                    Picker("", selection: $viewMode) {
                        ForEach(ViewMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 120)

                    Button {
                        app.selectedFile = nil
                        app.selectedFileContent = ""
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(nsColor: .controlBackgroundColor))

                Divider()

                // Content
                switch viewMode {
                case .code:
                    let lang: SyntaxHighlighter.Language = (gatekeeper.isEnabled && !app.showGatekeeperRawCode)
                        ? .jcross
                        : SyntaxHighlighter.language(for: file)
                    CodeView(
                        content: app.selectedFileContent,
                        language: lang
                    )
                case .raw:
                    ScrollView {
                        Text(app.selectedFileContent)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .textSelection(.enabled)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                }
            }
        }
    }
}
