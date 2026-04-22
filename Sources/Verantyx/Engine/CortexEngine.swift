import Foundation
import SwiftUI

// MARK: - MemoryNode

struct MemoryNode: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    var key: String
    var value: String
    var importance: Float
    var accessCount: Int
    var zone: Zone
    var kanjiTags: [String]

    // ── Zone hierarchy (MCP parity) ────────────────────────────────────────
    // front : recent + high importance  (cap: 100)
    // near  : recent sessions           (cap: 1000)
    // mid   : medium-term memory        (cap: 5000)
    // deep  : long-term archive         (uncapped)
    enum Zone: String, Codable, CaseIterable {
        case front, near, mid, deep

        // Physical directory name under ~/.openclaw/memory/
        var directoryName: String { rawValue }

        // LRU cap (0 = unlimited)
        var cap: Int {
            switch self {
            case .front: return 100
            case .near:  return 1000
            case .mid:   return 5000
            case .deep:  return 0
            }
        }

        // Zone that evicted nodes migrate to
        var nextZone: Zone? {
            switch self {
            case .front: return .near
            case .near:  return .mid
            case .mid:   return .deep
            case .deep:  return nil
            }
        }
    }

    init(id: UUID = UUID(), key: String, value: String,
         importance: Float = 0.5, zone: Zone = .near, kanjiTags: [String] = []) {
        self.id          = id
        self.timestamp   = Date()
        self.key         = key
        self.value       = value
        self.importance  = importance
        self.accessCount = 0
        self.zone        = zone
        self.kanjiTags   = kanjiTags
    }
}

// MARK: - CortexEngine

@MainActor
final class CortexEngine: ObservableObject {

    static weak var shared: CortexEngine?

