import Foundation
import CryptoKit

// MARK: - JCrossSchema
//
// セッション単位でランダム生成される「JCross 方言（Dialect）」。
// 毎回のリクエストで完全に異なる記号体系・トポロジーマップ・OP名を使用する。
//
// セキュリティ設計:
//   1. ランダム区切り文字     — LLMが変数として認識できるように _JCROSS_, __node_ 等の識別子形式を使用
//   2. ランダム漢字プール     — 2000字から8字をランダム選択してカテゴリに割り当て
//   3. ランダム OP 名         — "OP.FUNC" ではなく "KZ_NODE_A", "BM_VECTOR_7" 等
//   4. ランダム ノード ID形式 — "F1" ではなく "FN_07", "TY_93" 等ランダム接頭辞
//   5. ノイズノード注入       — 偽のノードをランダムに挿入（解析妨害）
//   6. セッション署名         — BLAKE2b でセッション整合性を検証
//
// 外部 AI は「今回だけの方言のルール」を system prompt で教えられる。
// 学習データになっても次セッションでは完全に無効。

struct JCrossSchema: Codable {

    // MARK: - Schema Identity
    let sessionID: String
    let createdAt: Date
    let schemaVersion: Int               // スキーマのバージョン識別子

    // MARK: - Delimiter Pairs (ランダム括弧ペア)
    let nodeOpen: String                 // default: _JCROSS_  → ランダム: _AST_, __node_, _TOKEN_ 等
    let nodeClose: String
    let secretOpen: String               // シークレット用 括弧
    let secretClose: String
    let tagOpen: String                  // カテゴリタグ用
    let tagClose: String

    // MARK: - Symbol Maps
    let kanjiCategoryMap: [String: String]  // 意味カテゴリ → ランダム漢字/記号
    //   "function" → "縁", "type" → "墟", "variable" → "礫" 等

    let opNameMap: [String: String]         // 標準 OP 名 → ランダム名
    //   "OP.FUNC" → "KZ.NODE_α", "OP.TYPE" → "BM.SHELL_7" 等

    let nodePrefixMap: [String: String]     // 種別接頭辞 → ランダム接頭辞
    //   "F" (function) → "FN_", "T" (type) → "TY_" 等

    // MARK: - Noise Config
    let noiseLevel: Int                  // 0: 無し, 1: 軽微, 2: 中程度, 3: 強
    let noiseNodeIDs: [String]           // 偽ノードID一覧（復元時に除去）

    // MARK: - Instructions for LLM
    /// このスキーマを LLM に教えるための system prompt セクション
    func schemaInstructions() -> String {
        let opExamples = opNameMap.prefix(4).map { k, v in "  \(k) → \(v)" }.joined(separator: "\n")
        let kanjiExamples = kanjiCategoryMap.prefix(4).map { k, v in "  \(k): '\(v)'" }.joined(separator: "\n")

        return """
        ━━━━ SESSION SCHEMA (ONE-TIME USE) ━━━━
        Schema ID: \(sessionID.prefix(8))
        This schema is uniquely generated for THIS request only.
        Any prior knowledge of JCross format is INVALID for this session.

        [Delimiter Rules]
        • Identifier nodes: \(nodeOpen)ID\(nodeClose)  (e.g. \(nodeOpen)\(nodePrefixMap["F"] ?? "FN_")1\(nodeClose))
        • Secret/redacted: \(secretOpen)ID\(secretClose) — NEVER restore these
        • Category tags: \(tagOpen)SYMBOL:weight\(tagClose)

        [Category Symbols (THIS SESSION ONLY)]
        \(kanjiExamples)

        [Command Names (THIS SESSION ONLY)]
        \(opExamples)

        [Noise Nodes] (ignore these IDs — they are decoys):
        \(noiseNodeIDs.prefix(5).joined(separator: ", "))

        RULES:
        1. Preserve ALL \(nodeOpen)ID\(nodeClose) tokens EXACTLY
        2. \(secretOpen)ID\(secretClose) tokens = security redactions, output as-is
        3. Category tags \(tagOpen)...\(tagClose) must remain intact
        4. Schema expires after this response — never cache or reuse
        5. IMPORTANT: When declaring NEW variables or functions, use standard English names. Do NOT use JCross format (like \(nodeOpen)ID\(nodeClose)) for your own additions.
        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        """
    }
}

