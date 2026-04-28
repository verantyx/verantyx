import Foundation

// MARK: - JCrossVault
//
// ワークスペース全体の JCross 変換済みシャドウファイルシステム。
// 実体: .verantyx/jcross_vault/{relativePath}.jcross
//       .verantyx/jcross_vault/{relativePath}.schema.json
//
// セキュリティ:
//   - .jcross ファイルには JCross IR のみ（識別子は全てノードID）
//   - .schema.json はノードID ↔ 実識別子のマッピング（ローカルのみ）
//   - .gitignore に jcross_vault/ を追加（リモートへの流出防止）

@MainActor
final class JCrossVault: ObservableObject {

    // MARK: - Types

    enum VaultStatus: Equatable {
        case notInitialized
        case converting(progress: Double, currentFile: String)
        case ready(fileCount: Int, lastConverted: Date)
        case error(String)
    }

    struct VaultEntry: Codable {
        let relativePath: String      // 元ファイルの相対パス
        let jcrossPath: String        // .jcross ファイルの相対パス
        let schemaPath: String        // .schema.json の相対パス
        let l1TagsPath: String?       // .l1tags ファイルの相対パス（BitNet 未導入の場合 nil）
        let convertedAt: Date
        let fileHash: String          // 元ファイルの SHA256（変更検知）
        let nodeCount: Int
        let secretCount: Int
        let schemaSessionID: String   // JCrossSchema の sessionID
    }

    struct VaultIndex: Codable {
        var entries: [String: VaultEntry]  // relativePath → VaultEntry
        var createdAt: Date
        var lastUpdatedAt: Date
        var workspaceRoot: String
    }

    struct ReadResult {
        let jcrossContent: String
        let schema: JCrossSchema
        let entry: VaultEntry
    }

    // MARK: - Properties

    @Published var vaultStatus: VaultStatus = .notInitialized
    @Published var conversionLog: [String] = []

    let workspaceURL: URL
    var vaultIndex: VaultIndex?

    lazy var vaultRootURL: URL = {
        workspaceURL.appendingPathComponent(".verantyx/jcross_vault")
    }()

    private lazy var indexURL: URL = {
        vaultRootURL.appendingPathComponent("VAULT_INDEX.json")
    }()

    // 変換対象の拡張子
    private static let targetExtensions: Set<String> = [
        "swift", "ts", "tsx", "js", "jsx", "py", "rs", "go", "kt", "java",
        "cpp", "cc", "c", "h", "cs", "rb", "php", "sh", "yaml", "json"
    ]

    // 除外パス
    nonisolated(unsafe) private static let excludedPaths: [String] = [
        ".verantyx", ".git", "node_modules", ".build", "build",
        "DerivedData", ".DS_Store", "__pycache__", ".venv", "venv"
    ]

    // MARK: - Init

    init(workspaceURL: URL) {
        self.workspaceURL = workspaceURL
    }

    // MARK: - Initialize Vault

    func initialize() async {
        // 既存インデックスを読み込む
        if let existing = loadIndex() {
            vaultIndex = existing
            let count = existing.entries.count
            let date  = existing.lastUpdatedAt
            vaultStatus = .ready(fileCount: count, lastConverted: date)
            log("✅ Vault ロード完了: \(count) ファイル (最終更新: \(date.formatted()))")

            // セッションマッピング (reverseMap) を復元
            let transpiler = await PolymorphicJCrossTranspiler.shared
            for entry in existing.entries.values {
                let schemaFileURL = vaultRootURL.appendingPathComponent(entry.schemaPath)
                if let data = try? Data(contentsOf: schemaFileURL),
                   let sessionData = try? JSONDecoder().decode(PolymorphicJCrossTranspiler.JCrossSchemaSessionData.self, from: data) {
                    await MainActor.run { transpiler.restoreSession(from: sessionData) }
                }
            }

            // Git 差分で変更されたファイルのみ再変換
            await updateDelta()
        } else {
            // 初回: 全ファイル一括変換
            await bulkConvert()
        }
    }

    // MARK: - Rebuild Vault (強制再変換)

