import SwiftUI
import AppKit

// MARK: - HumanPriorityModeView
// VS Code / Antigravity style layout:
//   [Activity Bar 48pt] | [File Tree 240pt] | [Code Editor flex] | [AI Chat 340pt]
//
// The human writes code directly in the editor.
// The AI chat panel sits on the right as a co-pilot assistant.

struct HumanPriorityModeView: View {
    @EnvironmentObject var app: AppState
    @State private var activitySection: ActivityBarView.ActivitySection = .explorer
    @State private var showSettings     = false
    @State private var showMCPQuick     = false

    // Editor state
    @State private var editorContent: String = ""
    @State private var editorLanguage: String = "swift"
    @State private var hasUnsavedChanges = false
    @State private var saveStatus: SaveStatus = .saved

    enum SaveStatus { case saved, unsaved, saving }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 0) {

                    // ① Activity bar (fixed 48pt)
                    ActivityBarView(selectedSection: $activitySection)
                        .frame(width: 48)

                    // ② Outer split: [Left panel] | [Center + Right]
                    ResizableHSplit(
                        minLeft: 160, maxLeft: 400, minRight: 700, initialLeft: 220
                    ) {
                        // ── Left: File Tree / MCP / Evolution ─────────────────
                        Group {
                            switch activitySection {
                            case .mcp:       MCPView()
                            case .evolution: SelfEvolutionView().environmentObject(app)
                            case .search:    GlobalSearchView().environmentObject(app)
                            case .git:       GitPanelView().environmentObject(app)
                            default:         FileTreeView()
                            }
                        }
                        .frame(maxHeight: .infinity)

                    } right: {
                        // ③ Inner split: [Code Editor] | [AI Chat]
                        ResizableHSplit(
                            minLeft: 400, maxLeft: 99999, minRight: 280, initialLeft: 99999
                        ) {
                            // ── Center: Code Editor ────────────────────────────
                            codeEditorPanel

                        } right: {
                            // ── Right: AI Chat ─────────────────────────────────
                            aiChatPanel
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // ── Loaded Model Panel — shows when model is active ───────
                Group {
                    switch app.modelStatus {
                    case .mlxReady, .ollamaReady:
                        LoadedModelPanel()
                            .environmentObject(app)
                    default:
                        EmptyView()
                    }
                }
                .animation(.spring(response: 0.32, dampingFraction: 0.78), value: app.modelStatus)

                // ── Status bar ────────────────────────────────────────────────
                Divider().opacity(0.4)
                humanPriorityStatusBar
            }
            .background(Color(red: 0.10, green: 0.10, blue: 0.13))

            // ── Settings overlay (same pattern as MainSplitView) ─────────────
            if showSettings {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.18)) { showSettings = false }
                    }
                    .transition(.opacity)

                SettingsView(onDismiss: {
                    withAnimation(.easeOut(duration: 0.18)) { showSettings = false }
                })
                .environmentObject(app)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.18), value: showSettings)
        .toastOverlay()
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OpenMCPPanel"))) { _ in
            activitySection = .mcp
        }
        // ── Settings を開く ──────────────────────────────────────────────────
        .onChange(of: activitySection) { _, section in
            if section == .settings {
                withAnimation(.easeOut(duration: 0.18)) { showSettings = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    activitySection = .explorer
                }
            }
        }
        .onChange(of: app.selectedFile) { _, url in
            loadFileIntoEditor(url: url)
        }
        .onChange(of: app.showGatekeeperRawCode) { _, _ in
            loadFileIntoEditor(url: app.selectedFile)
        }
        .onAppear {
            loadFileIntoEditor(url: app.selectedFile)
        }
    }

    // MARK: - Code Editor Panel

    private var codeEditorPanel: some View {
        VStack(spacing: 0) {
            // Tab bar
            editorTabBar

            Divider().opacity(0.3)

            // Editor body
            if let url = app.selectedFile {
                let isJCrossMode = GatekeeperModeState.shared.isEnabled && !app.showGatekeeperRawCode
                CodeEditorView(
                    content: $editorContent,
                    language: editorLanguage,
                    isEditable: !isJCrossMode,
                    onEdit: {
                        if !isJCrossMode {
                            hasUnsavedChanges = true
                            saveStatus = .unsaved
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Empty state
                emptyEditorState
            }

            // Terminal (collapsible)
            if app.showProcessLog {
                Divider().opacity(0.3)
                ResizableVSplit(
                    minTop: 0, maxTop: 0, minBottom: 80, initialTop: 0
                ) {
                    EmptyView()
                } bottom: {
                    TerminalPanelView(terminal: app.terminal)
                        .environmentObject(app)
                }
                .frame(height: 200)
            }
        }
        .background(Color(red: 0.10, green: 0.10, blue: 0.13))
    }

    // MARK: - Editor Tab Bar

    private var editorTabBar: some View {
        HStack(spacing: 0) {
            if let url = app.selectedFile {
                HStack(spacing: 6) {
                    // File icon
                    Image(systemName: fileIcon(for: url))
                        .font(.system(size: 11))
                        .foregroundStyle(fileIconColor(for: url))

                    Text(url.lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color(red: 0.88, green: 0.88, blue: 0.95))

                    // Unsaved dot
                    if hasUnsavedChanges {
                        Circle()
                            .fill(Color(red: 0.9, green: 0.7, blue: 0.3))
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color(red: 0.13, green: 0.13, blue: 0.17))
                .overlay(
                    Rectangle()
                        .fill(Color(red: 0.4, green: 0.75, blue: 1.0).opacity(0.6))
                        .frame(height: 1),
                    alignment: .top
                )
            }

            Spacer()

            // Save button / status
            HStack(spacing: 8) {
                if GatekeeperModeState.shared.isEnabled {
                    Picker("Gatekeeper View", selection: $app.showGatekeeperRawCode) {
                        Text("JCross IR").tag(false)
                        Text("Source File").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                    
                    Divider().frame(height: 16).opacity(0.4)
                }

                if hasUnsavedChanges {
                    Button(action: saveCurrentFile) {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 11))
                            Text("Save")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(Color(red: 0.4, green: 0.85, blue: 0.55))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color(red: 0.15, green: 0.32, blue: 0.20).opacity(0.8))
                        )
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("s", modifiers: .command)
                    .transition(.scale.combined(with: .opacity))
                }

                // Ask AI button
                Button(action: askAIAboutCurrentFile) {
                    HStack(spacing: 4) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11))
                        Text("Ask AI")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(Color(red: 0.7, green: 0.5, blue: 1.0))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color(red: 0.22, green: 0.16, blue: 0.35).opacity(0.8))
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .animation(.easeInOut(duration: 0.15), value: hasUnsavedChanges)
        }
        .frame(height: 34)
        .background(Color(red: 0.11, green: 0.11, blue: 0.15))
    }

    // MARK: - Empty Editor State

    private var emptyEditorState: some View {
        VStack(spacing: 20) {
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 48))
                .foregroundStyle(Color(red: 0.35, green: 0.35, blue: 0.45))

            VStack(spacing: 6) {
                Text("No file selected")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.68))

                Text("Select a file from the explorer to start editing")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.38, green: 0.38, blue: 0.50))
            }

            Button(action: { app.openWorkspace() }) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.badge.plus")
                    Text("Open Workspace")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(red: 0.4, green: 0.75, blue: 1.0))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(red: 0.13, green: 0.22, blue: 0.36).opacity(0.6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(red: 0.4, green: 0.75, blue: 1.0).opacity(0.3), lineWidth: 1)
                        )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    // MARK: - AI Chat Panel (right side)

    private var aiChatPanel: some View {
        VStack(spacing: 0) {
            // Chat header
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(red: 0.55, green: 1.0, blue: 0.65))

                Text("AI Assistant")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.80, green: 0.80, blue: 0.92))

                Spacer()

                // Mode badge
                Text("Human Priority")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.55, green: 1.0, blue: 0.65))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color(red: 0.55, green: 1.0, blue: 0.65).opacity(0.12))
                            .overlay(
                                Capsule()
                                    .stroke(Color(red: 0.55, green: 1.0, blue: 0.65).opacity(0.35), lineWidth: 0.8)
                            )
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(red: 0.11, green: 0.11, blue: 0.15))
            .overlay(
                Rectangle()
                    .fill(Color(red: 0.55, green: 1.0, blue: 0.65).opacity(0.25))
                    .frame(height: 1),
                alignment: .top
            )

            Divider().opacity(0.25)

            // Chat view
            AgentChatView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(red: 0.10, green: 0.10, blue: 0.14))
    }

    // MARK: - Status Bar

    private var humanPriorityStatusBar: some View {
        HStack(spacing: 12) {
            // Mode indicator
            HStack(spacing: 5) {
                Image(systemName: "keyboard")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.55, green: 1.0, blue: 0.65))
                Text("Human Priority")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(red: 0.55, green: 1.0, blue: 0.65))
            }

            Divider().frame(height: 12).opacity(0.4)

            // File info
            if let url = app.selectedFile {
                Text(url.lastPathComponent)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.70))

                Text("•")
                    .foregroundStyle(Color(red: 0.35, green: 0.35, blue: 0.48))

                Text(editorLanguage.uppercased())
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(red: 0.55, green: 0.55, blue: 0.70))

                if hasUnsavedChanges {
                    Text("•")
                        .foregroundStyle(Color(red: 0.35, green: 0.35, blue: 0.48))
                    Text("●")
                        .font(.system(size: 8))
                        .foregroundStyle(Color(red: 0.9, green: 0.7, blue: 0.3))
                }
            }

            Spacer()

            // Model status (reuse from StatusBarView)
            StatusBarView(terminal: app.terminal)
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }

    // MARK: - Actions

    private func loadFileIntoEditor(url: URL?) {
        guard let url = url else { return }
        let gatekeeper = GatekeeperModeState.shared
        if gatekeeper.isEnabled && !app.showGatekeeperRawCode {
            let relativePath: String
            if let wsPath = app.workspaceURL?.path,
               url.path.hasPrefix(wsPath + "/") {
                relativePath = String(url.path.dropFirst(wsPath.count + 1))
            } else {
                relativePath = url.lastPathComponent
            }
            Task {
                let vault = gatekeeper.vault
                let result = vault.read(relativePath: relativePath)
                if let vaultResult = result {
                    let banner = """
                    ;;; 🛡️ GATEKEEPER MODE — JCross IR View
                    ;;; Real identifiers have been replaced with node IDs.
                    ;;; Schema: \(vaultResult.entry.schemaSessionID.prefix(12))
                    ;;; Nodes: \(vaultResult.entry.nodeCount) | Secrets redacted: \(vaultResult.entry.secretCount)
                    ;;; Source: \(relativePath)
                    ;;; 
                    ;;; (To view raw code, toggle "Source File" above)
                    ;;;
                    """
                    let irContent = banner + "\n" + vaultResult.jcrossContent
                    await MainActor.run {
                        editorContent = irContent
                        editorLanguage = "jcross"
                        hasUnsavedChanges = false
                        saveStatus = .saved
                    }
                } else {
                    let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    let warning = app.t("""
                    ;;; ⚠️ GATEKEEPER MODE — This file is not yet converted to JCross
                    ;;; Please update the Vault via [Gatekeeper Settings] -> [Start Batch Conversion]
                    ;;; * The following is the raw source code. This view is temporary.
                    ;;;
                    
                    """, """
                    ;;; ⚠️ GATEKEEPER MODE — このファイルはまだ JCross 変換されていません
                    ;;; [Gatekeeper 設定] → [一括変換を開始] でVaultを更新してください
                    ;;; ※ 以下は実コードです。このビューは一時的なものです
                    ;;;
                    
                    """)
                    await MainActor.run {
                        editorContent = warning + raw
                        editorLanguage = "jcross"
                        hasUnsavedChanges = false
                        saveStatus = .saved
                    }
                }
            }
        } else {
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                editorContent = content
                editorLanguage = languageForExtension(url.pathExtension)
                hasUnsavedChanges = false
                saveStatus = .saved
            } catch {
                editorContent = ""
            }
        }
    }

    private func saveCurrentFile() {
        guard let url = app.selectedFile, hasUnsavedChanges else { return }
        saveStatus = .saving
        do {
            try editorContent.write(to: url, atomically: true, encoding: .utf8)
            hasUnsavedChanges = false
            saveStatus = .saved
            app.selectedFileContent = editorContent
            ToastManager.shared.show(
                "Saved \(url.lastPathComponent)",
                icon: "checkmark.circle.fill",
                color: Color(red: 0.3, green: 0.9, blue: 0.5)
            )
        } catch {
            saveStatus = .unsaved
            ToastManager.shared.show("Save failed: \(error.localizedDescription)", icon: "xmark.circle.fill", color: .red)
        }
    }

    private func askAIAboutCurrentFile() {
        guard let url = app.selectedFile else { return }
        let filename = url.lastPathComponent
        // Pre-fill chat with context about the current file
        app.addSystemMessage("📄 Now editing: **\(filename)**\n```\(editorLanguage)\n\(editorContent.prefix(2000))\n```")
        ToastManager.shared.show("File context sent to AI", icon: "sparkles", color: Color(red: 0.7, green: 0.5, blue: 1.0))
    }

    // MARK: - Helpers

    private func fileIcon(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "swift":  return "swift"
        case "ts","js","tsx","jsx": return "doc.text"
        case "py":     return "doc.text"
        case "json":   return "curlybraces"
        case "md":     return "doc.richtext"
        case "html","htm": return "globe"
        case "css":    return "paintbrush"
        default:       return "doc.text"
        }
    }

    private func fileIconColor(for url: URL) -> Color {
        switch url.pathExtension.lowercased() {
        case "swift":  return Color(red: 1.0, green: 0.55, blue: 0.25)
        case "ts","tsx": return Color(red: 0.3, green: 0.6, blue: 1.0)
        case "js","jsx": return Color(red: 1.0, green: 0.85, blue: 0.2)
        case "py":     return Color(red: 0.4, green: 0.8, blue: 0.4)
        case "json":   return Color(red: 1.0, green: 0.75, blue: 0.3)
        case "md":     return Color(red: 0.7, green: 0.7, blue: 0.85)
        case "html","htm": return Color(red: 1.0, green: 0.5, blue: 0.3)
        default:       return Color(red: 0.6, green: 0.6, blue: 0.75)
        }
    }

    private func languageForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "swift":        return "swift"
        case "ts", "tsx":    return "typescript"
        case "js", "jsx":    return "javascript"
        case "py":           return "python"
        case "json":         return "json"
        case "md":           return "markdown"
        case "html", "htm":  return "html"
        case "css":          return "css"
        case "sh":           return "bash"
        case "yml", "yaml":  return "yaml"
        case "rs":           return "rust"
        case "go":           return "go"
        case "kt":           return "kotlin"
        default:             return ext.isEmpty ? "text" : ext
        }
    }
}