// MARK: - JCrossSchemaGenerator

@MainActor
final class JCrossSchemaGenerator {

    // MARK: - Kanji Pool (2136 常用漢字 + 特殊記号から意味グループ別にサンプリング)

    /// 意味カテゴリ別の候補漢字プール
    private static let kanjiPools: [String: [String]] = [
        "function": ["核","覇","焦","錬","弧","縁","煌","礎","凛","雄","彩","粋","碑","凱","傑","嵐","巌","廉","燦","曠"],
        "type":     ["殻","墟","礎","廓","廊","廂","廬","廡","庖","庠","廩","廟","庭","廨","廳","庵","庸","廱","廴","廷"],
        "variable": ["礫","塵","粒","滴","沫","泡","霧","霞","霾","雰","露","霜","霪","霰","靄","霡","霤","霮","霢","霩"],
        "network":  ["網","縺","絡","糸","縁","絢","綾","紗","紬","縫","紐","組","紋","絵","繍","繕","縞","緞","緋","緯"],
        "storage":  ["蔵","庫","匣","箱","筐","函","匱","匾","匯","匳","匴","匵","匶","匷","匸","匹","区","医","匼","匽"],
        "secret":   ["鍵","錠","封","禁","秘","隠","蔽","伏","潜","沈","暗","冥","玄","幽","奥","深","底","淵","渕","窟"],
        "flow":     ["流","脈","漂","渦","潤","湧","滲","滴","漂","浸","滾","漕","澎","濫","泳","泡","浮","游","涌","浪"],
        "process":  ["処","業","技","術","法","式","道","策","計","謀","図","案","要","項","則","節","律","格","規","型"],
    ]

    /// LLMがAST構造を破壊しないよう、有効な識別子（変数名）として扱える文字列ペアに変更
    private static let delimiterPool: [(open: String, close: String)] = [
        ("_JCROSS_", "_"), ("_VERANTYX_", "_"), ("_ASTNODE_", "_"), ("_OPAQUE_", "_"), ("__jcross_", "__"),
        ("_SYM_", "_"), ("__node_", "__"), ("_TOKEN_", "_"), ("__ast_", "__"), ("_ID_", "_")
    ]

    /// ランダム OP 名ベース
    private static let opNameBases = [
        "KZ", "BM", "XR", "VΩ", "ΞΛ", "∂Σ", "ΔΘ", "ΨΦ", "ΓΞ", "ΩΛ",
        "ZK", "YR", "QX", "WΔ", "NΨ", "RΓ", "TΩ", "UΦ", "IΞ", "OΛ"
    ]

    private static let opSuffixes = [
        "NODE", "VECTOR", "BLOCK", "SHELL", "FRAME", "MATRIX", "TENSOR",
        "STREAM", "BUFFER", "STACK", "QUEUE", "HEAP", "GRAPH", "TREE"
    ]

    private static let alphaAlphabet = ["A","B","C","D","E","F","G","H","X","Y","Z","V","W","K","L","M"]

    // MARK: - Generate Schema