    func rebuildVault() async {
        vaultStatus = .notInitialized
        vaultIndex = nil
        conversionLog.removeAll()
        do {
            try FileManager.default.removeItem(at: vaultRootURL)
        } catch {
            log("Vault ディレクトリ削除に失敗: \(error.localizedDescription) (初回作成の場合は無視可能)")
        }
        await bulkConvert()
    }

    // MARK: - Bulk Conversion (初回)

    // nonisolated: @MainActor クラスのメソッドは省略すると @MainActor を継承するため
    // Task.detached から呼んでも MainActor に戻ってしまう。
    // nonisolated を明示することで真にバックグラウンドで動作する。
    nonisolated func bulkConvert() async {
        // MainActor プロパティへの初回アクセスは await で取得
        let wsRoot    = await workspaceURL
        let vaultRoot = await vaultRootURL
        let idxURL    = await indexURL

        do {
            try FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        } catch {
            let msg = error.localizedDescription
            await MainActor.run { self.vaultStatus = .error("Vault ディレクトリ作成失敗: \(msg)") }
            return
        }

        let files = JCrossVault.collectTargetFiles(wsRoot: wsRoot)
        await MainActor.run { self.log("📁 変換対象: \(files.count) ファイル") }

        // fire-and-forget でバックグラウンド変換を開始
        Task.detached(priority: .utility) { [weak self] in
            await JCrossVault._convertBatch(
                files: files, wsRoot: wsRoot, vaultRoot: vaultRoot, idxURL: idxURL, vault: self
            )
        }
    }

    /// バックグラウンド変換バッチ（nonisolated static — @MainActor を継承しない）
    nonisolated private static func _convertBatch(
        files: [URL],
        wsRoot: URL,
        vaultRoot: URL,
        idxURL: URL,
        vault: JCrossVault?
    ) async {
        guard let vault else { return }

        var index = VaultIndex(
            entries: [:],
            createdAt: Date(),
            lastUpdatedAt: Date(),
            workspaceRoot: wsRoot.path
        )

        for (i, fileURL) in files.enumerated() {
            let relativePath = String(fileURL.path.dropFirst(wsRoot.path.count + 1))
            let prog = Double(i) / Double(max(files.count, 1))
            let rel  = relativePath

            // UI 更新は片道 Task で投げる（await しない）
            Task { @MainActor [weak vault] in
                vault?.vaultStatus = .converting(progress: prog, currentFile: rel)
            }

            do {
                let transpiler = await PolymorphicJCrossTranspiler.shared
                let entry = try await vault.convertFile(
                    fileURL: fileURL, relativePath: relativePath,
                    transpiler: transpiler,
                    vaultRootURL: vaultRoot
                )
                index.entries[relativePath] = entry
                let msg = "  [\(i+1)/\(files.count)] ✓ \(relativePath) (\(entry.nodeCount) nodes)"
                await MainActor.run { vault.conversionLog.append(msg) }
            } catch {
                let msg = "  [\(i+1)/\(files.count)] ⚠️ \(relativePath): \(error.localizedDescription)"
                await MainActor.run { vault.conversionLog.append(msg) }
            }
        }

        index.lastUpdatedAt = Date()

        // ディスク書き込み（バックグラウンド安全）
        if let data = try? JSONEncoder().encode(index) {
            try? data.write(to: idxURL, options: .atomic)
        }
        JCrossVault._addGitignoreEntry(vaultRoot: vaultRoot, wsRoot: wsRoot)

        let count = index.entries.count
        let fin   = index.lastUpdatedAt
        Task { @MainActor [weak vault] in
            vault?.vaultIndex  = index
            vault?.vaultStatus = .ready(fileCount: count, lastConverted: fin)
            vault?.log("✅ 一括変換完了: \(count) ファイル")
        }
    }

