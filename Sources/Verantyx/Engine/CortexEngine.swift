import Foundation
import SwiftUI

// MARK: - CortexMemory
// Lightweight JCross-inspired in-process memory engine.
// Prevents "AI Alzheimer's" in local models with limited context windows.
//
// Mechanism:
//   1. Every AI exchange → extract facts → store as MemoryNode
//   2. Before AI call → inject relevant memories into system prompt
//   3. When context tokens > threshold → compress old messages into a node
//   4. MemoryNodes survive across conversations (persisted to disk)

// MARK: - MemoryNode

struct MemoryNode: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    var key: String          // short label (e.g., "project_name")
    var value: String        // the remembered fact
    var importance: Float    // 0.0 – 1.0
    var accessCount: Int     // LRU tracking
    var zone: Zone
    var kanjiTags: [String]  // L1 spatial index tags

    enum Zone: String, Codable { case front, near, mid, deep }

    init(id: UUID = UUID(), key: String, value: String,
                importance: Float = 0.5, zone: Zone = .near, kanjiTags: [String] = []) {
        self.id = id
        self.timestamp = Date()
        self.key = key
        self.value = value
        self.importance = importance
        self.accessCount = 0
        self.zone = zone
        self.kanjiTags = kanjiTags
    }
}

// MARK: - CortexEngine

@MainActor
final class CortexEngine: ObservableObject {