    func generate(noiseLevel: Int = 2) -> JCrossSchema {
        var rng = SystemRandomNumberGenerator()

        // 1. ランダム区切り文字ペアを3組選択（重複なし）
        let shuffledDelims = Self.delimiterPool.shuffled(using: &rng)
        let nodeDelim   = shuffledDelims[0]
        let secretDelim = shuffledDelims[1]
        let tagDelim    = shuffledDelims[2]

        // 2. 漢字カテゴリマップ生成
        var kanjiCategoryMap: [String: String] = [:]
        for (category, pool) in Self.kanjiPools {
            let chosen = pool.shuffled(using: &rng).first ?? pool[0]
            kanjiCategoryMap[category] = chosen
        }

        // 3. OP 名マップ生成
        let categories = ["function", "type", "variable", "network", "storage", "flow", "process", "secret"]
        var opNameMap: [String: String] = [:]
        let standardOps = ["OP.FUNC", "OP.TYPE", "OP.VAR", "OP.NET", "OP.STORE", "OP.FLOW", "OP.PROC", "OP.SECRET"]
        for (stdOp, category) in zip(standardOps, categories) {
            let base = Self.opNameBases.randomElement(using: &rng) ?? "KZ"
            let suffix = Self.opSuffixes.randomElement(using: &rng) ?? "NODE"
            let alpha = Self.alphaAlphabet.randomElement(using: &rng) ?? "A"
            let num = Int.random(in: 1...99, using: &rng)
            opNameMap[stdOp] = "\(base)_\(suffix)_\(alpha)\(num)"
        }

        // 4. ノード ID 接頭辞マップ生成 (漢字トポロジーによるセマンティック注入)
        // 抽象化されたコードでも、LLMが「これは関数だ」「これは変数だ」と推論しやすくするため、
        // 単なるランダム英字ではなく、漢字をプレフィックスとして使う（例: _JCROSS_核_1_）
        var nodePrefixMap: [String: String] = [:]
        nodePrefixMap["F"] = "\(kanjiCategoryMap["function"] ?? "核")_"
        nodePrefixMap["T"] = "\(kanjiCategoryMap["type"] ?? "型")_"
        nodePrefixMap["V"] = "\(kanjiCategoryMap["variable"] ?? "変")_"
        nodePrefixMap["N"] = "\(kanjiCategoryMap["network"] ?? "網")_"
        nodePrefixMap["D"] = "\(kanjiCategoryMap["storage"] ?? "蔵")_"
        nodePrefixMap["X"] = "\(kanjiCategoryMap["process"] ?? "処")_"
        nodePrefixMap["S"] = "\(kanjiCategoryMap["secret"] ?? "秘")_"

        // 5. ノイズノード生成
        let noiseCount = [0, 3, 8, 15][min(noiseLevel, 3)]
        let noiseNodeIDs: [String] = (0..<noiseCount).map { _ in
            let g1 = Self.alphaAlphabet.randomElement(using: &rng) ?? "A"
            let g2 = Self.alphaAlphabet.randomElement(using: &rng) ?? "B"
            let n  = Int.random(in: 100...999, using: &rng)
            return "\(g1)\(g2)_\(n)"
        }

        // 6. スキーマバージョン (UNIX timestamp ベース)
        let schemaVersion = Int(Date().timeIntervalSince1970)

        return JCrossSchema(
            sessionID: UUID().uuidString,
            createdAt: Date(),
            schemaVersion: schemaVersion,
            nodeOpen: nodeDelim.open,
            nodeClose: nodeDelim.close,
            secretOpen: secretDelim.open,
            secretClose: secretDelim.close,
            tagOpen: tagDelim.open,
            tagClose: tagDelim.close,
            kanjiCategoryMap: kanjiCategoryMap,
            opNameMap: opNameMap,
            nodePrefixMap: nodePrefixMap,
            noiseLevel: noiseLevel,
            noiseNodeIDs: noiseNodeIDs
        )
    }

    // MARK: - Schema Fingerprint (セッション固有の識別子)

    func fingerprint(of schema: JCrossSchema) -> String {
        let input = "\(schema.sessionID)\(schema.schemaVersion)\(schema.nodeOpen)\(schema.secretOpen)"
        let data = Data(input.utf8)
        let hash = SHA256.hash(data: data)
        return hash.compactMap { String(format: "%02x", $0) }.joined().prefix(16).description
    }
}

// MARK: - PolymorphicJCrossTranspiler
//
// JCrossCodeTranspiler のポリモーフィック対応版。
// セッションごとに異なるスキーマで変換する。

@MainActor
final class PolymorphicJCrossTranspiler: ObservableObject {

    static let shared = PolymorphicJCrossTranspiler()

    @Published var currentSchema: JCrossSchema?
    @Published var isTranspiling = false

    private let schemaGenerator = JCrossSchemaGenerator()
    private let nerEngine: any BitNetTranspilerInterface

    // Schema → Session mapping
    private var schemaSessions: [String: (schema: JCrossSchema, nodeMap: [String: String], reverseMap: [String: String])] = [:]

