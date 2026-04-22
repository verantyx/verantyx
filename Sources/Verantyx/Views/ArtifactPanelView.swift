import SwiftUI
import WebKit

// MARK: - ArtifactPanelView
// Right-side Artifact Panel — Claude-style live preview of HTML/Mermaid/Markdown/SVG/Code.
// In AI Priority mode this replaces the SideBySideDiffView entirely.

struct ArtifactPanelView: View {
    @EnvironmentObject var app: AppState

    enum DisplayTab: String, CaseIterable {
        case preview = "Preview"
        case code    = "Code"
        case diff    = "Diff"
    }

    @State private var activeTab: DisplayTab = .preview
    @State private var copyState: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            panelHeader

            Divider().opacity(0.3)

            switch activeTab {
            case .preview:
                artifactPreview
            case .code:
                codeView
            case .diff:
                // Hand off to the existing diff view — must pass EnvironmentObject
                SideBySideDiffView()
                    .environmentObject(app)
            }
        }
        .background(Color(red: 0.10, green: 0.10, blue: 0.13))
        .onChange(of: app.currentArtifact?.id) { _ in
            // Auto-switch to preview when a new artifact arrives
            if app.currentArtifact != nil { activeTab = .preview }
        }
    }

    // MARK: - Header

    private var panelHeader: some View {
        HStack(spacing: 0) {
            // Artifact title + type badge
            if let art = app.currentArtifact {
                Image(systemName: art.type.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(typeColor(art.type))
                    .padding(.trailing, 5)
                Text(art.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(red: 0.88, green: 0.88, blue: 0.94))
                    .lineLimit(1)
                Spacer(minLength: 8)
            } else {
                Image(systemName: "rectangle.on.rectangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Artifact")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            // Tab switcher
            tabSwitcher

            Spacer(minLength: 8)

            // Copy button
            if app.currentArtifact != nil {
                Button {
                    if let code = app.currentArtifact?.content {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        withAnimation { copyState = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            withAnimation { copyState = false }
                        }
                    }
                } label: {
                    Image(systemName: copyState ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(copyState
                                         ? Color(red: 0.3, green: 0.9, blue: 0.5)
                                         : Color(red: 0.55, green: 0.55, blue: 0.65))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
            }

            // History picker
            historyMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(red: 0.13, green: 0.13, blue: 0.17))
    }

    private var tabSwitcher: some View {
        HStack(spacing: 0) {
            ForEach(availableTabs, id: \.rawValue) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) { activeTab = tab }
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 11, weight: activeTab == tab ? .semibold : .regular))
                        .foregroundStyle(activeTab == tab ? .white : Color(red: 0.5, green: 0.5, blue: 0.62))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            activeTab == tab
                                ? Color.white.opacity(0.08)
                                : Color.clear
                        )
                        .overlay(
                            Rectangle()
                                .fill(activeTab == tab ? tabAccent(tab) : Color.clear)
                                .frame(height: 1.5),
                            alignment: .bottom
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .background(Color(red: 0.16, green: 0.16, blue: 0.20))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var availableTabs: [DisplayTab] {
        if app.currentArtifact?.type.isWebRenderable == true {
            return [.preview, .code, .diff]
        }
        return [.code, .diff]
    }

    // MARK: - Preview (WKWebView)

    private var artifactPreview: some View {
        Group {
            if let art = app.currentArtifact {
                ArtifactWebView(artifact: art)
                    .id(art.id)  // force reload on change
            } else {
                emptyState
            }
        }
    }

    // MARK: - Code view

    private var codeView: some View {
        Group {
            if let art = app.currentArtifact {
                ScrollView([.horizontal, .vertical]) {
                    Text(art.content)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(red: 0.82, green: 0.82, blue: 0.88))
                        .textSelection(.enabled)
                        .lineSpacing(2)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(red: 0.07, green: 0.07, blue: 0.10))
            } else {
                emptyState
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundStyle(Color(red: 0.25, green: 0.25, blue: 0.35))
            VStack(spacing: 6) {
                Text("Artifact Preview")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(red: 0.45, green: 0.45, blue: 0.58))
                Text("AIが <artifact> タグ付きのコンテンツを生成すると\nここにライブプレビューが表示されます")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(red: 0.38, green: 0.38, blue: 0.48))
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - History menu

    private var historyMenu: some View {
        Menu {
            ForEach(app.artifactHistory) { art in
                Button {
                    app.currentArtifact = art
                    activeTab = art.type.isWebRenderable ? .preview : .code
                } label: {
                    HStack {
                        Image(systemName: art.type.icon)
                        Text(art.title)
                        Spacer()
                        Text(art.createdAt, style: .relative)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if app.artifactHistory.isEmpty {
                Text("履歴なし").foregroundStyle(.secondary)
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 0.5, green: 0.5, blue: 0.62))
        }
        .menuStyle(.borderlessButton)
        .help("Artifact履歴")
    }

    // MARK: - Helpers

    private func typeColor(_ type: Artifact.ArtifactType) -> Color {
        switch type {
        case .html:     return Color(red: 0.90, green: 0.45, blue: 0.20)
        case .markdown: return Color(red: 0.55, green: 0.85, blue: 0.70)
        case .mermaid:  return Color(red: 0.45, green: 0.75, blue: 1.00)
        case .code:     return Color(red: 0.70, green: 0.55, blue: 1.00)
        case .svg:      return Color(red: 0.98, green: 0.70, blue: 0.30)
        }
    }

    private func tabAccent(_ tab: DisplayTab) -> Color {
        switch tab {
        case .preview: return Color(red: 0.3, green: 0.85, blue: 0.60)
        case .code:    return Color(red: 0.6, green: 0.50, blue: 0.95)
        case .diff:    return Color(red: 0.4, green: 0.70, blue: 1.00)
        }
    }
}

// MARK: - ArtifactWebView (WKWebView wrapper)

struct ArtifactWebView: NSViewRepresentable {
    let artifact: Artifact

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.setValue(false, forKey: "drawsBackground")
        wv.layer?.backgroundColor = NSColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1).cgColor
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        let html = buildHTML(for: artifact)
        wv.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - HTML construction per type

    private func buildHTML(for art: Artifact) -> String {
        switch art.type {
        case .html:
            // Inject dark background + sandbox reset
            return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
              * { box-sizing: border-box; }
              body {
                margin: 0; padding: 12px;
                background: #0f0f12; color: #dde;
                font-family: -apple-system, sans-serif;
              }
            </style>
            </head>
            <body>\(art.content)</body>
            </html>
            """

        case .markdown:
            return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
            <style>
              body {
                margin: 0; padding: 20px;
                background: #0f0f12; color: #d8d8e8;
                font-family: -apple-system, sans-serif; line-height: 1.65;
                max-width: 820px;
              }
              pre { background: #1a1a22; padding: 12px; border-radius: 6px; overflow-x: auto; }
              code { font-family: 'SF Mono', monospace; font-size: 0.88em; }
              h1,h2,h3 { color: #b8c8f8; }
              a { color: #6ab0f5; }
              blockquote { border-left: 3px solid #334; padding-left: 14px; color: #888; }
            </style>
            </head>
            <body>
            <div id="content"></div>
            <script>
              document.getElementById('content').innerHTML =
                marked.parse(\(jsonStringLiteral(art.content)));
            </script>
            </body>
            </html>
            """

        case .mermaid:
            return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
            <style>
              body { margin: 0; padding: 20px; background: #0f0f12; display: flex; justify-content: center; }
              .mermaid { background: #161620; border-radius: 8px; padding: 20px; }
              svg { max-width: 100%; }
            </style>
            </head>
            <body>
            <div class="mermaid">\(art.content)</div>
            <script>
              mermaid.initialize({ startOnLoad: true, theme: 'dark',
                themeVariables: { background: '#161620', primaryColor: '#2d4a8a',
                  lineColor: '#4a6090', textColor: '#c8d4f0' }
              });
            </script>
            </body>
            </html>
            """

        case .svg:
            return """
            <!DOCTYPE html>
            <html>
            <head><meta charset="utf-8">
            <style>
              body { margin: 0; padding: 20px; background: #0f0f12;
                     display: flex; justify-content: center; align-items: center; min-height: 100vh; }
              svg { max-width: 100%; max-height: 90vh; }
            </style>
            </head>
            <body>\(art.content)</body>
            </html>
            """

        case .code:
            // Syntax highlight with highlight.js
            let lang = art.title.lowercased()
            return """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/atom-one-dark.min.css">
            <script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
            <style>
              body { margin: 0; background: #0f0f12; }
              pre { margin: 0; border-radius: 0; }
              .hljs { background: #0f0f12; padding: 20px; font-size: 12px; line-height: 1.55; }
            </style>
            </head>
            <body>
            <pre><code class="\(lang)">\(escapeHTML(art.content))</code></pre>
            <script>hljs.highlightAll();</script>
            </body>
            </html>
            """
        }
    }

    private func jsonStringLiteral(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
        return "`\(escaped)`"
    }

    private func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
