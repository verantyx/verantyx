import Foundation

// MARK: - SessionMemoryArchiver
//
// セッションが削除されても記憶は消えない。
// セッション削除時にこのアーカイバーが会話の重要な情報を
// JCross 形式 (.jcross) としてローカルディスクに永続化する。
//
// 保存先: ~/Library/Application Support/Verantyx/jcross_archive/
// 形式: JCross Tri-Layer (L1 summary / L2 facts / L3 verbatim)
//
// CortexEngine とは独立して動作するため、CortexEngine の GC でも消えない。

final class SessionMemoryArchiver {

    static let shared = SessionMemoryArchiver()

    // Archive directory on local disk (survives session deletion)
    private let archiveDir: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let dir = appSupport.appendingPathComponent("Verantyx/jcross_archive", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // Also write to ~/.openclaw/memory/mid/ so MCP server can read it
    private let mcpMidDir: URL = {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".openclaw/memory/mid", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Archive a session before deletion

    /// Call this BEFORE deleting a session to immortalize its memory.
    /// Returns the filename of the saved .jcross node.
    @discardableResult
    func archiveBeforeDelete(session: ChatSession) -> String? {
        let messages = session.messages
        guard !messages.isEmpty else { return nil }

        // ── L1: One-line summary tag line ─────────────────────────────
        let l1 = buildL1(session: session)

        // ── L2: Structured fact extraction ────────────────────────────
        let l2 = buildL2(from: messages)

        // ── L3: Verbatim transcript (capped at 4000 chars) ────────────
        let l3 = buildL3(from: messages)

        // JCross file content
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let sessionDate = ISO8601DateFormatter().string(from: session.createdAt)

        let content = """
        ;;; JCross Memory Node — Auto-archived on session delete
        ;;; Session: \(session.title)
        ;;; Created: \(sessionDate)
        ;;; Archived: \(timestamp)
        ;;; ID: \(session.id.uuidString)

        [L1_SUMMARY]
        \(l1)
        [/L1_SUMMARY]

        [L2_FACTS]
        \(l2)
        [/L2_FACTS]

        [L3_VERBATIM]
        \(l3)
        [/L3_VERBATIM]
        """

        // File name: SESSION_<shortID>_<timestamp>.jcross
        let shortId = String(session.id.uuidString.prefix(8))
        let ts = Int(Date().timeIntervalSince1970)
        let fileName = "SESSION_\(shortId)_\(ts).jcross"

        // Write to local archive
        let localPath = archiveDir.appendingPathComponent(fileName)
        try? content.write(to: localPath, atomically: true, encoding: .utf8)

        // Mirror to MCP mid/ zone so verantyx-compiler can also read it
        let mcpPath = mcpMidDir.appendingPathComponent(fileName)
        try? content.write(to: mcpPath, atomically: true, encoding: .utf8)

        // Also store the session title + summary in CortexEngine (survives as a MemoryNode)
        Task { @MainActor in
            CortexEngine.shared?.remember(
                key: "archived_session_\(shortId)",
                value: "[\(sessionDate)] \(session.title): \(l1.prefix(200))",
                importance: 0.85,
                zone: .mid
            )
        }

        return fileName
    }

    // MARK: - Archive all sessions (bulk)

    func archiveAll(sessions: [ChatSession]) {
        for session in sessions {
            archiveBeforeDelete(session: session)
        }
    }

    // MARK: - Retrieve archived nodes

    /// List all archived .jcross filenames sorted by date (newest first)
    func listArchived() -> [URL] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: archiveDir,
                                                   includingPropertiesForKeys: [.creationDateKey])) ?? []
        return files
            .filter { $0.pathExtension == "jcross" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return da > db
            }
    }

    /// Build a memory prompt injection from recent archived sessions (last N)
    func buildArchiveInjection(topK: Int = 5, relevantTo query: String = "") -> String {
        let files = listArchived().prefix(topK)
        guard !files.isEmpty else { return "" }

        var parts: [String] = []
        for url in files {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // Extract L2 facts section
            if let l2 = extractSection(from: raw, tag: "L2_FACTS") {
                let name = url.deletingPathExtension().lastPathComponent
                parts.append("[\(name)]\n\(l2.prefix(400))")
            }
        }

        guard !parts.isEmpty else { return "" }
        return """

        [ARCHIVED SESSION MEMORY — sessions deleted but facts preserved]
        \(parts.joined(separator: "\n---\n"))
        [/ARCHIVED SESSION MEMORY]
        """
    }

    // MARK: - Build layers

    private func buildL1(session: ChatSession) -> String {
        // Use session title + first user message as the L1 tag
        let firstUser = session.messages.first(where: { $0.role == .user })?.content ?? ""
        let preview = String(firstUser.prefix(120)).replacingOccurrences(of: "\n", with: " ")
        return "[会話:\(session.title)] [日付:\(formatDate(session.createdAt))] \(preview)"
    }

    private func buildL2(from messages: [ChatMessage]) -> String {
        // Extract OP.FACT entries from the conversation
        var facts: [String] = []

        // Auto-detect file creations
        let filePattern = #"\[WRITE:\s*([^\]]+)\]"#
        let patchPattern = #"\[PATCH_FILE:\s*([^\]]+)\]"#

        for msg in messages where msg.role == .assistant {
            for pattern in [filePattern, patchPattern] {
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let matches = regex.matches(in: msg.content,
                                                range: NSRange(msg.content.startIndex..., in: msg.content))
                    for m in matches {
                        if let r = Range(m.range(at: 1), in: msg.content) {
                            facts.append("OP.FACT(\"modified_file\", \"\(String(msg.content[r]).trimmingCharacters(in: .whitespaces))\")")
                        }
                    }
                }
            }
        }

        // Include first N user messages as intent facts
        let userMsgs = messages.filter { $0.role == .user }.prefix(5)
        for (i, msg) in userMsgs.enumerated() {
            let preview = String(msg.content.prefix(150)).replacingOccurrences(of: "\n", with: " ")
            facts.append("OP.FACT(\"user_intent_\(i)\", \"\(preview)\")")
        }

        // Message count
        facts.append("OP.FACT(\"message_count\", \"\(messages.count)\")")

        return facts.joined(separator: "\n")
    }

    private func buildL3(from messages: [ChatMessage]) -> String {
        // Verbatim transcript, capped at 4000 chars
        let lines = messages.compactMap { msg -> String? in
            switch msg.role {
            case .user:      return "User: \(msg.content)"
            case .assistant: return "Agent: \(String(msg.content.prefix(500)))"
            case .system:    return nil
            }
        }
        return String(lines.joined(separator: "\n\n").prefix(4000))
    }

    private func extractSection(from raw: String, tag: String) -> String? {
        let open  = "[\(tag)]"
        let close = "[/\(tag)]"
        guard let start = raw.range(of: open),
              let end   = raw.range(of: close),
              start.upperBound < end.lowerBound
        else { return nil }
        return String(raw[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