    struct JCrossSchemaSessionData: Codable {
        let schema: JCrossSchema
        let nodeMap: [String: String]
        let reverseMap: [String: String]
    }

    func getSessionData(for schemaID: String) -> JCrossSchemaSessionData? {
        guard let session = schemaSessions[schemaID] else { return nil }
        return JCrossSchemaSessionData(schema: session.schema, nodeMap: session.nodeMap, reverseMap: session.reverseMap)
    }

    func restoreSession(from data: JCrossSchemaSessionData) {
        schemaSessions[data.schema.sessionID] = (schema: data.schema, nodeMap: data.nodeMap, reverseMap: data.reverseMap)
    }

    /// NER エンジンの優先順位:
    ///   1. OllamaNEREngine (ローカル Ollama が起動中の場合)
    ///   2. BitNetNEREngine (bitnet.cpp がインストール済みの場合)
    ///   3. RuleBaseNEREngine (フォールバック)
    private init(nerEngine: (any BitNetTranspilerInterface)? = nil) {
        if let provided = nerEngine {
            self.nerEngine = provided
        } else if let config = BitNetConfig.load(), config.isValid {
            self.nerEngine = BitNetNEREngine(config: config)
        } else {
            // Ollama は非同期で確認するため、起動時はルールベースを使い
            // OllamaNEREngineManager が ready になったら差し替える
            self.nerEngine = OllamaNEREngine()  // Ollama が落ちていれば内部でフォールバック
        }
    }

    // MARK: - Transpile with Polymorphic Schema

    /// ソースコード → ランダムスキーマ JCross 変換
    /// Returns: (jcrossCode, schemaID, systemPromptSection)
    func transpile(
        _ source: String,
        language: JCrossCodeTranspiler.CodeLanguage,
        noiseLevel: Int = 2
    ) async -> (jcross: String, schemaID: String, schemaInstructions: String) {

        isTranspiling = true
        defer { isTranspiling = false }

        // 1. 新しいスキーマを生成
        let schema = schemaGenerator.generate(noiseLevel: noiseLevel)
        currentSchema = schema

        // 2. NER でセンシティブ識別子を抽出
        let sensitiveTokens = Set(await nerEngine.extractSensitiveIdentifiers(from: source))

        let result = await Task.detached(priority: .userInitiated) {
            // 3. 識別子抽出・マッピング構築
            let identifiers = Self.extractAllIdentifiers(from: source)
            var nodeMap: [String: String] = [:]      // realSymbol → nodeID
            var reverseMap: [String: String] = [:]   // nodeID → realSymbol

            var counters: [String: Int] = [:]
            func nextID(prefix: String) -> String {
                let n = (counters[prefix] ?? 0) + 1
                counters[prefix] = n
                let schemaPrefix = schema.nodePrefixMap[prefix] ?? prefix
                return "\(schemaPrefix)\(n)"
            }

            for ident in identifiers {
                if nodeMap[ident] != nil { continue }
                let isSensitive = sensitiveTokens.contains(ident)
                let prefix = isSensitive ? "S" : Self.inferPrefix(from: ident)
                let nodeID = nextID(prefix: prefix)
                nodeMap[ident] = nodeID
                if !isSensitive {
                    reverseMap[nodeID] = ident
                }
            }

            // 4. 変換実行
            let jcrossLines = Self.convertToJCross(
                source: source,
                schema: schema,
                nodeMap: nodeMap,
                sensitiveTokens: sensitiveTokens
            )

            // 5. ノイズノード注入
            let noisyJCross = Self.injectNoise(into: jcrossLines, schema: schema)
            let jcrossOutput = noisyJCross.joined(separator: "\n")
            
            return (jcrossOutput, nodeMap, reverseMap)
        }.value

        // 6. セッション保存
        schemaSessions[schema.sessionID] = (schema: schema, nodeMap: result.1, reverseMap: result.2)

        return (result.0, schema.sessionID, schema.schemaInstructions())
    }

    // MARK: - Reverse Transpile

