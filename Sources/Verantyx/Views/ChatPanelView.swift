import SwiftUI

// MARK: - ChatPanelView
// Center panel: conversation history + input box.

struct ChatPanelView: View {
    @EnvironmentObject var app: AppState
    @FocusState private var isFocused: Bool
    @State private var scrollProxy: ScrollViewProxy?

    var body: some View {
        VStack(spacing: 0) {
            // Context file badge
            if let file = app.selectedFile {
                contextBadge(file)
            }

            Divider()

            // Messages
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(app.messages) { msg in
                            MessageBubble(message: msg)
                                .id(msg.id)
                        }
                        if app.isGenerating {
                            ThinkingBubble()
                                .id("generating")
                        }
                    }
                    .padding(16)
                }
                .onChange(of: app.messages.count) { _ in
                    withAnimation {
                        if app.isGenerating {
                            proxy.scrollTo("generating")
                        } else if let lastId = app.messages.last?.id {
                            proxy.scrollTo(lastId)
                        }
                    }
                }
                .onChange(of: app.isGenerating) { generating in
                    if generating {
                        withAnimation { proxy.scrollTo("generating") }
                    }
                }
            }

            Divider()

            // Input bar
            inputBar
        }
        .navigationTitle("Chat")
    }

    private func contextBadge(_ file: URL) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
                .font(.caption2)
            Text(file.lastPathComponent)
                .font(.caption)
                .fontWeight(.medium)
            Spacer()
            Button {
                app.selectedFile = nil
                app.selectedFileContent = ""
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.1))
        .foregroundStyle(.secondary)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Text field with auto-expand
            ZStack(alignment: .leading) {
                if app.inputText.isEmpty {
                    Text(app.selectedFile == nil
                         ? "Ask anything, or select a file to edit…"
                         : "Describe the changes you want…")
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 4)
                        .padding(.top, 1)
                }
                TextEditor(text: $app.inputText)
                    .font(.system(.body))
                    .frame(minHeight: 36, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .onSubmit { sendIfPossible() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(
                        isFocused ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor),
                        lineWidth: isFocused ? 1.5 : 0.5
                    )
            )

            // Send button
            Button {
                sendIfPossible()
            } label: {
                Image(systemName: app.isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var canSend: Bool { !app.inputText.trimmingCharacters(in: .whitespaces).isEmpty && !app.isGenerating }

    private func sendIfPossible() {
        guard canSend else { return }
        app.sendMessage()
    }
}

// MARK: - MessageBubble

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(message.content)
                    .font(.body)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }

        case .assistant:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "brain.head.profile")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.12), in: Circle())

                // Render markdown-style code blocks
                AssistantText(content: message.content)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 40)
            }

        case .system:
            HStack {
                Image(systemName: "info.circle")
                    .font(.caption)
                Text(message.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}


// MARK: - ThinkingBubble

struct ThinkingBubble: View {
    @State private var dotPhase = 0

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "brain.head.profile")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 28, height: 28)
                .background(Color.accentColor.opacity(0.12), in: Circle())

            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                        .scaleEffect(dotPhase == i ? 1.2 : 0.8)
                        .opacity(dotPhase == i ? 1.0 : 0.4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.3)) {
                    dotPhase = (dotPhase + 1) % 3
                }
            }
        }
    }
}