    /// ファイル同期変換（nonisolated static — バックグラウンドスレッド専用）
    nonisolated private static func _convertFileSynchronously(
        fileURL: URL,
        relativePath: String,
        wsRoot: URL,
        vaultRoot: URL
    ) throws -> VaultEntry {
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        let ext    = fileURL.pathExtension.lowercased()

        let transpiler = SimpleJCrossTranspiler()
        let (jcrossContent, nodeCount, secretCount, sessionID) =
            transpiler.transpile(source, fileExtension: ext)

        let jcrossURL = vaultRoot.appendingPathComponent(relativePath + ".jcross")
        try FileManager.default.createDirectory(
            at: jcrossURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try jcrossContent.write(to: jcrossURL, atomically: true, encoding: .utf8)

        let hash: String = {
            guard let data = source.data(using: .utf8) else { return "unknown" }
            var h = 5381
            data.forEach { h = ((h << 5) &+ h) &+ Int($0) }
            return String(format: "%08x", h & 0xFFFFFFFF)
        }()

        return VaultEntry(
            relativePath: relativePath,
            jcrossPath:   relativePath + ".jcross",
            schemaPath:   relativePath + ".schema.json",
            l1TagsPath:   nil,
            convertedAt:  Date(),
            fileHash:     hash,
            nodeCount:    nodeCount,
            secretCount:  secretCount,
            schemaSessionID: sessionID
        )
    }

    /// .gitignore 更新（nonisolated static）
    nonisolated private static func _addGitignoreEntry(vaultRoot: URL, wsRoot: URL) {
        let gitignoreURL = wsRoot.appendingPathComponent(".gitignore")
        let entry = "\n# Verantyx JCross Vault (local only)\n.verantyx/jcross_vault/\n"
        if let existing = try? String(contentsOf: gitignoreURL, encoding: .utf8) {
            if !existing.contains("jcross_vault") {
                try? (existing + entry).write(to: gitignoreURL, atomically: true, encoding: .utf8)
            }
        } else {
            try? entry.write(to: gitignoreURL, atomically: true, encoding: .utf8)
        }
    }


    // MARK: - Delta Update (差分)

    func updateDelta() async {
        let changedFiles = gitChangedFiles()
        guard !changedFiles.isEmpty else {
            log("✅ 変更なし — Vault は最新です")
            return
        }

        log("🔄 差分更新: \(changedFiles.count) ファイル")
        let transpiler = PolymorphicJCrossTranspiler.shared

        for relativePath in changedFiles {
            let fileURL = workspaceURL.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                // 削除されたファイル → Vault から除去
                removeFromVault(relativePath: relativePath)
                continue
            }

            do {
                let currentVaultRoot = vaultRootURL
                let entry = try await convertFile(
                    fileURL: fileURL,
                    relativePath: relativePath,
                    transpiler: transpiler,
                    vaultRootURL: currentVaultRoot
                )
                vaultIndex?.entries[relativePath] = entry
                log("  ✓ 更新: \(relativePath)")
            } catch {
                log("  ⚠️ 更新失敗: \(relativePath) — \(error.localizedDescription)")
            }
        }

        vaultIndex?.lastUpdatedAt = Date()
        if let index = vaultIndex { saveIndex(index) }
        log("✅ 差分更新完了")
    }

    // MARK: - Read (外部API向け)

    func read(relativePath: String) -> ReadResult? {
        guard let entry = vaultIndex?.entries[relativePath] else { return nil }

        let jcrossURL = vaultRootURL.appendingPathComponent(entry.jcrossPath)
        let schemaURL = vaultRootURL.appendingPathComponent(entry.schemaPath)

        guard let jcrossContent = try? String(contentsOf: jcrossURL, encoding: .utf8) else { return nil }

        let schema: JCrossSchema
        if let schemaData = try? Data(contentsOf: schemaURL),
           let decoded = try? JSONDecoder().decode(JCrossSchema.self, from: schemaData) {
            schema = decoded
        } else {
            schema = JCrossSchema(
                sessionID: entry.schemaSessionID,
                createdAt: entry.convertedAt,
                schemaVersion: 1,
                nodeOpen: "⟨",
                nodeClose: "⟩",
                secretOpen: "「",
                secretClose: "」",
                tagOpen: "[",
                tagClose: "]",
                kanjiCategoryMap: [:],
                opNameMap: [:],
                nodePrefixMap: [:],
                noiseLevel: 0,
                noiseNodeIDs: []
            )
        }

        return ReadResult(jcrossContent: jcrossContent, schema: schema, entry: entry)
    }

