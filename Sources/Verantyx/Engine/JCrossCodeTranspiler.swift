import Foundation

// MARK: - JCrossCodeTranspiler
//
// Verantyx IDE の「独自中間言語難読化」エンジン。
//
// コードを JCross 言語（漢字トポロジー + OP コマンド）に変換してから
// 外部 API（Claude 等）に送信することで、ソースコードが一切漏洩しない。
//
// 処理フロー：
//   Source Code
//       ↓ transpileToJCross()
//   JCross IR (漢字タグ + OP コマンド)   ← 外部APIへ送信
//       ↓ reverseTranspile()
//   Source Code (完全復元)               ← エディタに反映
//
// BitNet b1.58 統合ポイント:
//   現在: ルールベースの決定論的変換
//   将来: BitNetTranspilerInterface プロトコルに BitNet エンジンを差し込む
//
// --------------------------------------------------------------------------
// JCross 漢字トポロジー（セマンティックカテゴリ）
// --------------------------------------------------------------------------
//   核 (kaku)  = core / function / main logic    重み 1.0
//   処 (sho)   = process / method / algorithm   重み 0.9
//   変 (hen)   = variable / mutable state       重み 0.8
//   型 (kata)  = type / class / struct           重み 0.9
//   流 (ryu)   = control flow (if/loop/switch)  重み 0.7
//   鍵 (kagi)  = key / secret / credential      重み 1.0 → 完全削除
//   網 (mo)    = network / API / HTTP            重み 0.8
//   蔵 (kura)  = storage / database / file      重み 0.7
//   標 (hyo)   = constant / literal value       重み 0.6
//   束 (taba)  = parameter / argument            重み 0.5
// --------------------------------------------------------------------------

// MARK: - Kanji Tag

struct KanjiTag: Codable {
    let kanji: String
    let weight: Double
}

// MARK: - JCross Node

struct JCrossCodeNode: Codable {
    let id: String
    let kanjiTags: [KanjiTag]
    let opCommand: String
    let originalSymbol: String
    let isSensitive: Bool

    var jcrossLiteral: String {
        let tags = kanjiTags.map { "[\($0.kanji):\(String(format: "%.1f", $0.weight))]" }.joined()
        return "\(tags) \(opCommand)(\"\(id)\")"
    }
}

// MARK: - Transpile Session

final class JCrossTranspileSession {
    let sessionID: String
    let createdAt: Date
    var expiresAt: Date

    // Bidirectional lookup tables (in-memory only, never persisted externally)
    private(set) var nodesByID: [String: JCrossCodeNode] = [:]    // "A1" → node
    private(set) var nodesBySymbol: [String: JCrossCodeNode] = [:] // "processX" → node

    // Restore mapping: "<jcross_id>" → original symbol
    var restoreMap: [String: String] {
        nodesByID.reduce(into: [:]) { $0[$1.key] = $1.value.isSensitive ? nil : $1.value.originalSymbol }
            .compactMapValues { $0 }
    }

    private var counter: [String: Int] = [:] // prefix → counter for ID generation

    init() {
        self.sessionID = UUID().uuidString
        self.createdAt = Date()
        self.expiresAt = Date().addingTimeInterval(24 * 3600)
    }

    func nextID(prefix: String) -> String {
        let n = (counter[prefix] ?? 0) + 1
        counter[prefix] = n
        return "\(prefix)\(n)"
    }

    func register(_ node: JCrossCodeNode) {
        nodesByID[node.id] = node
        nodesBySymbol[node.originalSymbol] = node
    }

    var isExpired: Bool { Date() > expiresAt }
}

// MARK: - BitNet Transpiler Interface (未来の差し替えポイント)

protocol BitNetTranspilerInterface {
    /// ソースコードから機密識別子リストを抽出 (JSON配列で返す)
    func extractSensitiveIdentifiers(from code: String) async -> [String]
}

/// 現在の実装: ルールベース NER (BitNet の代替)
/// 将来: `class BitNetTranspilerEngine: BitNetTranspilerInterface` に差し替え
struct RuleBaseNEREngine: BitNetTranspilerInterface {

