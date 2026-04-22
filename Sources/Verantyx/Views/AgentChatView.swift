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
            .help("新しいセッション")

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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(app.messages) { msg in
                        AgentMessageView(message: msg)
                            .id(msg.id)
                    }
                    if app.isGenerating {
                        AgentThinkingView()
                            .id("generating")
                    }
                }
                .padding(14)
            }
            .onChange(of: app.messages.count) { _ in
                withAnimation {
                    if app.isGenerating {
                        proxy.scrollTo("generating")
                    } else if let last = app.messages.last {
                        proxy.scrollTo(last.id)
                    }
                }
            }
        }
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
                app.connectOllama()
            } label: {
                HStack(spacing: 8) {
                    Text("MLX")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 0.3, green: 0.3, blue: 0.35))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(red: 0.6, green: 0.9, blue: 0.6),
                                    in: RoundedRectangle(cornerRadius: 3))

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
                        Text("停止").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(red: 0.8, green: 0.2, blue: 0.2))
                    )
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
                            (app.inputText.isEmpty && app.attachedImages.isEmpty && app.attachedFiles.isEmpty)
                            ? Color(red: 0.4, green: 0.4, blue: 0.5)
                            : Color(red: 0.4, green: 0.7, blue: 1.0)
                        )
                        .padding(8)
                }
                .buttonStyle(.plain)
                .disabled(app.inputText.trimmingCharacters(in: .whitespaces).isEmpty
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

            // ── Selected code-file badge ──────────────────────────────
            if let file = app.selectedFile {
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
            HStack(alignment: .bottom, spacing: 6) {
                // Attach image button
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
                }
                .buttonStyle(.plain)
                .disabled(!app.isMultimodalModel)
                .help(app.isMultimodalModel
                      ? "画像を添付"
                      : "このモデルはマルチモーダル非対応です")

                // Attach file button
                Button {
                    let picked = AttachmentManager.pickFiles()
                    app.attachedFiles.append(contentsOf: picked)
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(red: 0.6, green: 0.7, blue: 0.85))
                }
                .buttonStyle(.plain)
                .help("ファイルを添付")

                // Text editor with placeholder
                ZStack(alignment: .topLeading) {
                    if app.inputText.isEmpty {
                        Text(app.selectedFile == nil ? "Ask VerantyxAgent anything…" : "Describe the changes you want…")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(red: 0.38, green: 0.38, blue: 0.45))
                            .padding(.leading, 4).padding(.top, 9)
                    }
                    TextEditor(text: $app.inputText)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(red: 0.88, green: 0.88, blue: 0.92))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 44, maxHeight: 110)
                        .focused($inputFocused)
                        .onKeyPress(.return) {
                            // ⌘+Return to send
                            guard NSEvent.modifierFlags.contains(.command) else { return .ignored }
                            sendMessage()
                            return .handled
                        }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(red: 0.17, green: 0.17, blue: 0.21))
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
        let text = app.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !app.isGenerating else { return }
        // Pass text BEFORE clearing — AppState.sendMessage reads inputText
        // so we pass it explicitly to avoid the empty-string race
        app.inputText = ""
        app.sendMessage(with: text)
    }

    private var modelDisplayName: String {
        switch app.modelStatus {
        case .ollamaReady(let m): return m
        case .ready(let n):        return n
        default:                   return "Select model ↓"
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

struct AgentMessageView: View {
    let message: ChatMessage

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

    var body: some View {
        switch message.role {
        case .user:
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 50)
                Text(message.content)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(red: 0.2, green: 0.35, blue: 0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

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
                    Text("VerantyxAgent")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color(red: 0.4, green: 0.7, blue: 1.0))

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

        case .system:
            HStack(spacing: 6) {
                Image(systemName: "info.circle").font(.caption2)
                Text(message.content).font(.system(size: 11))
            }
            .foregroundStyle(Color(red: 0.45, green: 0.45, blue: 0.6))
            .frame(maxWidth: .infinity, alignment: .center)
        }
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