    // MARK: - Write Diff (逆変換 → 実ファイル書き込み)

    func writeDiff(
        jcrossDiff: String,
        relativePath: String,
        transpiler: PolymorphicJCrossTranspiler
    ) async throws -> String {
        var targetEntry = vaultIndex?.entries[relativePath]

        if targetEntry == nil, let index = vaultIndex {
            let searchName = URL(fileURLWithPath: relativePath).lastPathComponent.lowercased()
            let baseName = searchName.replacingOccurrences(of: ".jc", with: "").replacingOccurrences(of: ".jcross", with: "")
            if let matched = index.entries.values.first(where: {
                $0.relativePath.lowercased().hasSuffix(baseName) ||
                URL(fileURLWithPath: $0.relativePath).lastPathComponent.lowercased().starts(with: baseName)
            }) {
                targetEntry = matched
            }
        }

        guard let entry = targetEntry else {
            throw VaultError.entryNotFound(relativePath)
        }

        // JCross → 実コードに逆変換
        guard let restored = transpiler.reverseTranspile(jcrossDiff, schemaID: entry.schemaSessionID) else {
            throw VaultError.reverseTranspileFailed(entry.relativePath)
        }

        // 実ファイルに書き込み
        let fileURL = workspaceURL.appendingPathComponent(entry.relativePath)
        try restored.write(to: fileURL, atomically: true, encoding: .utf8)

        // Vault を更新（差分適用後の状態で再変換）
        await updateDelta()

        log("✅ 逆変換・書き込み完了: \(entry.relativePath)")
        return restored
    }

    // MARK: - List Directory (抽象化)

    func listDirectory(relativePath: String) -> [AbstractedFileInfo] {
        guard let index = vaultIndex else { return [] }
        let prefix = relativePath.isEmpty ? "" : relativePath + "/"

        // 直下のエントリのみ返す
        var seen = Set<String>()
        var result: [AbstractedFileInfo] = []

        for path in index.entries.keys {
            guard path.hasPrefix(prefix) else { continue }
            let rest = String(path.dropFirst(prefix.count))
            let component = rest.components(separatedBy: "/").first ?? rest
            if seen.contains(component) { continue }
            seen.insert(component)

            let isDir = rest.contains("/")
            let entry = index.entries[path]
            result.append(AbstractedFileInfo(
                name: component,
                isDirectory: isDir,
                jcrossPath: isDir ? nil : entry?.jcrossPath,
                nodeCount: isDir ? nil : entry?.nodeCount,
                secretCount: isDir ? nil : entry?.secretCount
            ))
        }

        return result.sorted { $0.isDirectory && !$1.isDirectory || $0.name < $1.name }
    }

    // MARK: - Search (JCross内のノードID検索)

    func search(query: String) -> [SearchResult] {
        guard let index = vaultIndex else { return [] }
        var results: [SearchResult] = []

        for (path, entry) in index.entries {
            let jcrossURL = vaultRootURL.appendingPathComponent(entry.jcrossPath)
            guard let content = try? String(contentsOf: jcrossURL, encoding: .utf8) else { continue }

            // JCross IR 内でクエリに一致する行を検索
            let matchingLines = content.components(separatedBy: "\n")
                .enumerated()
                .filter { $0.element.localizedCaseInsensitiveContains(query) }
                .prefix(3)
                .map { SearchResult.Match(lineNumber: $0.offset + 1, line: String($0.element.prefix(120))) }

            if !matchingLines.isEmpty {
                results.append(SearchResult(relativePath: path, matches: Array(matchingLines)))
            }

            if results.count >= 20 { break }
        }

        return results
    }

    // MARK: - Private Helpers

