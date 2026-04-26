import SwiftUI

// MARK: - AgentChatView
// Center panel: "Vibe Coding Workspace" + "Thinking Log" tabs
// Shows AntigravityAgent with <think> rendering in teal

struct AgentChatView: View {
    @EnvironmentObject var app: AppState
    @State private var activeTab: Tab = .workspace
    @State private var inputText: String = ""
    @FocusState private var inputFocused: Bool

    enum Tab: String, CaseIterable {
        case workspace = "Workspace"
        case history   = "History"
        case thinking  = "Thinking"
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Tab bar ─────────────────────────────────────────────
            tabBar

            Divider().opacity(0.3)

            // ── Content ─────────────────────────────────────────────
            switch activeTab {
            case .workspace: workspaceView
            case .history:   SessionHistoryView().environmentObject(app)
            case .thinking:  thinkingLogView
            }

            Divider().opacity(0.3)

            // ── Model selector bar ───────────────────────────────────
            modelSelectorBar

            Divider().opacity(0.3)

            // ── Input ────────────────────────────────────────────────
            inputBar
        }
        .background(Color(red: 0.13, green: 0.13, blue: 0.16))
        // ─ Sync tab state with AppState (for session restore programmatic switch) ─
        .onChange(of: app.activeChatTab) { _, newVal in
            switch newVal {
            case 0: activeTab = .workspace
            case 1: activeTab = .history
            case 2: activeTab = .thinking
            default: break
            }
        }
        .onChange(of: activeTab) { _, tab in
            let idx: Int
            switch tab {
            case .workspace: idx = 0
            case .history:   idx = 1
            case .thinking:  idx = 2
            }
            if app.activeChatTab != idx { app.activeChatTab = idx }
        }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.rawValue) { tab in
                Button {
                    activeTab = tab
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tabIcon(tab))
                            .font(.system(size: 10))
                        Text(tab.rawValue)
                            .font(.system(size: 12, weight: activeTab == tab ? .semibold : .regular))
                    }
                    .foregroundStyle(activeTab == tab
                        ? Color.white
                        : Color(red: 0.55, green: 0.55, blue: 0.65))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        activeTab == tab
                            ? Color.white.opacity(0.06)
                            : Color.clear
                    )
                    .overlay(
                        Rectangle()
                            .fill(tabAccentColor(tab))
                            .frame(height: 1.5),
                        alignment: .bottom
                    )
                    .opacity(activeTab == tab ? 1 : 0.7)
                }
                .buttonStyle(.plain)

                // Session badge on History tab
                if tab == .history && app.sessions.sessions.count > 0 {
                    Text("\(app.sessions.sessions.count)")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1.5)
                        .background(Color(red: 0.4, green: 0.7, blue: 1.0), in: Capsule())
                        .offset(x: -4, y: -4)
                }
            }
            Spacer()

            // New session quick button
            Button {
                app.newChatSession()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 0.5, green: 0.5, blue: 0.6))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            .help(app.t("New session", "新しいセッション"))

            Button { } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.5, green: 0.5, blue: 0.6))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
        }
        .background(Color(red: 0.15, green: 0.15, blue: 0.19))
    }

    private func tabIcon(_ tab: Tab) -> String {
        switch tab {
        case .workspace: return "bolt.fill"
        case .history:   return "clock.arrow.circlepath"
        case .thinking:  return "brain"
        }
    }

    private func tabAccentColor(_ tab: Tab) -> Color {
        switch tab {
        case .workspace: return Color(red: 0.4, green: 0.7, blue: 1.0)
        case .history:   return Color(red: 0.5, green: 0.9, blue: 0.6)
        case .thinking:  return Color(red: 0.7, green: 0.5, blue: 1.0)
        }
    }

    // MARK: - Workspace (main chat)

    private var workspaceView: some View {
        // NSTextView ベースのトランスクリプト。
        // 単一テキストストレージのためメッセージをまたいでドラッグ選択・コピーができる。
        ChatTranscriptView(messages: app.messages, isGenerating: app.isGenerating)
    }


    // MARK: - Thinking Log (shows <think> sections)

    private var thinkingLogView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(app.messages.filter { !extractThinking(from: $0.content).isEmpty }) { msg in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(extractThinking(from: msg.content))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Color(red: 0.35, green: 0.85, blue: 0.80))
                            .textSelection(.enabled)
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                    Divider().opacity(0.2)
                }
                if app.messages.filter({ !extractThinking(from: $0.content).isEmpty }).isEmpty {
                    VStack(spacing: 12) {
                        Spacer()
                        Image(systemName: "brain")
                            .font(.title)
                            .foregroundStyle(Color(red: 0.4, green: 0.4, blue: 0.5))
                        Text("Thinking logs will appear here\nwhen the model uses chain-of-thought.")
                            .font(.callout)
                            .foregroundStyle(Color(red: 0.4, green: 0.4, blue: 0.5))
                            .multilineTextAlignment(.center)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(40)
                }
            }
            .padding(12)
        }
    }

    // MARK: - Model selector bar

    private var modelSelectorBar: some View {
        HStack(spacing: 8) {
            // ── Model chip ────────────────────────────────────────────
            Button {
                // Tapping re-opens model selection (no-op action; just shows the intent)
            } label: {
                HStack(spacing: 8) {
                    // Backend badge — dynamic based on active backend
                    let isOllama: Bool = {
                        if case .ollamaReady = app.modelStatus { return true }
                        return false
                    }()
                    Text(isOllama ? "OLLAMA" : "MLX")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.15, green: 0.15, blue: 0.18))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(
                            isOllama
                                ? Color(red: 0.45, green: 0.9, blue: 0.6)   // green for Ollama
                                : Color(red: 0.65, green: 0.5, blue: 1.0),  // purple for MLX
                            in: RoundedRectangle(cornerRadius: 3)
                        )

                    Text(modelDisplayName)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color(red: 0.75, green: 0.75, blue: 0.85))

                    // Multimodal badge
                    if app.isMultimodalModel {
                        Text("👁")
                            .font(.system(size: 10))
                            .help("Multimodal — images supported")
                    }

                    Image(systemName: "chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(Color(red: 0.5, green: 0.5, blue: 0.6))
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            // ── Stop button (visible only while generating) ───────────
            if app.isGenerating {
                Button {
                    app.cancelGeneration()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "stop.fill").font(.system(size: 11))
                        Text(app.t("Stop", "停止")).font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(red: 0.8, green: 0.2, blue: 0.2))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
            }

            // ── Send button ───────────────────────────────────────────
            if !app.isGenerating {
                Button { sendMessage() } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(
                            (inputText.isEmpty && app.attachedImages.isEmpty && app.attachedFiles.isEmpty)
                            ? Color(red: 0.4, green: 0.4, blue: 0.5)
                            : Color(red: 0.4, green: 0.7, blue: 1.0)
                        )
                        .padding(8)
                }
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty
                          && app.attachedImages.isEmpty
                          && app.attachedFiles.isEmpty)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Color(red: 0.15, green: 0.15, blue: 0.19))
        .animation(.easeInOut(duration: 0.15), value: app.isGenerating)
    }

    // MARK: - Input bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            // ── Attachment preview strip ──────────────────────────────
            if !app.attachedImages.isEmpty || !app.attachedFiles.isEmpty {
                attachmentStrip
                Divider().opacity(0.3)
            }

            // ── IDE Fix mode banner / normal file badge ───────────────
            if app.selfFixMode {
                // Persistent IDE Fix banner — always visible while mode is active
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(red: 1.0, green: 0.65, blue: 0.15))

                    Text("🔧 IDE Fix Mode")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 1.0, green: 0.75, blue: 0.30))

                    if let file = app.selectedFile {
                        Text("▸ \(file.lastPathComponent)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color(red: 0.9, green: 0.6, blue: 0.2).opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("▸ IDE Source Index")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color(red: 0.9, green: 0.6, blue: 0.2).opacity(0.8))
                    }

                    Spacer()

                    // Exit button — explicitly exits IDE Fix mode
                    Button {
                        app.selfFixMode = false
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                            Text(app.t("Exit Mode", "モード終了"))
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(Color(red: 1.0, green: 0.65, blue: 0.15))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color(red: 1.0, green: 0.65, blue: 0.15).opacity(0.5), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.28, green: 0.18, blue: 0.04),
                            Color(red: 0.22, green: 0.14, blue: 0.02)
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .overlay(
                    Rectangle()
                        .fill(Color(red: 1.0, green: 0.60, blue: 0.10).opacity(0.6))
                        .frame(height: 1),
                    alignment: .bottom
                )
            } else if let file = app.selectedFile {
                // Normal mode: selected code-file badge
                HStack(spacing: 6) {
                    Image(systemName: FileIcons.icon(for: file)).font(.system(size: 10))
                    Text(file.lastPathComponent).font(.system(size: 11, design: .monospaced))
                    Spacer()
                    Button {
                        app.selectedFile = nil; app.selectedFileContent = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10))
                    }.buttonStyle(.plain)
                }
                .foregroundStyle(Color(red: 0.5, green: 0.7, blue: 0.9))
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(Color(red: 0.2, green: 0.3, blue: 0.45).opacity(0.5))
            }

            // ── Text input + action buttons ───────────────────────────
            HStack(alignment: .bottom, spacing: 8) {

                // ── Fixed-width action button group ──────────────────────
                // IMPORTANT: fixed frame prevents Self Fix toggle from
                // shifting the TextEditor to the right
                HStack(spacing: 2) {
                    // Attach image
                    Button {
                        let picked = AttachmentManager.pickImages()
                        app.attachedImages.append(contentsOf: picked)
                    } label: {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 15))
                            .foregroundStyle(
                                app.isMultimodalModel
                                ? Color(red: 0.6, green: 0.8, blue: 1.0)
                                : Color(red: 0.35, green: 0.35, blue: 0.45)
                            )
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .disabled(!app.isMultimodalModel)
                    .help(app.isMultimodalModel ? app.t("Attach image", "画像を添付") : app.t("Multimodal not supported by this model", "このモデルはマルチモーダル非対応です"))

                    // Attach file
                    Button {
                        let picked = AttachmentManager.pickFiles()
                        app.attachedFiles.append(contentsOf: picked)
                    } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 15))
                            .foregroundStyle(Color(red: 0.6, green: 0.7, blue: 0.85))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help(app.t("Attach file", "ファイルを添付"))

                    // ── Self Fix — icon-only, fixed frame ────────────────
                    // Using just the icon + background color (no expanding text)
                    // so width never changes and TextEditor stays in place.
                    Button {
                        app.selfFixMode.toggle()
                    } label: {
                        Image(systemName: app.selfFixMode
                              ? "wrench.and.screwdriver.fill"
                              : "wrench.and.screwdriver")
                            .font(.system(size: 13))
                            .foregroundStyle(app.selfFixMode
                                             ? Color.black
                                             : Color(red: 0.55, green: 0.55, blue: 0.65))
                            .frame(width: 26, height: 26)
                            .background(
                                app.selfFixMode
                                    ? Color(red: 1.0, green: 0.65, blue: 0.15)
                                    : Color.white.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(app.selfFixMode
                          ? app.t("Self Fix Mode ON — tap to disable", "Self Fix モード ON — タップで解除")
                          : app.t("Self Fix: auto-fix IDE source", "Self Fix: IDEソースを自己修正"))
                }
                // FIXED width — never changes regardless of selfFixMode
                .frame(width: 86, alignment: .leading)

                // ── TextEditor + placeholder ───────────────────────────
                // Placeholder padding must match NSTextView's internal insets:
                //   lineFragmentPadding ≈ 5pt (leading)
                //   textContainerInset.y ≈ 5-7pt (top)
                ZStack(alignment: .topLeading) {
                    if inputText.isEmpty {
                        Text(app.selfFixMode
                             ? app.t("Fix this IDE… (Self Fix Mode)", "このIDEを修正… (Self Fix モード)")
                             : (app.selectedFile == nil
                                ? app.t("Ask VerantyxAgent anything…", "Ask VerantyxAgent anything…")
                                : app.t("Describe the changes you want…", "Describe the changes you want…")))
                            .font(.system(size: 13))
                            .foregroundStyle(
                                app.selfFixMode
                                    ? Color(red: 1.0, green: 0.65, blue: 0.15).opacity(0.55)
                                    : Color(red: 0.38, green: 0.38, blue: 0.45)
                            )
                            // Matches NSTextView's default lineFragmentPadding (5) + inset (~6)
                            .padding(.leading, 5)
                            .padding(.top, 6)
                            // No pointer interaction so clicks pass through to TextEditor
                            .allowsHitTesting(false)
                    }
                    ChatInputTextView(
                        text: $inputText,
                        onSend: { sendMessage() },
                        isFocused: $inputFocused
                    )
                    .frame(minHeight: 44, maxHeight: 110)
                }
            }

            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                app.selfFixMode
                    ? Color(red: 0.22, green: 0.16, blue: 0.08)  // warm amber tint in self-fix mode
                    : Color(red: 0.17, green: 0.17, blue: 0.21)
            )
            .overlay(
                // Top border glows orange in self-fix mode
                Rectangle()
                    .fill(app.selfFixMode
                          ? Color(red: 1.0, green: 0.60, blue: 0.10)
                          : Color.clear)
                    .frame(height: 1.5),
                alignment: .top
            )
            .animation(.easeInOut(duration: 0.2), value: app.selfFixMode)
            // Drag-and-drop images onto the input bar
            .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
                handleDrop(providers: providers)
                return true
            }
        }
    }

    // MARK: - Attachment Strip

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // Image thumbnails
                ForEach(app.attachedImages) { img in
                    ZStack(alignment: .topTrailing) {
                        img.swiftUIImage
                            .resizable().scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                            )

                        Button {
                            app.attachedImages.removeAll { $0.id == img.id }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.white)
                                .background(Circle().fill(Color.black.opacity(0.55)))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 4, y: -4)
                    }
                }

                // File chips
                ForEach(app.attachedFiles, id: \.absoluteString) { url in
                    HStack(spacing: 5) {
                        Image(systemName: FileIcons.icon(for: url))
                            .font(.system(size: 10))
                            .foregroundStyle(FileIcons.color(for: url))
                        Text(url.lastPathComponent)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                        Button {
                            app.attachedFiles.removeAll { $0 == url }
                        } label: {
                            Image(systemName: "xmark").font(.system(size: 8))
                        }.buttonStyle(.plain)
                    }
                    .foregroundStyle(Color(red: 0.75, green: 0.75, blue: 0.85))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.white.opacity(0.07))
                    )
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .background(Color(red: 0.14, green: 0.14, blue: 0.18))
    }

    // MARK: - Drag-and-drop handler

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.image") {
                _ = provider.loadDataRepresentation(forTypeIdentifier: "public.image") { data, _ in
                    guard let data, let img = AttachmentManager.loadImage(from: data) else { return }
                    Task { @MainActor in
                        guard app.isMultimodalModel else { return }
                        app.attachedImages.append(img)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                _ = provider.loadItem(forTypeIdentifier: "public.file-url") { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        // If it's an image and model supports multimodal, attach as image
                        let imgExts: Set<String> = ["png","jpg","jpeg","gif","webp","heic","tiff"]
                        if imgExts.contains(url.pathExtension.lowercased()), app.isMultimodalModel,
                           let img = AttachmentManager.loadImage(from: url) {
                            app.attachedImages.append(img)
                        } else {
                            app.attachedFiles.append(url)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !app.isGenerating else { return }
        inputText = ""          // ローカル state を即時クリア（@Published を触る前）
        app.sendMessage(with: text)
    }

    private var modelDisplayName: String {
        switch app.modelStatus {
        case .ollamaReady(let m):              return m
        case .mlxReady(let m):                 return m.components(separatedBy: "/").last ?? m
        case .anthropicReady(let m, _):        return m
        case .ready(let n):                    return n
        case .mlxDownloading(let m):           return "↓ \(m.components(separatedBy: "/").last ?? m)…"
        case .connecting:                      return "Connecting…"
        default:                               return "Select model ↓"
        }
    }

    private func extractThinking(from text: String) -> String {
        let pattern = #"<think>([\s\S]*?)</think>"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return "" }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - AgentMessageView

struct AgentMessageView: View, Equatable {
    let message: ChatMessage

    // Equatable: SwiftUI の .equatable() モディファイアがこれを使って
    // content/role が同一なら再描画をスキップする
    static func == (lhs: AgentMessageView, rhs: AgentMessageView) -> Bool {
        lhs.message.id == rhs.message.id &&
        lhs.message.content == rhs.message.content &&
        lhs.message.role == rhs.message.role
    }

    // Parse <think>...</think> from content
    private var parts: [(isThinking: Bool, text: String)] {
        guard message.role == .assistant else {
            return [(false, message.content)]
        }
        var result: [(Bool, String)] = []
        let pattern = #"<think>([\s\S]*?)</think>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [(false, message.content)]
        }
        var cursor = message.content.startIndex
        let matches = regex.matches(in: message.content, range: NSRange(message.content.startIndex..., in: message.content))

        for match in matches {
            if let r = Range(match.range, in: message.content), r.lowerBound > cursor {
                let text = String(message.content[cursor..<r.lowerBound]).trimmingCharacters(in: .newlines)
                if !text.isEmpty { result.append((false, text)) }
            }
            if let r2 = Range(match.range(at: 1), in: message.content) {
                result.append((true, String(message.content[r2])))
            }
            if let r = Range(match.range, in: message.content) { cursor = r.upperBound }
        }
        if cursor < message.content.endIndex {
            let text = String(message.content[cursor...]).trimmingCharacters(in: .newlines)
            if !text.isEmpty { result.append((false, text)) }
        }
        return result.isEmpty ? [(false, message.content)] : result
    }

    @State private var isHovered   = false
    @State private var copied       = false

    var body: some View {
        switch message.role {
        case .user:
            HStack(alignment: .top, spacing: 6) {
                // Copy button — always visible (dimmed when not hovered)
                copyButton
                    .opacity(isHovered ? 1.0 : 0.35)
                Spacer(minLength: 20)
                Text(message.content)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(red: 0.2, green: 0.35, blue: 0.7),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.12), value: isHovered)

        case .assistant:
            HStack(alignment: .top, spacing: 10) {
                // Agent avatar
                ZStack {
                    Circle().fill(Color(red: 0.2, green: 0.4, blue: 0.8))
                    Image(systemName: "atom")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("VerantyxAgent")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(red: 0.4, green: 0.7, blue: 1.0))
                        Spacer()
                        // Copy button — always visible (dimmed when not hovered)
                        copyButton
                            .opacity(isHovered ? 1.0 : 0.35)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                            if part.isThinking {
                                thinkingTag(part.text)
                            } else {
                                plainText(part.text)
                            }
                        }
                    }
                }
                Spacer(minLength: 20)
            }
            .onHover { isHovered = $0 }
            .animation(.easeInOut(duration: 0.12), value: isHovered)

        case .system:
            HStack(spacing: 6) {
                Image(systemName: "info.circle").font(.caption2)
                Text(message.content)
                    .font(.system(size: 11))
                    .textSelection(.enabled)
            }
            .foregroundStyle(Color(red: 0.45, green: 0.45, blue: 0.6))
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Copy button

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.content, forType: .string)
            withAnimation { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10))
                .foregroundStyle(copied
                    ? Color(red: 0.3, green: 0.9, blue: 0.5)
                    : Color(red: 0.45, green: 0.45, blue: 0.6))
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
        }
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .help(copied ? L("Copied!", "コピーしました！") : L("Copy message", "メッセージをコピー"))
    }

    private func thinkingTag(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("<think>")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color(red: 0.35, green: 0.75, blue: 0.70))
            }
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(red: 0.35, green: 0.85, blue: 0.80))
                .lineSpacing(3)
                .textSelection(.enabled)
            Text("</think>")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color(red: 0.35, green: 0.75, blue: 0.70))
        }
        .padding(8)
        .background(Color(red: 0.12, green: 0.22, blue: 0.22).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
    }

    private func plainText(_ text: String) -> some View {
        AssistantText(content: text)
            .font(.system(size: 13))
    }
}