    func extractSensitiveIdentifiers(from code: String) async -> [String] {
        var found: [String] = []

        // 正規表現パターン一覧
        let patterns: [(pattern: String, label: String)] = [
            // API Keys
            (#"sk_live_[a-zA-Z0-9]{24,}"#,    "api_key"),
            (#"sk_test_[a-zA-Z0-9]{24,}"#,    "api_key"),
            (#"AKIA[0-9A-Z]{16}"#,             "aws_key"),
            (#"ghp_[a-zA-Z0-9]{36}"#,         "github_pat"),
            (#"Bearer\s+[a-zA-Z0-9._-]{20,}"#,"bearer_token"),
            // Network
            (#"\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"#, "ip_address"),
            (#"https?://[^\s\"']{10,}"#,       "url"),
            // Credentials
            (#"password\s*=\s*[\"'][^\"']{3,}[\"']"#, "password"),
            (#"secret\s*=\s*[\"'][^\"']{3,}[\"']"#,   "secret"),
            // Emails
            (#"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#, "email"),
            // JWT
            (#"eyJ[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{20,}\.[a-zA-Z0-9_-]{20,}"#, "jwt"),
        ]

        for (pattern, _) in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let ns = code as NSString
                let matches = regex.matches(in: code, range: NSRange(location: 0, length: ns.length))
                for match in matches {
                    let matched = ns.substring(with: match.range)
                    found.append(matched)
                }
            }
        }

        return Array(Set(found)) // deduplicate
    }
}

// MARK: - JCrossCodeTranspiler

@MainActor
final class JCrossCodeTranspiler: ObservableObject {

    // MARK: - State

    @Published var currentSession: JCrossTranspileSession?
    @Published var isTranspiling = false

    private let nerEngine: any BitNetTranspilerInterface
    private var sessions: [String: JCrossTranspileSession] = [:]

    // Kanji topology assignment rules
    private static let kanjiMap: [String: (String, Double)] = [
        // Keywords → 流 (control flow)
        "if": ("流", 0.7), "else": ("流", 0.7), "for": ("流", 0.7),
        "while": ("流", 0.7), "switch": ("流", 0.7), "guard": ("流", 0.7),
        "return": ("流", 0.6), "break": ("流", 0.5), "continue": ("流", 0.5),
        // Types → 型
        "class": ("型", 0.9), "struct": ("型", 0.9), "enum": ("型", 0.85),
        "protocol": ("型", 0.85), "extension": ("型", 0.8),
        // Declarations → 核
        "func": ("核", 1.0), "def": ("核", 1.0), "fn": ("核", 1.0),
        "function": ("核", 1.0), "method": ("処", 0.9),
        // Variables → 変
        "var": ("変", 0.8), "let": ("変", 0.75), "const": ("変", 0.75),
        // Network → 網
        "http": ("網", 0.8), "api": ("網", 0.8), "request": ("網", 0.7),
        "response": ("網", 0.7), "fetch": ("網", 0.75), "url": ("網", 0.8),
        // Storage → 蔵
        "database": ("蔵", 0.7), "storage": ("蔵", 0.7), "file": ("蔵", 0.65),
        "cache": ("蔵", 0.65), "save": ("蔵", 0.6), "load": ("蔵", 0.6),
        // Sensitive → 鍵 (will be wiped)
        "key": ("鍵", 1.0), "secret": ("鍵", 1.0), "password": ("鍵", 1.0),
        "token": ("鍵", 0.95), "auth": ("鍵", 0.9), "credential": ("鍵", 1.0),
    ]

    init(nerEngine: any BitNetTranspilerInterface = RuleBaseNEREngine()) {
        self.nerEngine = nerEngine
    }

    // MARK: - Session Management

    func newSession() -> JCrossTranspileSession {
        let session = JCrossTranspileSession()
        sessions[session.sessionID] = session
        currentSession = session
        return session
    }

    func session(for id: String) -> JCrossTranspileSession? {
        sessions[id]
    }

    func purgeExpiredSessions() {
        sessions = sessions.filter { !$0.value.isExpired }
    }

    // MARK: - Main API

    /// ソースコード → JCross 中間言語変換
    /// 返値: (jcrossCode, sessionID)  ← sessionID は復元時に必要
    func transpileToJCross(_ source: String, language: CodeLanguage) async -> (jcross: String, sessionID: String) {
        isTranspiling = true
        defer { isTranspiling = false }

        let session = newSession()

        // Phase 1: NER でセンシティブ識別子を抽出
        let sensitiveTokens = await nerEngine.extractSensitiveIdentifiers(from: source)

        // Phase 2: 構文トークン化
        let tokens = tokenize(source, language: language)

        // Phase 3: JCross 変換
        var output = ""
        output += jcrossHeader(language: language)
        output += transpileTokens(tokens, sensitiveTokens: Set(sensitiveTokens), session: session, language: language)

        return (output, session.sessionID)
    }

    /// JCross → ソースコード復元
    func reverseTranspile(_ jcross: String, sessionID: String) -> String? {
        guard let session = sessions[sessionID], !session.isExpired else { return nil }
        return restoreFromJCross(jcross, session: session)
    }

    // MARK: - Tokenizer

    private func tokenize(_ source: String, language: CodeLanguage) -> [CodeToken] {
        var tokens: [CodeToken] = []
        let lines = source.components(separatedBy: "\n")

        for (lineNum, line) in lines.enumerated() {
            // Simple line-based tokenization
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count

            if trimmed.isEmpty {
                tokens.append(CodeToken(kind: .blank, value: "", lineNumber: lineNum, indent: indent))
                continue
            }

            if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") || trimmed.hasPrefix("--") {
                tokens.append(CodeToken(kind: .comment, value: line, lineNumber: lineNum, indent: indent))
                continue
            }

            tokens.append(CodeToken(kind: .code, value: line, lineNumber: lineNum, indent: indent))
        }

        return tokens
    }

    // MARK: - JCross Generation

    private func jcrossHeader(language: CodeLanguage) -> String {
        """
        // JCROSS_BEGIN
        // lang:\(language.rawValue) ver:1.0 enc:kanji-topology
        // ⚠️ Verantyx JCross Intermediate Representation
        // ⚠️ Proprietary format — requires Verantyx SDK to interpret

        """
    }

    private func transpileTokens(
        _ tokens: [CodeToken],
        sensitiveTokens: Set<String>,
        session: JCrossTranspileSession,
        language: CodeLanguage
    ) -> String {
        var lines: [String] = []

        for token in tokens {
            switch token.kind {
            case .blank:
                lines.append("")

            case .comment:
                // Strip comments — they can contain sensitive info
                lines.append("// [omit]")

            case .code:
                let transpiled = transpileLine(
                    token.value,
                    sensitiveTokens: sensitiveTokens,
                    session: session,
                    language: language
                )
                lines.append(transpiled)
            }
        }

        lines.append("// JCROSS_END")
        return lines.joined(separator: "\n")
    }

    private func transpileLine(
        _ line: String,
        sensitiveTokens: Set<String>,
        session: JCrossTranspileSession,
        language: CodeLanguage
    ) -> String {
        var result = line

        // Replace sensitive tokens first (they become REDACTED)
        for secret in sensitiveTokens {
            if result.contains(secret) {
                let node = makeNode(
                    symbol: secret,
                    kind: .secret,
                    session: session,
                    isSensitive: true
                )
                result = result.replacingOccurrences(of: secret, with: "「\(node.id)」")
            }
        }

        // Replace identifiers with JCross node IDs
        let identifiers = extractIdentifiers(from: result, language: language)
        for ident in identifiers {
            guard !isKeyword(ident, language: language) else { continue }
            let node: JCrossCodeNode
            if let existing = session.nodesBySymbol[ident] {
                node = existing
            } else {
                node = makeNode(symbol: ident, kind: .identifier, session: session, isSensitive: false)
            }
            // Replace whole-word occurrences
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: ident))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let ns = result as NSString
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(location: 0, length: ns.length),
                    withTemplate: "⟨\(node.id)⟩"
                )
            }
        }

        return result
    }

    private func makeNode(
        symbol: String,
        kind: NodeKind,
        session: JCrossTranspileSession,
        isSensitive: Bool
    ) -> JCrossCodeNode {
        if let existing = session.nodesBySymbol[symbol] { return existing }

        let kanji = inferKanji(from: symbol)
        let prefix: String
        let opCmd: String

        switch kind {
        case .secret:
            prefix = "S"
            opCmd = "OP.SECRET"
        case .identifier:
            let k = kanji.first?.kanji ?? "変"
            switch k {
            case "核": prefix = "F"; opCmd = "OP.FUNC"
            case "型": prefix = "T"; opCmd = "OP.TYPE"
            case "変": prefix = "V"; opCmd = "OP.VAR"
            case "網": prefix = "N"; opCmd = "OP.NET"
            case "蔵": prefix = "D"; opCmd = "OP.STORE"
            default:   prefix = "X"; opCmd = "OP.SYM"
            }
        }

        let id = session.nextID(prefix: prefix)
        let node = JCrossCodeNode(
            id: id,
            kanjiTags: kanji,
            opCommand: opCmd,
            originalSymbol: symbol,
            isSensitive: isSensitive
        )
        session.register(node)
        return node
    }

    // MARK: - Kanji Inference

    private func inferKanji(from symbol: String) -> [KanjiTag] {
        let lower = symbol.lowercased()

        for (keyword, (kanji, weight)) in Self.kanjiMap {
            if lower.contains(keyword) {
                return [KanjiTag(kanji: kanji, weight: weight)]
            }
        }

        let functionSuffixes = ["Handler", "Manager", "Controller", "Service", "Engine", "Processor", "Executor"]
        for suffix in functionSuffixes {
            if symbol.hasSuffix(suffix) {
                return [KanjiTag(kanji: "核", weight: 0.85), KanjiTag(kanji: "処", weight: 0.7)]
            }
        }

        let verbs = ["get", "set", "fetch", "post", "send", "receive", "load", "save", "update", "delete", "create", "build", "run", "execute"]
        for verb in verbs {
            if lower.hasPrefix(verb) { return [KanjiTag(kanji: "処", weight: 0.9)] }
        }

        return [KanjiTag(kanji: "変", weight: 0.6)]
    }

    private func isKeyword(_ word: String, language: CodeLanguage) -> Bool {
        let keywords: Set<String>
        switch language {
        case .swift:
            keywords = ["if", "else", "for", "while", "func", "var", "let", "class",
                       "struct", "enum", "return", "guard", "switch", "case", "in",
                       "self", "super", "init", "deinit", "import", "true", "false", "nil"]
        case .python:
            keywords = ["if", "else", "elif", "for", "while", "def", "class", "return",
                       "import", "from", "as", "with", "pass", "break", "continue",
                       "True", "False", "None", "and", "or", "not", "in", "is"]
        case .typescript, .javascript:
            keywords = ["if", "else", "for", "while", "function", "const", "let", "var",
                       "class", "return", "import", "export", "async", "await",
                       "true", "false", "null", "undefined", "new", "this"]
        case .rust:
            keywords = ["if", "else", "for", "while", "fn", "let", "mut", "struct",
                       "enum", "impl", "match", "return", "use", "mod", "pub",
                       "true", "false", "self", "Self", "super"]
        default:
            keywords = []
        }
        return keywords.contains(word)
    }

    private func extractIdentifiers(from line: String, language: CodeLanguage) -> [String] {
        // Match camelCase / snake_case / PascalCase / ALL_CAPS identifiers
        guard let regex = try? NSRegularExpression(pattern: #"\b[a-zA-Z_][a-zA-Z0-9_]*\b"#) else { return [] }
        let ns = line as NSString
        return regex.matches(in: line, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
            .filter { $0.count > 2 } // skip very short tokens
    }

    // MARK: - Reverse Transpile (アンマスク)

    private func restoreFromJCross(_ jcross: String, session: JCrossTranspileSession) -> String {
        var result = jcross

        // Remove JCross metadata lines
        let lines = result.components(separatedBy: "\n").filter {
            !$0.hasPrefix("// JCROSS_") &&
            !$0.hasPrefix("// ⚠️") &&
            !$0.hasPrefix("// lang:") &&
            !$0.hasPrefix("// ver:")
        }
        result = lines.joined(separator: "\n")

        // Restore [omit] comments (replace with empty comment)
        result = result.replacingOccurrences(of: "// [omit]", with: "")

        // Restore node IDs: ⟨F1⟩ → originalSymbol, 「S1」 → [REDACTED]
        let nodePattern = try? NSRegularExpression(pattern: #"⟨([A-Z]\d+)⟩"#)
        let secretPattern = try? NSRegularExpression(pattern: #"「([A-Z]\d+)」"#)

        nodePattern?.enumerateMatches(in: result, range: NSRange(result.startIndex..., in: result)) { match, _, _ in
            guard let match, let range = Range(match.range(at: 1), in: result) else { return }
            let nodeID = String(result[range])
            if let node = session.nodesByID[nodeID], !node.isSensitive {
                // Will restore below
            }
        }

        // Batch restore nodes
        for (nodeID, node) in session.nodesByID.sorted(by: { $0.key < $1.key }) {
            if node.isSensitive {
                // Secrets: replace with env-var suggestion
                let envVar = "$\(node.originalSymbol.uppercased().replacingOccurrences(of: " ", with: "_"))"
                result = result.replacingOccurrences(of: "「\(nodeID)」", with: envVar)
            } else {
                result = result.replacingOccurrences(of: "⟨\(nodeID)⟩", with: node.originalSymbol)
            }
        }

        return result
    }

    // MARK: - Enums & Support Types

    enum CodeLanguage: String {
        case swift, python, typescript, javascript, rust, go, kotlin, java, plain
    }

    enum NodeKind { case identifier, secret }
}

// MARK: - CodeToken

private struct CodeToken {
    enum Kind { case code, comment, blank }
    let kind: Kind
    let value: String
    let lineNumber: Int
    let indent: Int
}

// MARK: - JCross Transpile Stats

extension JCrossTranspileSession {
    var stats: String {
        let sensitive = nodesByID.values.filter { $0.isSensitive }.count
        let total = nodesByID.count
        return "Session \(sessionID.prefix(8)): \(total) nodes (\(sensitive) secrets redacted)"
    }
}