    // MARK: - State
    @Published var nodes: [MemoryNode] = []
    @Published var compressedCount: Int = 0
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "cortex_enabled") }
    }
    @Published var contextThreshold: Int {
        didSet { UserDefaults.standard.set(contextThreshold, forKey: "cortex_threshold") }
    }

    var maxNodes: Int = 100  // kept for legacy compatibility; zones have own caps

    // MARK: - Zone directories (MCP parity: ~/.openclaw/memory/<zone>/)

    private let mcpMemoryRoot: URL = {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".openclaw/memory", isDirectory: true)
        for zone in MemoryNode.Zone.allCases {
            let zoneDir = dir.appendingPathComponent(zone.rawValue, isDirectory: true)
            try? FileManager.default.createDirectory(at: zoneDir, withIntermediateDirectories: true)
        }
        // meta/
        try? FileManager.default.createDirectory(
            at: dir.appendingPathComponent("meta", isDirectory: true),
            withIntermediateDirectories: true
        )
        return dir
    }()

    // Legacy single-file fallback (for migration)
    private let legacyStorageURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Verantyx/cortex")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("memory.json")
    }()

    // MARK: - Init

    init() {
        self.isEnabled       = UserDefaults.standard.object(forKey: "cortex_enabled") as? Bool ?? true
        self.contextThreshold = UserDefaults.standard.object(forKey: "cortex_threshold") as? Int ?? 3000
        loadFromZones()
        CortexEngine.shared = self
    }

    // MARK: - Public API

    /// Store a key-value fact. Zone is auto-classified by importance if not specified.
    func remember(key: String, value: String, importance: Float = 0.5, zone: MemoryNode.Zone? = nil) {
        guard isEnabled else { return }
        let resolvedZone = zone ?? classifyNode(importance: importance)

        if let idx = nodes.firstIndex(where: { $0.key == key }) {
            nodes[idx].value       = value
            nodes[idx].importance  = max(nodes[idx].importance, importance)
            nodes[idx].accessCount += 1
            // Promote to better zone if importance increased
            let newZone = classifyNode(importance: nodes[idx].importance)
            if newZone == .front && nodes[idx].zone != .front {
                migrateNode(&nodes[idx], to: .front)
            }
            writeNode(nodes[idx])
        } else {
            var node = MemoryNode(key: key, value: value, importance: importance,
                                  zone: resolvedZone, kanjiTags: inferKanjiTags(key: key, value: value))
            nodes.append(node)
            writeNode(node)
        }

        runLRUGC()
    }

    /// Get relevant memories for a query (keyword + importance scoring).
    func recall(for query: String, topK: Int = 8) -> [MemoryNode] {
        guard isEnabled, !nodes.isEmpty else { return [] }
        let words = query.lowercased().components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count > 2 }

        let scored = nodes.map { node -> (MemoryNode, Float) in
            let text = (node.key + " " + node.value + " " + node.kanjiTags.joined()).lowercased()
            let matchCount = words.filter { text.contains($0) }.count
            // Boost front/near zone nodes
            let zoneBoost: Float = node.zone == .front ? 0.3 : node.zone == .near ? 0.15 : 0.0
            let score = Float(matchCount) * node.importance + Float(node.accessCount) * 0.1 + zoneBoost
            return (node, score)
        }

        var result = scored.sorted { $0.1 > $1.1 }.prefix(topK).map { $0.0 }
        // Increment accessCount for recalled nodes
        for i in 0..<result.count {
            if let idx = nodes.firstIndex(where: { $0.id == result[i].id }) {
                nodes[idx].accessCount += 1
            }
        }
        return result
    }

    /// Build the memory injection string for the system prompt.
    func buildMemoryPrompt(for query: String) -> String {
        guard isEnabled else { return "" }
        let relevant = recall(for: query, topK: 10)
        guard !relevant.isEmpty else { return "" }

        let facts = relevant.map { node in
            let zoneIcon = node.zone == .front ? "⚡" : node.zone == .near ? "🔵" : "💾"
            return "  \(zoneIcon) \(node.key): \(node.value)"
        }.joined(separator: "\n")

        return """

        [CORTEX MEMORY — remembered context to prevent forgetting]
        \(facts)
        [/CORTEX MEMORY]
        """
    }

    /// Compress messages when context gets too long.
    func compressIfNeeded(messages: [ChatMessage]) -> [ChatMessage] {
        guard isEnabled else { return messages }
        let totalChars = messages.reduce(0) { $0 + $1.content.count }
        guard totalChars > contextThreshold * 4 else { return messages }

        let keepCount = 6
        guard messages.count > keepCount + 2 else { return messages }

        let toCompress = Array(messages.dropLast(keepCount))
        let toKeep     = Array(messages.suffix(keepCount))
        let summary    = buildCompressionSummary(from: toCompress)

        remember(key: "session_summary_\(compressedCount)", value: summary,
                 importance: 0.9, zone: .near)
        compressedCount += 1

        let compressionNote = ChatMessage(
            role: .system,
            content: "🧠 [Cortex] Compressed \(toCompress.count) earlier messages into memory. Key context preserved."
        )
        return [compressionNote] + toKeep
    }

    /// Auto-extract facts from AI response.
    func extractAndStore(from aiResponse: String, userInstruction: String) {
        guard isEnabled else { return }

        let filePatterns = [
            (#"\[WRITE:\s*([^\]]+)\]"#, "created_files", Float(0.8), MemoryNode.Zone.near),
            (#"\[PATCH_FILE:\s*([^\]]+)\]"#, "patched_files", Float(0.85), MemoryNode.Zone.near),
            (#"\[APPLY_PATCH:\s*([^\]]+)\]"#, "applied_patches", Float(0.85), MemoryNode.Zone.near),
            (#"\[WORKSPACE:\s*([^\]]+)\]"#, "current_workspace", Float(0.95), MemoryNode.Zone.front),
        ]

        for (pattern, key, imp, zone) in filePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let matches = regex.matches(in: aiResponse, range: NSRange(aiResponse.startIndex..., in: aiResponse))
                let values = matches.compactMap { m -> String? in
                    Range(m.range(at: 1), in: aiResponse).map {
                        String(aiResponse[$0]).trimmingCharacters(in: .whitespaces)
                    }
                }
                if !values.isEmpty { remember(key: key, value: values.joined(separator: ", "), importance: imp, zone: zone) }
            }
        }

        // Project language detection
        let lower = userInstruction.lowercased()
        let langMap: [(String, String)] = [
            ("swift", "Swift"), ("python", "Python"), ("rust", "Rust"),
            ("typescript", "TypeScript"), ("react", "React"), ("kotlin", "Kotlin"),
        ]
        for (keyword, lang) in langMap {
            if lower.contains(keyword) {
                remember(key: "project_language", value: lang, importance: 0.7, zone: .near)
                break
            }
        }

        if userInstruction.count > 10 {
            remember(key: "last_instruction", value: String(userInstruction.prefix(200)),
                     importance: 0.6, zone: .near)
        }
    }

    func clearAll() {
        // Remove all .jcross files from all zones
        for zone in MemoryNode.Zone.allCases {
            let dir = mcpMemoryRoot.appendingPathComponent(zone.rawValue)
            let files = (try? FileManager.default.contentsOfDirectory(at: dir,
                                                                       includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "jcross" && !file.lastPathComponent.hasPrefix("JCROSS_TOMB") {
                try? FileManager.default.removeItem(at: file)
            }
        }
        nodes = []
        compressedCount = 0
    }

    // MARK: - Zone classification (classifyNode — MCP parity)

    private func classifyNode(importance: Float) -> MemoryNode.Zone {
        switch importance {
        case 0.9...: return .front
        case 0.7..<0.9: return .near
        case 0.4..<0.7: return .mid
        default:        return .deep
        }
    }

    // MARK: - LRU GC with Tombstone migration (MCP parity)

    private func runLRUGC() {
        for zone in [MemoryNode.Zone.front, .near, .mid] {
            guard let cap = Optional(zone.cap), cap > 0 else { continue }
            let zoneNodes = nodes.filter { $0.zone == zone }
            guard zoneNodes.count > cap else { continue }

            // Sort by LRU score ascending (evict lowest first)
            let sorted = zoneNodes.sorted {
                ($0.importance * Float($0.accessCount + 1)) < ($1.importance * Float($1.accessCount + 1))
            }
            let toEvict = Array(sorted.prefix(zoneNodes.count - cap))

            for var node in toEvict {
                guard let next = zone.nextZone else { continue }
                // Write Tombstone in current zone
                writeTombstone(for: node, evictedTo: next)
                // Move node to next zone
                deleteNodeFile(node, from: zone)
                migrateNode(&node, to: next)
                writeNode(node)
            }
        }
    }

    // MARK: - Node migration

    private func migrateNode(_ node: inout MemoryNode, to newZone: MemoryNode.Zone) {
        if let idx = nodes.firstIndex(where: { $0.id == node.id }) {
            nodes[idx].zone = newZone
        }
        node.zone = newZone
    }

    // MARK: - Disk I/O (.jcross format, MCP parity)

    private func nodeFileName(_ node: MemoryNode) -> String {
        let shortId = String(node.id.uuidString.prefix(8).lowercased())
        return "\(shortId).jcross"
    }

    private func writeNode(_ node: MemoryNode) {
        let dir      = mcpMemoryRoot.appendingPathComponent(node.zone.rawValue)
        let fileName = nodeFileName(node)
        let content  = JCrossFormatter.buildNode(
            id: String(Int(node.timestamp.timeIntervalSince1970 * 1000)),
            key: node.key,
            value: node.value,
            importance: node.importance,
            kanjiTags: node.kanjiTags.isEmpty ? inferKanjiTags(key: node.key, value: node.value) : node.kanjiTags,
            rawText: "\(node.key): \(node.value)"
        )
        try? content.write(to: dir.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
    }

    private func deleteNodeFile(_ node: MemoryNode, from zone: MemoryNode.Zone) {
        let dir      = mcpMemoryRoot.appendingPathComponent(zone.rawValue)
        let fileName = nodeFileName(node)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(fileName))
    }

    private func writeTombstone(for node: MemoryNode, evictedTo next: MemoryNode.Zone) {
        let currentDir = mcpMemoryRoot.appendingPathComponent(node.zone.rawValue)
        let fileName   = nodeFileName(node)
        let tomb = JCrossFormatter.buildTombstone(
            fileName: fileName,
            kanjiTags: node.kanjiTags,
            evictedTo: "\(next.rawValue)/\(fileName)"
        )
        let tombFile = "JCROSS_TOMB_\(fileName)"
        try? tomb.write(to: currentDir.appendingPathComponent(tombFile), atomically: true, encoding: .utf8)
    }

    // MARK: - Load from zones (startup)

    private func loadFromZones() {
        var loaded: [MemoryNode] = []

        for zone in MemoryNode.Zone.allCases {
            let dir   = mcpMemoryRoot.appendingPathComponent(zone.rawValue)
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.creationDateKey]
            )) ?? []

            for file in files where file.pathExtension == "jcross"
                                 && !file.lastPathComponent.hasPrefix("JCROSS_TOMB") {
                guard let raw = try? String(contentsOf: file, encoding: .utf8),
                      let parsed = JCrossFormatter.parseNode(from: raw)
                else { continue }

                let node = MemoryNode(
                    key: parsed.key,
                    value: parsed.value,
                    importance: 0.6,
                    zone: zone,
                    kanjiTags: parsed.kanjiTags
                )
                loaded.append(node)
            }
        }

        // If no zone files, migrate from legacy JSON
        if loaded.isEmpty {
            migrateLegacyJSON()
        } else {
            nodes = loaded
        }
    }

    /// One-time migration from old memory.json → zone directories
    private func migrateLegacyJSON() {
        guard let data    = try? Data(contentsOf: legacyStorageURL),
              let decoded = try? JSONDecoder().decode([MemoryNode].self, from: data),
              !decoded.isEmpty
        else { return }

        nodes = decoded
        // Write each node to its classified zone
        for node in decoded {
            var n = node
            n = MemoryNode(id: node.id, key: node.key, value: node.value,
                           importance: node.importance,
                           zone: classifyNode(importance: node.importance),
                           kanjiTags: node.kanjiTags)
            writeNode(n)
        }
        // Rename legacy file so migration doesn't repeat
        let backup = legacyStorageURL.deletingLastPathComponent()
            .appendingPathComponent("memory_migrated.json")
        try? FileManager.default.moveItem(at: legacyStorageURL, to: backup)
    }

    // MARK: - Kanji tag inference

    private func inferKanjiTags(key: String, value: String) -> [String] {
        let text = (key + " " + value).lowercased()
        var tags: [String] = []
        let map: [(String, String)] = [
            ("swift", "技"), ("code", "技"), ("build", "技"), ("file", "技"),
            ("session", "会"), ("memory", "憶"), ("workspace", "場"),
            ("install", "実"), ("model", "模"), ("ui", "画"), ("view", "視"),
            ("error", "障"), ("fix", "修"), ("patch", "修"),
        ]
        for (keyword, kanji) in map {
            if text.contains(keyword) && !tags.contains(kanji) { tags.append(kanji) }
        }
        if tags.isEmpty { tags = ["技", "標"] }
        return Array(tags.prefix(4))
    }

    // MARK: - Compression summary

    private func buildCompressionSummary(from messages: [ChatMessage]) -> String {
        messages.compactMap { msg -> String? in
            switch msg.role {
            case .user:      return "U: \(msg.content.prefix(100))"
            case .assistant: return "A: \(msg.content.prefix(200))"
            case .system:    return nil
            }
        }.joined(separator: " | ")
    }
}
import Foundation