// MARK: - AgentThinkingView (animated)

struct AgentThinkingView: View {
    @State private var dotPhase = 0
    @State private var thinkingText = "Analyzing…"

    private let thinkingSteps = [
        "Reading context files…",
        "Analyzing project structure…",
        "Running steps…",
        "Diff generation…",
        "Verifying changes…"
    ]
    @State private var stepIndex = 0

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(Color(red: 0.2, green: 0.4, blue: 0.8))
                Image(systemName: "atom")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 4) {
                Text("VerantyxAgent")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(red: 0.4, green: 0.7, blue: 1.0))

                VStack(alignment: .leading, spacing: 2) {
                    Text("<think>")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(red: 0.35, green: 0.75, blue: 0.70))

                    ForEach(Array(thinkingSteps[0...stepIndex].enumerated()), id: \.offset) { i, step in
                        HStack(spacing: 6) {
                            Image(systemName: i < stepIndex ? "checkmark" : "circle.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(i < stepIndex
                                    ? Color(red: 0.4, green: 0.85, blue: 0.5)
                                    : Color(red: 0.4, green: 0.7, blue: 1.0))
                            Text((i < stepIndex ? "- " : "+ ") + step)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(i < stepIndex
                                    ? Color(red: 0.35, green: 0.85, blue: 0.5).opacity(0.8)
                                    : Color(red: 0.35, green: 0.85, blue: 0.80))
                        }
                    }

                    // Animated dots
                    HStack(spacing: 4) {
                        ForEach(0..<3) { i in
                            Circle()
                                .fill(Color(red: 0.35, green: 0.85, blue: 0.80))
                                .frame(width: 4, height: 4)
                                .scaleEffect(dotPhase == i ? 1.4 : 0.8)
                                .opacity(dotPhase == i ? 1 : 0.3)
                        }
                    }
                }
                .padding(8)
                .background(Color(red: 0.12, green: 0.22, blue: 0.22).opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.25)) {
                    dotPhase = (dotPhase + 1) % 3
                }
            }
            Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { _ in
                withAnimation {
                    if stepIndex < thinkingSteps.count - 1 { stepIndex += 1 }
                }
            }
        }
    }
}

