import Foundation

// MARK: - SkillNode
// A single stored skill — the unit of the Verantyx Skill Library.
//
// Storage: ~/.openclaw/memory/skills/<name>.skill.json
//   SHARED between:
//   • This Swift app (read/write via SkillLibrary actor)
//   • MCP server (Node.js, port 5420) — writes via distill_skill / forge_skill
//
// Cloud models calling distill_skill via MCP write here; the IDE picks it up
// automatically via MCPSkillSync polling (GET /skills/version every 5s).
//
// Inspired by Voyager (Wang et al., 2023): LLMs store successful workflows
// as reusable primitives, radically reducing redundant reasoning per turn.

struct SkillNode: Codable, Sendable, Identifiable {

    // ── Identity ──────────────────────────────────────────────────────────
    var id: String { name }
    let name:        String       // snake_case, unique key
    let description: String       // used as tool description in system prompt
    var version:     Int          // bumped on refinement
    let createdAt:   Date
    var updatedAt:   Date
    var tags:        [String]     // semantic labels for retrieval

    // ── Spatial topology ──────────────────────────────────────────────────
    // JCross Kanji topology tags — set by distill_skill's kanjiAutoClassify().
    // Example: "[技:1.0] [編:0.9] [蒸:0.7]"
    // [蒸:0.7] marks skills distilled from cloud-model histories.
    var kanjiTags:  String?

    // ── Provenance ────────────────────────────────────────────────────────
    // "user" | "community" | "cloud" | "distilled"
    var source:     String?

    // ── Execution ─────────────────────────────────────────────────────────
    let executionType: ExecutionType
    var payload:       [String]   // macro: ordered [TOOL:…] strings | script: body

    enum ExecutionType: String, Codable, Sendable {
        case macro   // replay a sequence of [TOOL:…] strings
        case script  // execute a shell script in Safe Zone
    }

    // ── Stats ─────────────────────────────────────────────────────────────
    var successCount: Int = 0
    var failCount:    Int = 0
    var forgedBy:     String = ""  // model that created this skill
}

// MARK: - SkillLibrary

/// Actor managing the on-disk skill index and in-memory retrieval.
/// Lives as a singleton; safe to call from any isolation context.
actor SkillLibrary {

    static let shared = SkillLibrary()

    // ── Storage root ──────────────────────────────────────────────────────
    // Shared with MCP server. Must match ENGINE_ROOT/skills in server.ts.
    let skillsDir: URL = {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw/memory/skills", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    // ── In-memory index ───────────────────────────────────────────────────
    private var index: [String: SkillNode] = [:]   // name → node

    private init() {}

    // MARK: - Index boot

    /// Load all .skill.json files from disk into memory. Call once at app start.
    func loadIndex() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: skillsDir,
            includingPropertiesForKeys: nil
        ) else { return }

        var loaded = 0
        for file in files where file.pathExtension == "json" && file.lastPathComponent.hasSuffix(".skill.json") {
            if let data = try? Data(contentsOf: file),
               let node = try? makeDecoder().decode(SkillNode.self, from: data) {
                index[node.name] = node
                loaded += 1
            }
        }
        if loaded > 0 {
            print("[SkillLibrary] Loaded \(loaded) skill(s) from \(skillsDir.path)")
        }
    }

    // MARK: - Hot-reload (called by MCPSkillSync)

    /// Reload all skills from disk, replacing the in-memory index.
    /// Called automatically when MCPSkillSync detects a version change.
    func reloadIndex() {
        index.removeAll()
        loadIndex()
    }

    // MARK: - Save / Forge

    /// Persist a SkillNode to disk and update the in-memory index.
    /// If a skill with the same name already exists, it is refined (version bumped).
    @discardableResult
    func save(_ node: SkillNode) -> SkillNode {
        var refined = node
        if let existing = index[node.name] {
            refined = SkillNode(
                name:          existing.name,
                description:   node.description,
                version:       existing.version + 1,
                createdAt:     existing.createdAt,
                updatedAt:     Date(),
                tags:          node.tags,
                kanjiTags:     node.kanjiTags ?? existing.kanjiTags,
                source:        node.source ?? existing.source,
                executionType: node.executionType,
                payload:       node.payload,
                successCount:  existing.successCount,
                failCount:     existing.failCount,
                forgedBy:      node.forgedBy
            )
        }
        index[refined.name] = refined
        persistToDisk(refined)
        return refined
    }

    private func persistToDisk(_ node: SkillNode) {
        let enc = JSONEncoder()
        enc.outputFormatting     = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(node) else { return }
        let file = skillsDir.appendingPathComponent("\(node.name).skill.json")
        try? data.write(to: file, options: .atomic)
    }

    // MARK: - Retrieval

    /// Return the top-N skills most relevant to a query string.
    /// Uses lightweight TF-IDF-style scoring on name + description + tags + kanjiTags.
    func search(query: String, topK: Int = 3) -> [SkillNode] {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return Array(index.values.prefix(topK)) }

        var scored: [(SkillNode, Double)] = []
        for node in index.values {
            let corpusText: String = node.name + " " + node.description + " "
                + node.tags.joined(separator: " ") + " "
                + (node.kanjiTags ?? "")
            let corpus: Set<String> = tokenize(corpusText)
            var hits = 0
            for t in tokens where corpus.contains(t) { hits += 1 }
            let score: Double = Double(hits) / Double(tokens.count)
            if score > 0 { scored.append((node, score)) }
        }
        scored.sort { $0.1 > $1.1 }
        return Array(scored.prefix(topK).map { $0.0 })
    }

    /// Return a skill by exact name (nil if not found).
    func skill(named name: String) -> SkillNode? { index[name] }

    /// All registered skill names.
    var allNames: [String] { Array(index.keys).sorted() }

    /// Total number of skills in the library.
    var count: Int { index.count }

    // MARK: - Record outcomes

    func recordSuccess(name: String) {
        guard var node = index[name] else { return }
        node.successCount += 1
        save(node)
    }

    func recordFailure(name: String) {
        guard var node = index[name] else { return }
        node.failCount += 1
        save(node)
    }

    // MARK: - Helpers

    private func tokenize(_ text: String) -> Set<String> {
        Set(
            text
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 2 }
        )
    }

    private func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