// MARK: - JCrossFormatter
// MCPのverantyx-compilerと互換性のある .jcross ノード形式を生成・解析する。
// 確認済み仕様: deep/ノードの実ファイル構造から逆算。

enum JCrossFormatter {

    // MARK: - Build a .jcross node (MCP compatible)

    static func buildNode(
        id: String,
        key: String,
        value: String,
        importance: Float,
        kanjiTags: [String],
        rawText: String? = nil
    ) -> String {
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let nodeId = "JCROSS_NODE_\(id.isEmpty ? "\(ts)" : id)"
        let l1Tags = buildL1Tags(kanjiTags: kanjiTags, importance: importance)
        let l15Index = buildL15Index(kanjiTags: kanjiTags, summary: String(value.prefix(64)))
        let opFact = "OP.FACT(\"\(escapeQuotes(key))\", \"\(escapeQuotes(String(value.prefix(200))))\")"
        let verbatim = rawText ?? "\(key): \(value)"

        return """
        ■ \(nodeId)
        【空間座相】
        \(l1Tags)

        【L1.5索引】
        \(l15Index)

        【位相対応表】
        [標] := "\(String(value.prefix(80)).replacingOccurrences(of: "\n", with: " "))"

        【操作対応表】
        \(opFact)

        【原文】
        \(verbatim)
        """
    }