    func reverseTranspile(_ jcross: String, schemaID: String) -> String? {
        guard let session = schemaSessions[schemaID] else { return nil }
        let schema = session.schema
        let reverseMap = session.reverseMap

        var result = jcross

        // ヘッダー除去
        result = result.components(separatedBy: "\n")
            .filter { !$0.hasPrefix("// POLYMORPHIC_JCROSS") && !$0.hasPrefix("// schema:") }
            .joined(separator: "\n")

        // ノイズノード除去
        for noiseID in schema.noiseNodeIDs {
            let noiseToken = "\(schema.nodeOpen)\(noiseID)\(schema.nodeClose)"
            result = result.replacingOccurrences(of: noiseToken, with: "")
        }

        // シークレットを環境変数参照に置換
        // 「秘密ID」→ ENV_VAR_REFERENCE (平文復元しない)
        if let secretRegex = try? NSRegularExpression(
            pattern: "\(NSRegularExpression.escapedPattern(for: schema.secretOpen))(.*?)\(NSRegularExpression.escapedPattern(for: schema.secretClose))"
        ) {
            result = secretRegex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$ENV_SECRET_$1"
            )
        }

        // 識別子ノードを元のシンボルに復元
        // 長い ID から順に置換（部分マッチ防止）
        for (nodeID, realSymbol) in reverseMap.sorted(by: { $0.key.count > $1.key.count }) {
            let token = "\(schema.nodeOpen)\(nodeID)\(schema.nodeClose)"
            result = result.replacingOccurrences(of: token, with: realSymbol)
        }

        // タグ残留物をクリーン
        let tagPattern = "\(NSRegularExpression.escapedPattern(for: schema.tagOpen))(.*?)\(NSRegularExpression.escapedPattern(for: schema.tagClose))"
        if let tagRegex = try? NSRegularExpression(pattern: tagPattern) {
            result = tagRegex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Conversion Core

    nonisolated private static func convertToJCross(
        source: String,
        schema: JCrossSchema,
        nodeMap: [String: String],
        sensitiveTokens: Set<String>
    ) -> [String] {

        var lines: [String] = []
        lines.append("// POLYMORPHIC_JCROSS_BEGIN")
        lines.append("// schema:\(schema.sessionID.prefix(8)) ver:\(schema.schemaVersion)")
        lines.append("// ⚠️ One-time schema — expires after response")
        lines.append("")

        let sourceLines = source.components(separatedBy: "\n")
        for line in sourceLines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") ||
               line.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
                lines.append("// [metadata-stripped]")
                continue
            }

            var converted = line

            // センシティブトークンを先に置換（シークレット括弧で囲む）
            for (real, nodeID) in nodeMap {
                if sensitiveTokens.contains(real) && converted.contains(real) {
                    converted = converted.replacingOccurrences(
                        of: real,
                        with: "\(schema.secretOpen)\(nodeID)\(schema.secretClose)"
                    )
                }
            }

            // 通常識別子をノード括弧で置換（長い順）
            let sortedMap = nodeMap.filter { !sensitiveTokens.contains($0.key) }
                .sorted { $0.key.count > $1.key.count }

            for (real, nodeID) in sortedMap {
                if converted.contains(real) {
                    // カテゴリタグを生成
                    let category = inferCategory(from: real)
                    let kanjiSym = schema.kanjiCategoryMap[category] ?? "変"
                    let tag = "\(schema.tagOpen)\(kanjiSym):1.0\(schema.tagClose)"
                    let nodeToken = "\(schema.nodeOpen)\(nodeID)\(schema.nodeClose)"

                    // OP コマンドを生成（行の先頭で関数定義の場合のみ）
                    let isDefLine = line.trimmingCharacters(in: .whitespaces).hasPrefix("func ") ||
                                   line.trimmingCharacters(in: .whitespaces).hasPrefix("def ")
                    if isDefLine && category == "function" {
                        let opName = schema.opNameMap["OP.FUNC"] ?? "OP.FUNC"
                        converted = converted.replacingOccurrences(
                            of: real,
                            with: "\(tag)\(opName)(\(nodeToken))"
                        )
                    } else {
                        converted = converted.replacingOccurrences(of: real, with: "\(tag)\(nodeToken)")
                    }
                }
            }

            lines.append(converted)
        }