// MARK: - CodeEditorView
// Native NSTextView-based code editor with line numbers and monospaced font.
// Supports direct editing and calls onEdit callback on each change.

struct CodeEditorView: NSViewRepresentable {
    @Binding var content: String
    let language: String
    var isEditable: Bool = true
    let onEdit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = NSColor(red: 0.88, green: 0.88, blue: 0.95, alpha: 1.0)
        textView.backgroundColor = NSColor(red: 0.09, green: 0.09, blue: 0.12, alpha: 1.0)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.usesFindBar = true

        // Padding
        textView.textContainerInset = NSSize(width: 16, height: 10)

        // Line wrap off for code
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.backgroundColor = NSColor(red: 0.09, green: 0.09, blue: 0.12, alpha: 1.0)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.isEditable != isEditable {
            textView.isEditable = isEditable
        }
        if textView.string != content {
            let selectedRange = textView.selectedRange()
            textView.string = content
            context.coordinator.applyHighlighting(to: textView)
            // Restore selection if possible
            let safeLen = min(selectedRange.location + selectedRange.length, textView.string.count)
            if safeLen <= textView.string.count {
                textView.setSelectedRange(NSRange(location: min(selectedRange.location, textView.string.count), length: 0))
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        init(_ parent: CodeEditorView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if parent.content != textView.string {
                parent.content = textView.string
                parent.onEdit()
            }
            applyHighlighting(to: textView)
        }

        func applyHighlighting(to textView: NSTextView) {
            guard let textStorage = textView.textStorage else { return }
            let string = textStorage.string
            let langEnum = SyntaxHighlighter.language(for: URL(fileURLWithPath: "dummy.\(parent.language)"))
            let tokens = SyntaxHighlighter.tokenize(string, language: langEnum)
            
            // Only update layout attributes to avoid interfering with cursor and undo state
            textStorage.beginEditing()
            let fullRange = NSRange(location: 0, length: textStorage.length)
            
            // Apply background safely to reset
            textStorage.removeAttribute(.foregroundColor, range: fullRange)
            textStorage.removeAttribute(.font, range: fullRange)
            
            var currentIndex = 0
            for token in tokens {
                let tokenLength = token.text.utf16.count
                if currentIndex + tokenLength <= fullRange.length {
                    let range = NSRange(location: currentIndex, length: tokenLength)
                    let nsColor = NSColor(token.kind.color)
                    textStorage.addAttribute(.foregroundColor, value: nsColor, range: range)
                    
                    if token.kind == .keyword || token.kind == .keyword2 {
                        textStorage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold), range: range)
                    } else {
                        textStorage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), range: range)
                    }
                }
                currentIndex += tokenLength
            }
            textStorage.endEditing()
        }
    }
}