// MARK: - ChatInputTextView (IME-aware Enter-to-send)
// NSViewRepresentable wrapping NSTextView for reliable Japanese IME handling.
//
// Behavior:
//   • Enter (no modifier):
//       - If IME has markedText (未確定文字) → confirms composition (default NSTextView behavior)
//       - If no markedText → sends the message
//   • Shift+Enter: inserts newline (multi-line input)
//   • ⌘+Enter: also sends the message (legacy shortcut)

struct ChatInputTextView: NSViewRepresentable {
    @Binding var text: String
    var onSend: () -> Void
    var isFocused: FocusState<Bool>.Binding

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = IMEAwareTextView()
        textView.delegate = context.coordinator
        textView.onSend = onSend
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.textColor = NSColor(red: 0.88, green: 0.88, blue: 0.92, alpha: 1.0)
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 5)
        textView.textContainer?.lineFragmentPadding = 5
        textView.textContainer?.widthTracksTextView = true

        // Caret color
        textView.insertionPointColor = NSColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 1.0)

        scrollView.documentView = textView
        context.coordinator.textView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? IMEAwareTextView else { return }

        // ── GUARD 1: Never interrupt active IME composition ──────────
        // Setting textView.string during composition destroys the markedText.
        if textView.hasMarkedText() {
            textView.onSend = onSend
            return
        }

        // ── GUARD 2: Prevent feedback loop ──────────────────────────
        // textDidChange sets parent.text → triggers updateNSView → must not set string again
        let coordinator = context.coordinator
        guard !coordinator.isSyncingToBinding else {
            textView.onSend = onSend
            return
        }

        // ── Only apply external changes (e.g., clearing after send) ─
        if textView.string != text {
            coordinator.isSyncingFromBinding = true
            textView.string = text
            textView.setSelectedRange(NSRange(location: textView.string.count, length: 0))
            coordinator.isSyncingFromBinding = false
        }

        textView.onSend = onSend
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputTextView
        weak var textView: IMEAwareTextView?

        /// True while textDidChange is propagating to the binding.
        /// Prevents updateNSView from re-entering.
        var isSyncingToBinding = false

        /// True while updateNSView is writing to textView.string.
        /// Prevents textDidChange from re-entering.
        var isSyncingFromBinding = false

        init(parent: ChatInputTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Don't propagate if WE set the string programmatically
            guard !isSyncingFromBinding else { return }

            isSyncingToBinding = true
            parent.text = textView.string
            isSyncingToBinding = false
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.isFocused.wrappedValue = false
        }
    }
}

// MARK: - IMEAwareTextView
// Custom NSTextView subclass that intercepts Enter key events
// and checks IME composition state before deciding to send.

final class IMEAwareTextView: NSTextView {
    var onSend: (() -> Void)?

    override func insertNewline(_ sender: Any?) {
        // ── IME composition active → let default behavior confirm it ──
        if hasMarkedText() {
            super.insertNewline(sender)
            return
        }

        // ── Shift+Enter → insert actual newline (multi-line input) ──
        if NSEvent.modifierFlags.contains(.shift) {
            super.insertNewline(sender)
            return
        }

        // ── Plain Enter (no IME, no Shift) → send message ──
        onSend?()
    }

    // Also support ⌘+Enter as a legacy send shortcut
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36,  // Return key
           event.modifierFlags.contains(.command) {
            onSend?()
            return
        }
        super.keyDown(with: event)
    }
}