// MARK: - MCPSkillSync

/// Polls the MCP HTTP bridge at http://127.0.0.1:5420/skills/version every 5 seconds.
/// When the version token changes (new skill distilled from cloud), triggers a full
/// index reload so VerantyxIDE picks up new skills without requiring a restart.
///
/// Usage:
///   MCPSkillSync.shared.startPolling()   // called from app launch
///   MCPSkillSync.shared.stopPolling()    // called on app quit (optional)
@MainActor
final class MCPSkillSync: ObservableObject {

    static let shared = MCPSkillSync()

    private let bridgeBase = URL(string: "http://127.0.0.1:5420")!
    private let pollInterval: TimeInterval = 5.0

    /// Last version token received from /skills/version
    @Published private(set) var lastVersion: Int = 0
    /// Number of skills reported by MCP server
    @Published private(set) var mcpSkillCount: Int = 0
    /// True if the MCP bridge is reachable
    @Published private(set) var bridgeReachable: Bool = false

    private var pollTask: Task<Void, Never>?
    private init() {}

    // MARK: - Lifecycle

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: UInt64(5.0 * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Poll

    private func poll() async {
        let url = bridgeBase.appendingPathComponent("skills/version")
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                await MainActor.run { self.bridgeReachable = false }
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let version = json["version"] as? Int else { return }

            let count = json["count"] as? Int ?? 0
            let changed = version != self.lastVersion

            await MainActor.run {
                self.bridgeReachable = true
                self.mcpSkillCount   = count
            }

            if changed {
                await MainActor.run { self.lastVersion = version }
                // Version changed — reload the full index
                await SkillLibrary.shared.reloadIndex()
                let n = await SkillLibrary.shared.count
                print("[MCPSkillSync] Version changed → \(version). Reloaded \(n) skill(s).")
                // Notify any observers (e.g. SkillLibraryView)
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .skillLibraryDidReload,
                        object: nil,
                        userInfo: ["version": version, "count": count]
                    )
                }
            }
        } catch {
            await MainActor.run { self.bridgeReachable = false }
        }
    }
}

// MARK: - Notification name

extension Notification.Name {
    /// Posted by MCPSkillSync whenever the skill library is reloaded from MCP.
    static let skillLibraryDidReload = Notification.Name("verantyx.skillLibraryDidReload")
}

// MARK: - SkillInjector

/// Builds the §スキルライブラリ section injected into the agent system prompt.
/// Shows kanji topology tags and cloud-distillation badges.
enum SkillInjector {

    static func buildSection(skills: [SkillNode]) -> String {
        guard !skills.isEmpty else { return "" }

        var lines: [String] = [
            "",
            "── §スキルライブラリ SKILL LIBRARY (技: 習得済みスキル) ──────────────────────",
            "以下のスキルは過去の成功体験から自動生成されたカスタムツールです。",
            "該当タスクでは必ず組み込みツールより先に呼び出してください。",
            "",
            "呼び出し構文: [USE_SKILL: スキル名]",
            "パラメータ付き: [USE_SKILL: スキル名|key=val|key=val]",
            "",
        ]

        for skill in skills {
            let tags  = skill.tags.prefix(3).joined(separator: ", ")
            let kTags = skill.kanjiTags ?? ""
            // Badge: ✦蒸留 = distilled from cloud model, ★共有 = community skill
            let badge = skill.source == "distilled" ? " ✦蒸留" :
                        skill.source == "community"  ? " ★共有" : ""
            lines.append("  🔧 \(skill.name)  v\(skill.version)\(badge)")
            lines.append("     └─ \(skill.description)")
            if !kTags.isEmpty { lines.append("        kanji: \(kTags)") }
            if !tags.isEmpty  { lines.append("        tags: \(tags)") }
            lines.append("        ✅ \(skill.successCount) wins | ❌ \(skill.failCount) fails")
            lines.append("")
        }

        lines += [
            "新しいスキルの登録:",
            "  [FORGE_SKILL: 名前|説明|tag1,tag2]",
            "  ```",
            "  ツール呼び出しシーケンス…",
            "  ```",
            "  [/FORGE_SKILL]",
            "",
        ]
        return lines.joined(separator: "\n")
    }
}