    // MARK: - Build a Tombstone (zone eviction marker)

    static func buildTombstone(
        fileName: String,
        kanjiTags: [String],
        evictedTo: String
    ) -> String {
        let l1Tags = buildL1Tags(kanjiTags: kanjiTags, importance: 0.5)
        let now = ISO8601DateFormatter().string(from: Date())
        return """
        ■ JCROSS_TOMB_\(fileName)
        【空間座相】
        \(l1Tags)

        【EVICTED_TO】
        \(evictedTo)

        【EVICTED_AT】
        \(now)
        """
    }

    // MARK: - Parse a .jcross node back to key/value

    static func parseNode(from raw: String) -> (key: String, value: String, kanjiTags: [String])? {
        // Extract OP.FACT
        if let factRange = raw.range(of: #"OP\.FACT\("([^"]+)",\s*"([^"]*)"\)"#,
                                      options: .regularExpression) {
            let factStr = String(raw[factRange])
            let pattern = #"OP\.FACT\("([^"]+)",\s*"([^"]*)"\)"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: factStr, range: NSRange(factStr.startIndex..., in: factStr)) {
                let key   = Range(match.range(at: 1), in: factStr).map { String(factStr[$0]) } ?? ""
                let value = Range(match.range(at: 2), in: factStr).map { String(factStr[$0]) } ?? ""
                let tags  = extractKanjiTags(from: raw)
                return (key, value, tags)
            }
        }

