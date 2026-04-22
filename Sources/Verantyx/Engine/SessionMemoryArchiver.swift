import Foundation

// MARK: - SessionMemoryArchiver
//
// セッションが削除されても記憶は消えない。
// 【変更】セッション削除時だけでなく、10メッセージ毎に自動蒸留する。
// 新規セッション開始時に過去セッションの記憶を L1〜L3 レイヤーで注入する。
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

    // MARK: - Progressive archiving (every N messages, overwrites previous)

    /// Called by SessionStore every time messages.count is a multiple of 10.
    /// Overwrites the existing .jcross for this session (no accumulation).
    @discardableResult
    func archiveProgressively(session: ChatSession) -> String? {
        let messages = session.messages
        // Only archive when there's meaningful content (≥4 messages)
        guard messages.filter({ $0.role != .system }).count >= 4 else { return nil }

        let content = buildJCrossContent(session: session, label: "Progressive")
        let fileName = progressiveFileName(for: session)

        // Write to local archive (overwrite)
        let localPath = archiveDir.appendingPathComponent(fileName)
        try? content.write(to: localPath, atomically: true, encoding: .utf8)

        // Mirror to MCP mid/ zone
        let mcpPath = mcpMidDir.appendingPathComponent(fileName)
        try? content.write(to: mcpPath, atomically: true, encoding: .utf8)

        return fileName
    }

    // MARK: - Archive a session before deletion

    /// Call this BEFORE deleting a session to immortalize its memory.
    @discardableResult
    func archiveBeforeDelete(session: ChatSession) -> String? {
        let messages = session.messages
        guard !messages.isEmpty else { return nil }

        let content = buildJCrossContent(session: session, label: "Deleted")
        let shortId = String(session.id.uuidString.prefix(8))
        let ts = Int(Date().timeIntervalSince1970)
        let fileName = "SESSION_\(shortId)_\(ts).jcross"

        let localPath = archiveDir.appendingPathComponent(fileName)
        try? content.write(to: localPath, atomically: true, encoding: .utf8)

        let mcpPath = mcpMidDir.appendingPathComponent(fileName)
        try? content.write(to: mcpPath, atomically: true, encoding: .utf8)

        // Also store in CortexEngine
        let l1 = buildL1(session: session)
        let sessionDate = ISO8601DateFormatter().string(from: session.createdAt)
        let shortId2 = String(session.id.uuidString.prefix(8))
        Task { @MainActor in
            CortexEngine.shared?.remember(
                key: "archived_session_\(shortId2)",
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

    // MARK: - Cross-session memory injection (NEW)

    /// Build a memory injection string from recent past sessions.
    /// Called when a new session starts, filtered by the user's activeLayer setting.
    ///
    /// - Parameters:
    ///   - topK: How many past sessions to include (default: 5)
    ///   - layer: Which JCross layer to extract (L1 = minimal, L3 = full verbatim)
    ///   - excludingSessionId: Skip the current session's own archive
    func buildCrossSessionInjection(
        topK: Int = 5,
        layer: JCrossLayer = .l2,
        excludingSessionId: UUID? = nil
    ) -> String {
        let files = listArchived()
            .filter { url in
                // Exclude the current session's progressive archive if needed
                if let excId = excludingSessionId {
                    let prefix = "PROG_\(String(excId.uuidString.prefix(8)))"
                    return !url.lastPathComponent.hasPrefix(prefix)
                }
                return true
            }
            .prefix(topK)

        guard !files.isEmpty else { return "" }

        var parts: [String] = []
        for url in files {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let sessionName = extractMetaField(from: raw, key: "Session") ?? url.deletingPathExtension().lastPathComponent
            let date        = extractMetaField(from: raw, key: "Created") ?? ""

            // Extract the section matching the requested layer
            let extracted: String
            switch layer {
            case .l1:
                extracted = extractSection(from: raw, tag: "L1_SUMMARY") ?? ""
            case .l1_5:
                // L1.5 = L1 summary + OP.ENTITY/OP.STATE lines from L2
                let l1Part = extractSection(from: raw, tag: "L1_SUMMARY") ?? ""
                let l2Part = extractSection(from: raw, tag: "L2_FACTS") ?? ""
                let entityLines = l2Part.components(separatedBy: "\n")
                    .filter { $0.contains("OP.ENTITY") || $0.contains("OP.STATE") }
                    .joined(separator: "\n")
                extracted = [l1Part, entityLines].filter { !$0.isEmpty }.joined(separator: "\n")
            case .l2:
                extracted = extractSection(from: raw, tag: "L2_FACTS") ?? ""
            case .l3:
                extracted = extractSection(from: raw, tag: "L3_VERBATIM") ?? ""
            }

            guard !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

            let header = "【\(sessionName)】\(date.isEmpty ? "" : " (\(date))")"
            // Cap each section to prevent context overflow
            let cap: Int
            switch layer {
            case .l1:   cap = 120
            case .l1_5: cap = 300
            case .l2:   cap = 600
            case .l3:   cap = 2000
            }
            parts.append("\(header)\n\(String(extracted.prefix(cap)))")
        }

        guard !parts.isEmpty else { return "" }

        return """

        [CROSS-SESSION MEMORY — Layer: \(layer.rawValue) — \(layer.description)]
        以下は過去のセッションから蒸留された記憶です。参考にしてください。

        \(parts.joined(separator: "\n---\n"))
        [/CROSS-SESSION MEMORY]
        """
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

    /// Build a memory prompt injection from recent archived sessions (last N) — L2 fixed (legacy).
    func buildArchiveInjection(topK: Int = 5, relevantTo query: String = "") -> String {
        buildCrossSessionInjection(topK: topK, layer: .l2)
    }

    // MARK: - Helpers

    private func progressiveFileName(for session: ChatSession) -> String {
        let shortId = String(session.id.uuidString.prefix(8))
        return "PROG_\(shortId).jcross"   // fixed name — always overwrites
    }

    private func buildJCrossContent(session: ChatSession, label: String) -> String {
        let l1 = buildL1(session: session)
        let l2 = buildL2(from: session.messages)
        let l3 = buildL3(from: session.messages)

        let timestamp   = ISO8601DateFormatter().string(from: Date())
        let sessionDate = ISO8601DateFormatter().string(from: session.createdAt)

        return """
        ;;; JCross Memory Node — \(label)
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
    }

    // MARK: - Build layers

    private func buildL1(session: ChatSession) -> String {
        let firstUser = session.messages.first(where: { $0.role == .user })?.content ?? ""
        let preview = String(firstUser.prefix(120)).replacingOccurrences(of: "\n", with: " ")
        return "[会話:\(session.title)] [日付:\(formatDate(session.createdAt))] \(preview)"
    }

    private func buildL2(from messages: [ChatMessage]) -> String {
        var facts: [String] = []

        // Auto-detect file modifications
        let filePattern  = #"\[WRITE:\s*([^\]]+)\]"#
        let patchPattern = #"\[PATCH_FILE:\s*([^\]]+)\]"#
        let applyPattern = #"\[APPLY_PATCH:\s*([^\]]+)\]"#

        for msg in messages where msg.role == .assistant {
            for pattern in [filePattern, patchPattern, applyPattern] {
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

        // User intent facts (first 5 user messages)
        let userMsgs = messages.filter { $0.role == .user }.prefix(5)
        for (i, msg) in userMsgs.enumerated() {
            let preview = String(msg.content.prefix(150)).replacingOccurrences(of: "\n", with: " ")
            facts.append("OP.FACT(\"user_intent_\(i)\", \"\(preview)\")")
        }

        // Entity: workspace path if detectable
        for msg in messages where msg.role == .system {
            if msg.content.contains("Workspace:") {
                let trimmed = msg.content.replacingOccurrences(of: "📂 Workspace: ", with: "")
                facts.append("OP.ENTITY(\"workspace\", \"\(trimmed.prefix(80))\")")
                break
            }
        }

        facts.append("OP.FACT(\"message_count\", \"\(messages.count)\")")
        facts.append("OP.STATE(\"layer\", \"L2\")")

        return facts.joined(separator: "\n")
    }

    private func buildL3(from messages: [ChatMessage]) -> String {
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

    private func extractMetaField(from raw: String, key: String) -> String? {
        let prefix = ";;; \(key): "
        guard let line = raw.components(separatedBy: "\n").first(where: { $0.hasPrefix(prefix) })
        else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