    // MARK: - State
    @Published var nodes: [MemoryNode] = []
    @Published var compressedCount: Int = 0
    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "cortex_enabled") }
    }
    @Published var contextThreshold: Int {
        didSet { UserDefaults.standard.set(contextThreshold, forKey: "cortex_threshold") }
    }

    // Configuration
    var maxNodes: Int = 100

    // MARK: - Init / Persistence

    private let storageURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AntigravityIDE/cortex")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("memory.json")
    }()

    init() {
        self.isEnabled = UserDefaults.standard.object(forKey: "cortex_enabled") as? Bool ?? true
        self.contextThreshold = UserDefaults.standard.object(forKey: "cortex_threshold") as? Int ?? 3000
        loadFromDisk()
    }

    // MARK: - Public API

    /// Store a key-value fact.
    func remember(key: String, value: String, importance: Float = 0.5, zone: MemoryNode.Zone = .near) {
        guard isEnabled else { return }
        // Update existing or insert
        if let idx = nodes.firstIndex(where: { $0.key == key }) {
            nodes[idx].value = value
            nodes[idx].accessCount += 1
        } else {
            let node = MemoryNode(key: key, value: value, importance: importance, zone: zone)
            nodes.append(node)
        }
        runGC()
        saveToDisk()
    }

    /// Get relevant memories for a query (simple keyword match).
    func recall(for query: String, topK: Int = 8) -> [MemoryNode] {
        guard isEnabled, !nodes.isEmpty else { return [] }
        let words = query.lowercased().components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count > 2 }
        let scored = nodes.map { node -> (MemoryNode, Float) in
            let text = (node.key + " " + node.value).lowercased()
            let matchCount = words.filter { text.contains($0) }.count
            let score = Float(matchCount) * node.importance + Float(node.accessCount) * 0.1
            return (node, score)
        }
        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(topK)
            .map { var n = $0.0; n.accessCount += 1; return n }
    }

    /// Build the memory injection string for the system prompt.
    func buildMemoryPrompt(for query: String) -> String {
        guard isEnabled else { return "" }
        let relevant = recall(for: query, topK: 10)
        guard !relevant.isEmpty else { return "" }

        let facts = relevant.map { "  • \($0.key): \($0.value)" }.joined(separator: "\n")
        return """

        [CORTEX MEMORY — remembered context to prevent forgetting]
        \(facts)
        [/CORTEX MEMORY]
        """
    }

    /// Compress messages when context gets too long.
    /// Returns a trimmed message array + stores compressed summary as a memory node.
    func compressIfNeeded(messages: [ChatMessage]) -> [ChatMessage] {
        guard isEnabled else { return messages }
        let totalChars = messages.reduce(0) { $0 + $1.content.count }
        guard totalChars > contextThreshold * 4 else { return messages }   // ~4 chars/token

        // Keep the last 6 messages intact, compress the rest
        let keepCount = 6
        guard messages.count > keepCount + 2 else { return messages }

        let toCompress = Array(messages.dropLast(keepCount))
        let toKeep     = Array(messages.suffix(keepCount))

        // Build compression summary
        let summary = buildCompressionSummary(from: toCompress)

        // Store as memory node
        remember(key: "session_summary_\(compressedCount)", value: summary,
                 importance: 0.9, zone: .near)
        compressedCount += 1

        // Inject a system message noting the compression
        let compressionNote = ChatMessage(
            role: .system,
            content: "🧠 [Cortex] Compressed \(toCompress.count) earlier messages into memory. Key context preserved."
        )

        return [compressionNote] + toKeep
    }

    /// Auto-extract facts from AI response.
    func extractAndStore(from aiResponse: String, userInstruction: String) {
        guard isEnabled else { return }

        // Extract file paths created
        let filePattern = #"\[WRITE:\s*([^\]]+)\]"#
        if let regex = try? NSRegularExpression(pattern: filePattern) {
            let matches = regex.matches(in: aiResponse, range: NSRange(aiResponse.startIndex..., in: aiResponse))
            let paths = matches.compactMap { m -> String? in
                Range(m.range(at: 1), in: aiResponse).map { String(aiResponse[$0]).trimmingCharacters(in: .whitespaces) }
            }
            if !paths.isEmpty {
                remember(key: "created_files", value: paths.joined(separator: ", "), importance: 0.8)
            }
        }

        // Extract workspace path
        let wsPattern = #"\[WORKSPACE:\s*([^\]]+)\]"#
        if let regex = try? NSRegularExpression(pattern: wsPattern),
           let match = regex.firstMatch(in: aiResponse, range: NSRange(aiResponse.startIndex..., in: aiResponse)),
           let range = Range(match.range(at: 1), in: aiResponse) {
            let wsPath = String(aiResponse[range]).trimmingCharacters(in: .whitespaces)
            remember(key: "current_workspace", value: wsPath, importance: 0.95, zone: .front)
        }

        // Extract project type from user intent
        let lower = userInstruction.lowercased()
        if lower.contains("python") || lower.contains(".py") {
            remember(key: "project_language", value: "Python", importance: 0.7)
        } else if lower.contains("swift") {
            remember(key: "project_language", value: "Swift", importance: 0.7)
        } else if lower.contains("rust") || lower.contains("cargo") {
            remember(key: "project_language", value: "Rust", importance: 0.7)
        } else if lower.contains("node") || lower.contains("typescript") || lower.contains("react") {
            remember(key: "project_language", value: "TypeScript/Node", importance: 0.7)
        }

        // Store instruction as last user intent
        if userInstruction.count > 10 {
            remember(key: "last_instruction", value: String(userInstruction.prefix(200)), importance: 0.6)
        }
    }

    // MARK: - Clear

    func clearAll() {
        nodes = []
        compressedCount = 0
        saveToDisk()
    }

    // MARK: - Private helpers

    private func buildCompressionSummary(from messages: [ChatMessage]) -> String {
        var lines: [String] = []
        for msg in messages {
            switch msg.role {
            case .user:      lines.append("U: \(msg.content.prefix(100))")
            case .assistant: lines.append("A: \(msg.content.prefix(200))")
            case .system:    break
            }
        }
        return lines.joined(separator: " | ")
    }

    private func runGC() {
        guard nodes.count > maxNodes else { return }
        // Remove lowest importance + oldest nodes
        nodes = nodes
            .sorted { $0.importance * Float($0.accessCount + 1) > $1.importance * Float($1.accessCount + 1) }
            .prefix(maxNodes)
            .map { $0 }
    }

    // MARK: - Disk persistence

    private func saveToDisk() {
        guard let data = try? JSONEncoder().encode(nodes) else { return }
        try? data.write(to: storageURL)
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([MemoryNode].self, from: data)
        else { return }
        nodes = decoded
    }
}