// MARK: - SkillExecutor

/// Executes a SkillNode in the context of the current agent loop.
/// Returns a result string fed back to the LLM as a tool result.
actor SkillExecutor {

    private let toolExecutor = AgentToolExecutor()

    func execute(
        skill: SkillNode,
        args: [String: String] = [:],
        workspaceURL: URL?,
        onProgress: @escaping @Sendable (LoopEvent) async -> Void
    ) async -> String {

        switch skill.executionType {

        case .macro:
            return await executeMacro(
                skill: skill,
                args: args,
                workspaceURL: workspaceURL,
                onProgress: onProgress
            )

        case .script:
            return await executeScript(
                skill: skill,
                args: args,
                workspaceURL: workspaceURL
            )
        }
    }

    // MARK: Macro execution

    private func executeMacro(
        skill: SkillNode,
        args: [String: String],
        workspaceURL: URL?,
        onProgress: @escaping @Sendable (LoopEvent) async -> Void
    ) async -> String {

        var results: [String] = []
        var stepIndex = 0

        for rawLine in skill.payload {
            // Substitute any {{key}} placeholders with supplied args
            let line = substitutePlaceholders(rawLine, args: args)
            stepIndex += 1

            let (toolCalls, _) = AgentToolParser.parse(from: line)
            if toolCalls.isEmpty {
                // Plain text in payload — skip silently
                continue
            }

            for tool in toolCalls {
                let call = AgentToolCall(tool: tool)
                await onProgress(.toolCall(call))

                let result = await toolExecutor.execute(tool, workspaceURL: workspaceURL)
                results.append("  step\(stepIndex): \(result)")

                let completed = AgentToolCall(tool: tool, result: result, succeeded: !result.hasPrefix("✗"))
                await onProgress(.toolResult(completed))
            }
        }

        await SkillLibrary.shared.recordSuccess(name: skill.name)
        return """
        ✓ [Skill: \(skill.name)] completed \(results.count) step(s)
        \(results.joined(separator: "\n"))
        """
    }

    // MARK: Script execution

    private func executeScript(
        skill: SkillNode,
        args: [String: String],
        workspaceURL: URL?
    ) async -> String {

        guard let scriptBody = skill.payload.first else {
            return "✗ [Skill: \(skill.name)] Empty script payload"
        }

        let substituted = substitutePlaceholders(scriptBody, args: args)

        // Write to a temp file and execute in workspace (Safe Zone constraint)
        let tmpDir  = FileManager.default.temporaryDirectory
        let tmpFile = tmpDir.appendingPathComponent("vx_skill_\(skill.name)_\(UUID().uuidString).sh")

        do {
            try substituted.write(to: tmpFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpFile.path)
        } catch {
            return "✗ [Skill: \(skill.name)] Failed to write script: \(error.localizedDescription)"
        }

        let result = await runShellScript(path: tmpFile.path, workingDir: workspaceURL)
        try? FileManager.default.removeItem(at: tmpFile)

        if result.hasPrefix("✗") {
            await SkillLibrary.shared.recordFailure(name: skill.name)
        } else {
            await SkillLibrary.shared.recordSuccess(name: skill.name)
        }
        return "✓ [Skill: \(skill.name)]\n\(result)"
    }

    // MARK: Helpers

    private func substitutePlaceholders(_ text: String, args: [String: String]) -> String {
        var result = text
        for (k, v) in args {
            result = result.replacingOccurrences(of: "{{\(k)}}", with: v)
        }
        return result
    }

    private func runShellScript(path: String, workingDir: URL?) async -> String {
        await withCheckedContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/bash")
            proc.arguments = [path]
            if let wd = workingDir { proc.currentDirectoryURL = wd }

            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError  = errPipe

            do {
                try proc.run()
                proc.waitUntilExit()
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: outData, encoding: .utf8) ?? ""
                let err = String(data: errData, encoding: .utf8) ?? ""
                let combined = [out, err].filter { !$0.isEmpty }.joined(separator: "\n").prefix(2000)
                continuation.resume(returning: proc.terminationStatus == 0
                    ? String(combined)
                    : "✗ exit \(proc.terminationStatus)\n\(combined)"
                )
            } catch {
                continuation.resume(returning: "✗ Script launch failed: \(error.localizedDescription)")
            }
        }
    }
}