        // Fallback: use 位相対応表
        if let line = raw.components(separatedBy: "\n").first(where: { $0.hasPrefix("[標]") }) {
            let value = line
                .replacingOccurrences(of: #"\[標\] := ""#, with: "", options: .regularExpression)
                .replacingOccurrences(of: "\"", with: "")
                .trimmingCharacters(in: .whitespaces)
            return ("parsed_fact", value, extractKanjiTags(from: raw))
        }
        return nil
    }

    // MARK: - Extract verbatim (L3)

    static func extractVerbatim(from raw: String) -> String? {
        guard let range = raw.range(of: "【原文】") else { return nil }
        return String(raw[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private static func buildL1Tags(kanjiTags: [String], importance: Float) -> String {
        let defaults: [(String, Float)] = [("技", 0.8), ("標", 0.7), ("認", 0.6)]
        var pairs: [(String, Float)] = kanjiTags.enumerated().map { i, k in
            (k, max(0.1, importance - Float(i) * 0.1))
        }
        if pairs.isEmpty { pairs = defaults }
        return pairs.map { "[\($0.0): \(String(format: "%.1f", $0.1))]" }.joined(separator: " ")
    }

    private static func buildL15Index(kanjiTags: [String], summary: String) -> String {
        let combined = kanjiTags.prefix(3).joined()
        let safe = summary.replacingOccurrences(of: "\n", with: " ")
        return "[\(combined.isEmpty ? "技標認" : combined)] | \"\(safe)\""
    }

    private static func extractKanjiTags(from raw: String) -> [String] {
        guard let line = raw.components(separatedBy: "\n")
            .first(where: { $0.contains("[") && $0.contains(":") && !$0.contains("】") })
        else { return [] }
        let pattern = #"\[([^\]:]+):\s*[\d.]+\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: line, range: NSRange(line.startIndex..., in: line))
        return matches.compactMap { m -> String? in
            Range(m.range(at: 1), in: line).map { String(line[$0]).trimmingCharacters(in: .whitespaces) }
        }
    }

    private static func escapeQuotes(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