    nonisolated private func convertFile(
        fileURL: URL,
        relativePath: String,
        transpiler: PolymorphicJCrossTranspiler,
        vaultRootURL: URL
    ) async throws -> VaultEntry {
        let source = try String(contentsOf: fileURL, encoding: .utf8)
        let lang   = JCrossCodeTranspiler.CodeLanguage.from(extension: fileURL.pathExtension)

        let (jcrossContent, schemaID, _) = await transpiler.transpile(
            source, language: lang, noiseLevel: 2
        )

        // ノード数・シークレット数を取得
        let session     = await transpiler.currentSchema
        let nodeCount   = await transpiler.sessionNodeCount(for: schemaID)
        let secretCount = await transpiler.sessionSecretCount(for: schemaID)
        let schema      = session

        // .jcross ファイルを書き込む
        let safeRelPath   = relativePath.replacingOccurrences(of: "/", with: "∕")
        let jcrossRelPath = safeRelPath + ".jcross"
        let schemaRelPath = safeRelPath + ".schema.json"

        let jcrossFileURL = vaultRootURL.appendingPathComponent(jcrossRelPath)
        let schemaFileURL = vaultRootURL.appendingPathComponent(schemaRelPath)

        try jcrossContent.write(to: jcrossFileURL, atomically: true, encoding: .utf8)
        if let sessionData = await transpiler.getSessionData(for: schemaID) {
            let schemaData = try JSONEncoder().encode(sessionData)
            try schemaData.write(to: schemaFileURL)
        }

        // ── BitNet L1 タグ生成 ──────────────────────────────────────────
        // BitNet b1.58 が動いている場合は L1 漢字トポロジータグを生成し保存する。
        // 未インストールの場合はルールベースフォールバックで提供する。
        let langName = fileURL.pathExtension.lowercased()
        let l1Tags = await generateL1TagsViaBitNet(source: source, language: langName)
        let l1TagsRelPath = safeRelPath + ".l1tags"
        let l1TagsFileURL = vaultRootURL.appendingPathComponent(l1TagsRelPath)
        if let l1Data = l1Tags.data(using: .utf8) {
            try l1Data.write(to: l1TagsFileURL)
        }
        // ───────────────────────────────────────────────────────────────

        let fileHash = await sha256(of: source)
        return VaultEntry(
            relativePath: relativePath,
            jcrossPath: jcrossRelPath,
            schemaPath: schemaRelPath,
            l1TagsPath: l1TagsRelPath,
            convertedAt: Date(),
            fileHash: fileHash,
            nodeCount: nodeCount,
            secretCount: secretCount,
            schemaSessionID: schemaID
        )
    }

    nonisolated private static func collectTargetFiles(wsRoot: URL) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: wsRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        for case let fileURL as URL in enumerator {
            // Check if it's a directory
            let resourceValues = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDirectory = resourceValues?.isDirectory ?? false
            let fileName = fileURL.lastPathComponent

            if isDirectory {
                if JCrossVault.excludedPaths.contains(fileName) {
                    enumerator.skipDescendants()
                }
                continue
            }

            // Exclude minified files
            if fileName.contains(".min.") { continue }

            // Exclude by path substrings just in case
            let path = fileURL.path
            if JCrossVault.excludedPaths.contains(where: { path.contains("/\($0)/") || path.hasSuffix("/\($0)") }) {
                continue
            }

            // 拡張子フィルタ
            let ext = fileURL.pathExtension.lowercased()
            guard JCrossVault.targetExtensions.contains(ext) else { continue }

            // サイズフィルタ (500KB 以上は重すぎるため JCross 変換対象外)
            let fileSize = resourceValues?.fileSize ?? 0
            if fileSize > 500_000 { continue }

            result.append(fileURL)
        }

