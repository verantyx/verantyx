import Foundation
import SwiftUI

// MARK: - OperationMode
// Controls the overall agent behavior:
//   .aiPriority — no confirmations, no MCP timeouts, full-screen Gemini-style UI
//   .human      — standard confirmations, 60s MCP timeout, 4-pane IDE layout

enum OperationMode: String, CaseIterable, Codable, Identifiable {
    case aiPriority = "AI Priority"
    case human      = "Human"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .aiPriority: return "bolt.fill"
        case .human:      return "person.fill"
        }
    }

    var accentColor: Color {
        switch self {
        case .aiPriority: return Color(red: 1.0, green: 0.35, blue: 0.25)
        case .human:      return Color(red: 0.4, green: 0.75, blue: 1.0)
        }
    }

    var description: String {
        switch self {
        case .aiPriority:
            return "承認なし・MCP無制限・フルスクリーンチャット"
        case .human:
            return "Diff確認あり・MCP 60秒制限・通常IDE"
        }
    }
}

// MARK: - Artifact
// A self-contained renderable output block extracted from AI response.

struct Artifact: Identifiable {
    let id: UUID
    let type: ArtifactType
    var content: String
    var title: String
    var createdAt: Date

    init(id: UUID = UUID(), type: ArtifactType, content: String, title: String = "") {
        self.id        = id
        self.type      = type
        self.content   = content
        self.title     = title.isEmpty ? type.defaultTitle : title
        self.createdAt = Date()
    }

    enum ArtifactType: String {
        case html     = "html"
        case markdown = "markdown"
        case mermaid  = "mermaid"
        case code     = "code"
        case svg      = "svg"

        var defaultTitle: String {
            switch self {
            case .html:     return "HTML Preview"
            case .markdown: return "Markdown"
            case .mermaid:  return "Diagram"
            case .code:     return "Code"
            case .svg:      return "SVG"
            }
        }

        var icon: String {
            switch self {
            case .html:     return "globe"
            case .markdown: return "doc.richtext"
            case .mermaid:  return "arrow.triangle.branch"
            case .code:     return "chevron.left.forwardslash.chevron.right"
            case .svg:      return "squareshape.controlhandles.on.squareshape.controlhandles"
            }
        }

        // Whether this type can be live-rendered in WKWebView
        var isWebRenderable: Bool {
            switch self {
            case .html, .markdown, .mermaid, .svg: return true
            case .code:                              return false
            }
        }

        static func detect(from tag: String) -> ArtifactType {
            let t = tag.lowercased()
            if t.contains("html")                        { return .html }
            if t.contains("mermaid")                     { return .mermaid }
            if t.contains("markdown") || t.contains("md") { return .markdown }
            if t.contains("svg")                         { return .svg }
            return .code
        }
    }
}

// MARK: - ArtifactParser
// Detects <artifact> ... </artifact> blocks in streamed AI output.
// Supports both complete and incremental (streaming) parsing.

enum ArtifactParser {

    // Extract the last (or only) artifact from a complete AI response string.
    static func extract(from text: String) -> Artifact? {
        // Pattern: <artifact type="html" title="My Page"> ... </artifact>
        let pattern = #"<artifact(?:\s+type=\"([^\"]*?)\")?(?:\s+title=\"([^\"]*?)\")?\s*>([\s\S]*?)</artifact>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }

        let typeName  = match.group(1, in: text) ?? "html"
        let title     = match.group(2, in: text) ?? ""
        let content   = (match.group(3, in: text) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let artType = Artifact.ArtifactType.detect(from: typeName)
        return Artifact(type: artType, content: content, title: title)
    }

    // Strip <artifact> tags from the display-facing text (so chat doesn't show raw tags)
    static func stripArtifactTags(from text: String) -> String {
        let pattern = #"<artifact[^>]*>[\s\S]*?</artifact>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators)
        else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Check if a streaming buffer has a complete artifact block
    static func hasCompleteArtifact(in buffer: String) -> Bool {
        buffer.contains("<artifact") && buffer.contains("</artifact>")
    }

    // Check if streaming has started an artifact (but not closed it yet)
    static func isStreamingArtifact(in buffer: String) -> Bool {
        buffer.contains("<artifact") && !buffer.contains("</artifact>")
    }
}

private extension NSTextCheckingResult {
    func group(_ index: Int, in text: String) -> String? {
        guard index < numberOfRanges,
              let r = Range(range(at: index), in: text),
              !r.isEmpty else { return nil }
        return String(text[r])
    }
}