        lines.append("// POLYMORPHIC_JCROSS_END")
        return lines
    }

    // MARK: - Noise Injection

    nonisolated private static func injectNoise(into lines: [String], schema: JCrossSchema) -> [String] {
        guard schema.noiseLevel > 0, !schema.noiseNodeIDs.isEmpty else { return lines }

        var result = lines
        var noiseIterator = schema.noiseNodeIDs.makeIterator()

        // ランダムな位置にノイズノードをコメントとして挿入
        let insertCount = min(schema.noiseNodeIDs.count, schema.noiseLevel * 3)
        for _ in 0..<insertCount {
            guard let noiseID = noiseIterator.next() else { break }
            let pos = Int.random(in: 2..<max(3, result.count - 1))
            let noiseKanji = schema.kanjiCategoryMap.values.randomElement() ?? "変"
            let noiseTag = "\(schema.tagOpen)\(noiseKanji):0.\(Int.random(in: 1...9))\(schema.tagClose)"
            let noiseToken = "\(schema.nodeOpen)\(noiseID)\(schema.nodeClose)"
            let noiseLine = "// \(noiseTag)\(noiseToken) [decoy-metadata]"
            result.insert(noiseLine, at: min(pos, result.count))
        }

        return result
    }

    // MARK: - Identifier Extraction & Analysis

    nonisolated private static func extractAllIdentifiers(from source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\b[a-zA-Z_][a-zA-Z0-9_]{2,}\b"#) else { return [] }
        let ns = source as NSString
        return Array(Set(
            regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
                .map { ns.substring(with: $0.range) }
                .filter { !isSwiftKeyword($0) }
        ))
    }

    nonisolated private static func inferPrefix(from symbol: String) -> String {
        let lower = symbol.lowercased()
        if lower.hasPrefix("get") || lower.hasPrefix("set") || lower.hasPrefix("fetch") ||
           lower.hasSuffix("Handler") || lower.hasSuffix("Manager") { return "F" }
        if symbol.first?.isUppercase == true { return "T" }  // PascalCase = Type
        return "V"
    }

    nonisolated private static func inferCategory(from symbol: String) -> String {
        let lower = symbol.lowercased()
        if lower.contains("key") || lower.contains("secret") || lower.contains("token") || lower.contains("password") { return "secret" }
        if lower.contains("url") || lower.contains("http") || lower.contains("api") || lower.contains("request") { return "network" }
        if lower.contains("file") || lower.contains("save") || lower.contains("load") || lower.contains("cache") { return "storage" }
        if lower.hasPrefix("get") || lower.hasPrefix("fetch") || lower.hasPrefix("set") ||
           lower.hasSuffix("er") { return "process" }
        if symbol.first?.isUppercase == true { return "type" }
        if lower.contains("if") || lower.contains("for") || lower.contains("while") { return "flow" }
        return "variable"
    }

    nonisolated private static func isSwiftKeyword(_ word: String) -> Bool {
        let keywords: Set<String> = [
            "if", "else", "for", "while", "func", "var", "let", "class", "struct",
            "enum", "return", "guard", "switch", "case", "in", "self", "super",
            "init", "deinit", "import", "true", "false", "nil", "async", "await",
            "actor", "protocol", "extension", "override", "static", "final",
            "private", "public", "internal", "open", "mutating", "lazy", "weak",
            "unowned", "throws", "rethrows", "try", "catch", "defer", "break",
            "continue", "where", "some", "any", "nonisolated", "consuming"
        ]
        return keywords.contains(word)
    }
}

// MARK: - Schema Rotation Policy

/// スキーマをどのような条件でローテーションするかを定義
enum SchemaRotationPolicy {
    case perRequest        // リクエストごとに毎回生成（最高セキュリティ）
    case perFile           // ファイルごとに生成
    case perSession        // IDE セッションごとに生成
    case timeBased(seconds: TimeInterval)  // 時間ベース（例: 300秒ごと）

    func shouldRotate(lastGenerated: Date, requestCount: Int) -> Bool {
        switch self {
        case .perRequest:
            return true
        case .perFile:
            return requestCount > 0
        case .perSession:
            return false  // セッション開始時に1回だけ生成
        case .timeBased(let interval):
            return Date().timeIntervalSince(lastGenerated) > interval
        }
    }
}