        return result
    }

    private func gitChangedFiles() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["diff", "--name-only", "HEAD"]
        process.currentDirectoryURL = workspaceURL

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = Pipe()

        try? process.run()
        process.waitUntilExit()

        let data   = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func removeFromVault(relativePath: String) {
        guard let entry = vaultIndex?.entries[relativePath] else { return }
        try? FileManager.default.removeItem(at: vaultRootURL.appendingPathComponent(entry.jcrossPath))
        try? FileManager.default.removeItem(at: vaultRootURL.appendingPathComponent(entry.schemaPath))
        vaultIndex?.entries.removeValue(forKey: relativePath)
        log("🗑️ Vault から除去: \(relativePath)")
    }

    private func loadIndex() -> VaultIndex? {
        guard let data = try? Data(contentsOf: indexURL) else { return nil }
        return try? JSONDecoder().decode(VaultIndex.self, from: data)
    }

    private func saveIndex(_ index: VaultIndex) {
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL)
    }

    private func addGitignoreEntry() {
        let gitignoreURL = workspaceURL.appendingPathComponent(".gitignore")
        let entry = "\n# Verantyx JCross Vault (session-specific schemas — never commit)\n.verantyx/jcross_vault/\n"

        if let existing = try? String(contentsOf: gitignoreURL, encoding: .utf8) {
            if !existing.contains("jcross_vault") {
                try? (existing + entry).write(to: gitignoreURL, atomically: true, encoding: .utf8)
                log("📝 .gitignore に jcross_vault/ を追加")
            }
        } else {
            try? entry.write(to: gitignoreURL, atomically: true, encoding: .utf8)
        }
    }

    private func sha256(of string: String) -> String {
        let data = Data(string.utf8)
        var hash = [UInt8](repeating: 0, count: 32)
        data.withUnsafeBytes { ptr in
            _ = ptr // Simple checksum as placeholder
        }
        return String(data.hashValue, radix: 16)
    }

    private func log(_ message: String) {
        conversionLog.append("[\(Date().formatted(.dateTime.hour().minute().second()))] \(message)")
        if conversionLog.count > 500 { conversionLog.removeFirst(100) }
    }

    // MARK: - Errors

    enum VaultError: Error, LocalizedError {
        case entryNotFound(String)
        case reverseTranspileFailed(String)
        var errorDescription: String? {
            switch self {
            case .entryNotFound(let p): return "Vault にエントリなし: \(p)"
            case .reverseTranspileFailed(let p): return "逆変換失敗 (スキーマが見つかりません): \(p)"
            }
        }
    }

    // MARK: - L1 Tag Bridge

    /// BitNet L1 タグ生成への橋渡し。
    private func generateL1TagsViaBitNet(source: String, language: String) async -> String {
        let lower = source.lowercased()
        var tags: [String] = []
        switch language {
        case "swift":       tags.append("[迅:1.0]")
        case "rs":          tags.append("[錆:1.0]")
        case "py":          tags.append("[蛇:1.0]")
        case "ts", "tsx":   tags.append("[型:1.0]")
        default:            tags.append("[码:1.0]")
        }
        if lower.contains("async") || lower.contains("await") { tags.append("[並:0.9]") }
        if lower.contains("secret") || lower.contains("token") { tags.append("[秘:0.9]") }
        if lower.contains("network") || lower.contains("http")  { tags.append("[網:0.8]") }
        if lower.contains("database") || lower.contains("sql")  { tags.append("[蔵:0.8]") }
        return tags.prefix(5).joined()
    }
}

// MARK: - Supporting Types

struct AbstractedFileInfo: Identifiable {
    let id = UUID()
    let name: String
    let isDirectory: Bool
    let jcrossPath: String?
    let nodeCount: Int?
    let secretCount: Int?

    var icon: String { isDirectory ? "folder.fill" : "doc.text" }
}

struct SearchResult: Identifiable {
    let id = UUID()
    let relativePath: String
    let matches: [Match]

    struct Match: Identifiable {
        let id = UUID()
        let lineNumber: Int
        let line: String
    }
}

// MARK: - JCrossCodeTranspiler Language Extension

extension JCrossCodeTranspiler.CodeLanguage {
    static func from(extension ext: String) -> JCrossCodeTranspiler.CodeLanguage {
        switch ext.lowercased() {
        case "swift": return .swift
        case "py":    return .python
        case "ts", "tsx": return .typescript
        case "js", "jsx": return .javascript
        case "rs":    return .rust
        case "go":    return .go
        case "kt":    return .kotlin
        case "java":  return .java
        default:      return .plain
        }
    }
}

// MARK: - PolymorphicJCrossTranspiler Session Extensions

extension PolymorphicJCrossTranspiler {
    func sessionNodeCount(for schemaID: String) async -> Int {
        // schemaSessions は private なので currentSchema から取得
        return 0  // TODO: expose session stats
    }
    func sessionSecretCount(for schemaID: String) async -> Int {
        return 0  // TODO: expose session stats
    }
}
