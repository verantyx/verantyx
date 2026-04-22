import Foundation

// MARK: - AgentTool
// Tool definitions that the AI can emit in its response.
// Parsed from a clean bracket-based syntax that local LLMs can follow reliably.

enum AgentTool {
    // ── File system ──────────────────────────────────────────────────────────
    case makeDir(String)
    case writeFile(path: String, content: String)
    case runCommand(String)
    case setWorkspace(String)
    case done(message: String)
    case readFile(String)
    case listDir(String)                          // NEW: tree-style directory listing
    case editLines(path: String,                  // NEW: partial line-range replacement
                   startLine: Int,
                   endLine: Int,
                   newContent: String)
    // ── Web / Grounding ──────────────────────────────────────────────────────
    case browse(url: String)
    case search(query: String)
    case searchMulti(query: String)               // NEW: parallel top-3 URLs + synthesis
    case evalJS(script: String)
    case openSafari(url: String)
    case openChrome(url: String)
    // ── JCross Memory ────────────────────────────────────────────────────────
    case jcrossQuery(String)                      // NEW: recall from CortexEngine
    case jcrossStore(key: String, value: String)  // NEW: remember to CortexEngine
    // ── Git / Safety ─────────────────────────────────────────────────────────
    case gitCommit(String)                        // NEW: git add -A && git commit -m
    case gitRestore(String)                       // NEW: git restore <path>
    case askHuman(String)                         // NEW: Yield — request human input
    // ── Self-Fix pipeline ────────────────────────────────────────────────────
    case applyPatch(relativePath: String, content: String)
    case buildIDE
    case restartIDE
}

// MARK: - AgentToolCall (result wrapper)

struct AgentToolCall: Identifiable {
    let id = UUID()
    let tool: AgentTool
    var result: String = ""
    var succeeded: Bool = true

    var displayLabel: String {
        switch tool {
        case .makeDir(let p):               return "mkdir \(p)"
        case .writeFile(let p, _):          return "write → \(p)"
        case .runCommand(let cmd):          return "$ \(cmd)"
        case .setWorkspace(let p):          return "workspace: \(p)"
        case .done(let m):                  return "✓ \(m)"
        case .readFile(let p):              return "read ← \(p)"
        case .listDir(let p):               return "ls \(p)"
        case .editLines(let p, let s, let e, _): return "edit \(p):\(s)-\(e)"
        case .browse(let url):              return "🌐 browse \(url)"
        case .search(let q):               return "🔍 search: \(q)"
        case .searchMulti(let q):          return "🔍× search: \(q)"
        case .evalJS(let s):               return "⚡ eval_js: \(s.prefix(40))"
        case .openSafari(let url):         return "🧡 safari: \(url)"
        case .openChrome(let url):         return "🟢 chrome: \(url)"
        case .jcrossQuery(let q):          return "🧠 jcross_query: \(q)"
        case .jcrossStore(let k, _):       return "🧠 jcross_store: \(k)"
        case .gitCommit(let m):            return "git commit: \(m.prefix(40))"
        case .gitRestore(let p):           return "git restore: \(p)"
        case .askHuman(let q):             return "⏸ ask_human: \(q.prefix(40))"
        case .applyPatch(let p, _):        return "📦 patch → \(p)"
        case .buildIDE:                    return "🔨 xcodebuild"
        case .restartIDE:                  return "🔄 restart IDE"
        }
    }
}

// MARK: - AgentToolParser

struct AgentToolParser {

    // MARK: System prompt injected before every agent turn
    static let toolInstructions = """
    You are VerantyxAgent, an autonomous AI coding assistant with persistent spatial memory.
    You have access to these tools — use them to complete tasks:

    ── FILE SYSTEM ──────────────────────────────────────────────────────
    [LIST_DIR: path]              — list directory contents (tree style)
    [READ: path/to/file]          — read file contents
    [MKDIR: path/to/directory]    — create a directory
    [WRITE: path/to/file.ext]     — write entire file
    ```
    ... file content ...
    ```
    [/WRITE]
    [EDIT_LINES: path/to/file]    — replace specific line range
    ```
    START_LINE: 42
    END_LINE: 48
    ---
    new code replacing lines 42-48
    ```
    [/EDIT_LINES]
    [RUN: command]                — run a shell command
    [WORKSPACE: /absolute/path]   — set/open workspace folder
    [DONE: summary message]       — signal task completion

    ── WEB GROUNDING ─────────────────────────────────────────────────────
    [SEARCH_MULTI: query terms]   — fetch top 3 URLs in parallel, synthesize
    [SEARCH: query terms]         — single DuckDuckGo search
    [BROWSE: https://url]         — fetch URL (WebKit, returns Markdown)
    [EVAL_JS: javascript code]    — run JS in current browser page
    [SAFARI: https://url]         — open in Safari (uses your cookies)
    [CHROME: https://url]         — open in Chrome (uses your cookies)

    ── MEMORY (JCross Spatial) ────────────────────────────────────────────
    [JCROSS_QUERY: search terms]  — recall relevant past memories
    [JCROSS_STORE: key=value]     — save important fact to long-term memory

    ── VERSION CONTROL ─────────────────────────────────────────────────────
    [GIT_COMMIT: commit message]  — git add -A && git commit
    [GIT_RESTORE: path/or/.]      — git restore (undo uncommitted changes)

    ── HUMAN IN THE LOOP ────────────────────────────────────────────────────
    [ASK_HUMAN: your question]    — pause and ask the user for input/approval

    ── SELF-FIX (only in Self-Fix mode) ─────────────────────────────────────
    [APPLY_PATCH: Sources/Path/File.swift]
    ```swift
    // complete new file content
    ```
    [/APPLY_PATCH]
    [BUILD_IDE]                   — run xcodebuild; returns errors or BUILD SUCCEEDED
    [RESTART_IDE]                 — show restart dialog to user

    ══════════════════════════════════════════════════════════════════════
    ⚡ REACT LOOP PROTOCOL — follow this 4-phase pattern for every task:

    Phase 1 OBSERVE (never skip):
      1. [JCROSS_QUERY] — check if related work exists in memory
      2. [LIST_DIR]     — understand structure before touching files
      3. [READ]         — read the specific file(s) you'll modify
      4. <think>plan: what to change, why, which lines</think>

    Phase 2 ACT + VERIFY (loop until clean):
      1. [EDIT_LINES] for small changes / [APPLY_PATCH] for full rewrites
      2. [RUN: swift build] or [BUILD_IDE] to verify compilation
      3. If errors → read error, fix, repeat from step 1

    Phase 3 EVOLVE (Self-Fix only, after BUILD SUCCEEDED):
      1. [GIT_COMMIT: "describe change"]
      2. [BUILD_IDE]
      3. [RESTART_IDE]

    Phase 4 CONSOLIDATE (always after task complete):
      1. [JCROSS_STORE: key=value] — save key findings to memory
      2. [DONE: summary]

    ══════════════════════════════════════════════════════════════════════
    ⚡ GROUNDING RULE — MANDATORY:
    Your training data has a cutoff. For these topics, ALWAYS search first:
      • Anything with "latest", "current", "2024", "2025" in the question
      • Version numbers, API names, framework releases
      • Error messages you don't immediately recognize
      • External service status, pricing, documentation URLs
    → Use [SEARCH_MULTI:] for best results. Never guess — search instead.

    ⚡ EDIT SAFETY RULE:
    Before any [APPLY_PATCH] or [EDIT_LINES], run [GIT_COMMIT] to save current state.
    If your edit breaks the build → use [GIT_RESTORE: .] to undo instantly.

    ⚡ HUMAN MODE RULE:
    In Human Mode, before deleting files, making irreversible changes, or when stuck:
    → Use [ASK_HUMAN: your question] to pause and get user guidance.

    ══════════════════════════════════════════════════════════════════════
    EXAMPLE — user says "什么是 Swift 6 の Concurrency の変更点?":
    <think>This is about latest Swift version — I need to search, not guess.</think>
    [SEARCH_MULTI: Swift 6 concurrency changes 2024]
    [JCROSS_STORE: swift6_concurrency=Swift 6 adds strict concurrency checking by default]
    Swift 6 では厳密な同時実行チェックがデフォルトになりました。
    [DONE: Answered from live web search]

    EXAMPLE — user says "UIの幅を固定して":
    [JCROSS_QUERY: ResizableSplit width UI]
    [LIST_DIR: Sources/Verantyx/Views]
    [READ: Sources/Verantyx/Views/ResizableSplit.swift]
    <think>Line 45-52 contains the drag handler. I'll fix it there.</think>
    [GIT_COMMIT: backup before ResizableSplit fix]
    [EDIT_LINES: Sources/Verantyx/Views/ResizableSplit.swift]
    ```
    START_LINE: 45
    END_LINE: 52
    ---
        .frame(width: 280)  // fixed width
    ```
    [/EDIT_LINES]
    [BUILD_IDE]
    [JCROSS_STORE: resizablesplit_fix=Fixed width to 280 at line 45]
    [DONE: Width fixed]
    """

    // MARK: - Main parse method

    static func parse(from text: String) -> (toolCalls: [AgentTool], cleanText: String) {
        var tools: [AgentTool] = []
        var cleaned = text

        // ── 1. WRITE block ─────────────────────────────────────────────────
        let writePattern = #"\[WRITE:\s*([^\]]+)\]\s*```(?:\w+)?\n?([\s\S]*?)```\s*\[/WRITE\]"#
        if let regex = try? NSRegularExpression(pattern: writePattern) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches.reversed() {
                if let pathRange    = Range(match.range(at: 1), in: text),
                   let contentRange = Range(match.range(at: 2), in: text),
                   let fullRange    = Range(match.range, in: text) {
                    let path    = expandHome(String(text[pathRange]).trimmingCharacters(in: .whitespaces))
                    let content = String(text[contentRange])
                    tools.insert(.writeFile(path: path, content: content), at: 0)
                    cleaned = cleaned.replacingCharacters(in: fullRange, with: "")
                }
            }
        }

        // ── 2. APPLY_PATCH block ───────────────────────────────────────────
        let patchPattern = #"\[APPLY_PATCH:\s*([^\]]+)\]\s*```(?:\w+)?\n?([\s\S]*?)```\s*\[/APPLY_PATCH\]"#
        if let regex = try? NSRegularExpression(pattern: patchPattern) {
            let matches = regex.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned))
            for match in matches.reversed() {
                if let pathRange    = Range(match.range(at: 1), in: cleaned),
                   let contentRange = Range(match.range(at: 2), in: cleaned),
                   let fullRange    = Range(match.range, in: cleaned) {
                    let path    = String(cleaned[pathRange]).trimmingCharacters(in: .whitespaces)
                    let content = String(cleaned[contentRange])
                    tools.insert(.applyPatch(relativePath: path, content: content), at: 0)
                    cleaned = cleaned.replacingCharacters(in: fullRange, with: "")
                }
            }
        }

        // ── 3. EDIT_LINES block ────────────────────────────────────────────
        let editPattern = #"\[EDIT_LINES:\s*([^\]]+)\]\s*```(?:\w+)?\n?([\s\S]*?)```\s*\[/EDIT_LINES\]"#
        if let regex = try? NSRegularExpression(pattern: editPattern) {
            let matches = regex.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned))
            for match in matches.reversed() {
                if let pathRange    = Range(match.range(at: 1), in: cleaned),
                   let contentRange = Range(match.range(at: 2), in: cleaned),
                   let fullRange    = Range(match.range, in: cleaned) {
                    let path    = String(cleaned[pathRange]).trimmingCharacters(in: .whitespaces)
                    let body    = String(cleaned[contentRange])
                    if let editTool = parseEditLines(path: path, body: body) {
                        tools.insert(editTool, at: 0)
                    }
                    cleaned = cleaned.replacingCharacters(in: fullRange, with: "")
                }
            }
        }

        // ── 4. Single-line tags ────────────────────────────────────────────
        let lines = cleaned.components(separatedBy: "\n")
        var resultLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if      let m = match(trimmed, pattern: #"^\[MKDIR:\s*([^\]]+)\]$"#) {
                tools.append(.makeDir(expandHome(m)))
            } else if let m = match(trimmed, pattern: #"^\[RUN:\s*([^\]]+)\]$"#) {
                tools.append(.runCommand(m))
            } else if let m = match(trimmed, pattern: #"^\[WORKSPACE:\s*([^\]]+)\]$"#) {
                tools.append(.setWorkspace(expandHome(m)))
            } else if let m = match(trimmed, pattern: #"^\[DONE[:\s]*([^\]]*)\]$"#) {
                tools.append(.done(message: m.isEmpty ? "Task complete." : m))
            } else if let m = match(trimmed, pattern: #"^\[READ:\s*([^\]]+)\]$"#) {
                tools.append(.readFile(expandHome(m)))
            } else if let m = match(trimmed, pattern: #"^\[LIST_DIR:\s*([^\]]+)\]$"#) {
                tools.append(.listDir(expandHome(m)))
            // ── Web ─────────────────────────────────────────────────────
            } else if let m = match(trimmed, pattern: #"^\[BROWSE:\s*([^\]]+)\]$"#) {
                tools.append(.browse(url: m))
            } else if let m = match(trimmed, pattern: #"^\[SEARCH_MULTI:\s*([^\]]+)\]$"#) {
                tools.append(.searchMulti(query: m))
            } else if let m = match(trimmed, pattern: #"^\[SEARCH:\s*([^\]]+)\]$"#) {
                tools.append(.search(query: m))
            } else if let m = match(trimmed, pattern: #"^\[EVAL_JS:\s*([^\]]+)\]$"#) {
                tools.append(.evalJS(script: m))
            } else if let m = match(trimmed, pattern: #"^\[SAFARI:\s*([^\]]+)\]$"#) {
                tools.append(.openSafari(url: m))
            } else if let m = match(trimmed, pattern: #"^\[CHROME:\s*([^\]]+)\]$"#) {
                tools.append(.openChrome(url: m))
            // ── JCross ──────────────────────────────────────────────────
            } else if let m = match(trimmed, pattern: #"^\[JCROSS_QUERY:\s*([^\]]+)\]$"#) {
                tools.append(.jcrossQuery(m))
            } else if let m = match(trimmed, pattern: #"^\[JCROSS_STORE:\s*([^=\]]+)=([^\]]*)\]$"#) {
                let parts = parseKV(trimmed)
                tools.append(.jcrossStore(key: parts.key, value: parts.value))
            // ── Git ──────────────────────────────────────────────────────
            } else if let m = match(trimmed, pattern: #"^\[GIT_COMMIT:\s*([^\]]+)\]$"#) {
                tools.append(.gitCommit(m))
            } else if let m = match(trimmed, pattern: #"^\[GIT_RESTORE:\s*([^\]]+)\]$"#) {
                tools.append(.gitRestore(m))
            // ── Human ────────────────────────────────────────────────────
            } else if let m = match(trimmed, pattern: #"^\[ASK_HUMAN:\s*([^\]]+)\]$"#) {
                tools.append(.askHuman(m))
            // ── Self-Fix ─────────────────────────────────────────────────
            } else if trimmed == "[BUILD_IDE]" {
                tools.append(.buildIDE)
            } else if trimmed == "[RESTART_IDE]" {
                tools.append(.restartIDE)
            } else {
                resultLines.append(line)
            }
        }

        cleaned = resultLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (tools, cleaned)
    }

    // MARK: - Helpers

    private static func parseEditLines(path: String, body: String) -> AgentTool? {
        // Body format:
        // START_LINE: 42
        // END_LINE: 48
        // ---
        // new content
        let parts = body.components(separatedBy: "---")
        guard parts.count >= 2 else { return nil }
        let header  = parts[0]
        let content = parts[1...].joined(separator: "---").trimmingCharacters(in: .whitespacesAndNewlines)

        var start = 0; var end = 0
        for line in header.components(separatedBy: "\n") {
            if line.hasPrefix("START_LINE:"), let v = Int(line.replacingOccurrences(of: "START_LINE:", with: "").trimmingCharacters(in: .whitespaces)) { start = v }
            if line.hasPrefix("END_LINE:"),   let v = Int(line.replacingOccurrences(of: "END_LINE:", with: "").trimmingCharacters(in: .whitespaces))   { end   = v }
        }
        guard start > 0, end >= start else { return nil }
        return .editLines(path: expandHome(path), startLine: start, endLine: end, newContent: content)
    }

    private static func parseKV(_ text: String) -> (key: String, value: String) {
        // [JCROSS_STORE: key=value]
        let inner = text.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .replacingOccurrences(of: "JCROSS_STORE:", with: "")
            .trimmingCharacters(in: .whitespaces)
        if let eq = inner.firstIndex(of: "=") {
            let key   = String(inner[inner.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(inner[inner.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            return (key, value)
        }
        return (inner, "")
    }

    private static func match(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text)
        else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespaces)
    }

    static func expandHome(_ path: String) -> String {
        if path.hasPrefix("~/") { return NSHomeDirectory() + path.dropFirst(1) }
        return path
    }

    static func stripArtifactTags(from text: String) -> String { text }
}

// MARK: - AgentToolExecutor

actor AgentToolExecutor {

    private let fileManager = FileManager.default

    func execute(_ tool: AgentTool, workspaceURL: URL?) async -> String {
        switch tool {

        // ── File system ───────────────────────────────────────────────────

        case .makeDir(let path):
            let url = resolve(path, workspace: workspaceURL)
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                return "✓ Created directory: \(url.path)"
            } catch { return "✗ mkdir failed: \(error.localizedDescription)" }

        case .writeFile(let path, let content):
            let url = resolve(path, workspace: workspaceURL)
            try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                return "✓ Wrote \(url.lastPathComponent) (\(content.components(separatedBy: "\n").count) lines)"
            } catch { return "✗ write failed for \(path): \(error.localizedDescription)" }

        case .runCommand(let cmd):
            return await runShell(cmd, workingDir: workspaceURL)

        case .setWorkspace(let path):
            return "✓ Workspace set to: \(path)"

        case .done(let msg):
            return "✓ \(msg)"

        case .readFile(let path):
            let url = resolve(path, workspace: workspaceURL)
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                return "FILE CONTENT (\(url.lastPathComponent)):\n\(content.prefix(6000))"
            }
            return "✗ Could not read: \(path)"

        case .listDir(let path):
            let url = resolve(path, workspace: workspaceURL)
            return buildDirectoryTree(url: url, depth: 0, maxDepth: 3)

        case .editLines(let path, let startLine, let endLine, let newContent):
            let url = resolve(path, workspace: workspaceURL)
            guard let original = try? String(contentsOf: url, encoding: .utf8) else {
                return "✗ Could not read file for editing: \(path)"
            }
            var lines = original.components(separatedBy: "\n")
            guard startLine >= 1, endLine <= lines.count, startLine <= endLine else {
                return "✗ Invalid line range \(startLine)-\(endLine) (file has \(lines.count) lines)"
            }
            let replacement = newContent.components(separatedBy: "\n")
            lines.replaceSubrange((startLine-1)...(endLine-1), with: replacement)
            let patched = lines.joined(separator: "\n")
            do {
                try patched.write(to: url, atomically: true, encoding: .utf8)
                return "✓ Edited \(url.lastPathComponent) lines \(startLine)-\(endLine) (\(replacement.count) replacement lines)"
            } catch { return "✗ Edit failed: \(error.localizedDescription)" }

        // ── Web / Grounding ───────────────────────────────────────────────

        case .browse(let url):
            let result = await WebSearchEngine.shared.browse(url: url, preferredSource: .verantyxBrowser)
            return "[WEB PAGE: \(result.url)]\n\(result.contextSnippet)\n[END WEB PAGE]"

        case .search(let query):
            let result = await WebSearchEngine.shared.search(query: query)
            // Auto-store in JCross (importance 0.7, zone near)
            let snippet = String(result.contextSnippet.prefix(200))
            await persistSearchResult(key: "web_\(query.prefix(30))", value: snippet)
            return "[SEARCH RESULTS for: \(query)]\nSource: \(result.url)\n\(result.contextSnippet)\n[END SEARCH RESULTS]"

        case .searchMulti(let query):
            return await executeSearchMulti(query: query)

        case .evalJS(let script):
            do {
                let result = try await BrowserBridge.shared.evalJS(script)
                return "[JS RESULT] \(result)"
            } catch { return "[JS ERROR] \(error.localizedDescription)" }

        case .openSafari(let url):
            let result = await WebSearchEngine.shared.browse(url: url, preferredSource: .safari)
            return "[SAFARI: \(result.url)]\n\(result.contextSnippet)\n[END SAFARI]"

        case .openChrome(let url):
            let result = await WebSearchEngine.shared.browse(url: url, preferredSource: .chrome)
            return "[CHROME: \(result.url)]\n\(result.contextSnippet)\n[END CHROME]"

        // ── JCross Memory ─────────────────────────────────────────────────

        case .jcrossQuery(let query):
            return await MainActor.run {
                guard let cortex = CortexEngine.shared else {
                    return "[JCROSS] Memory engine not available"
                }
                let nodes = cortex.recall(for: query, topK: 5)
                if nodes.isEmpty { return "[JCROSS] No memories found for: \(query)" }
                let lines = nodes.map { "• \($0.key): \($0.value)" }.joined(separator: "\n")
                return "[JCROSS MEMORY for: \(query)]\n\(lines)\n[END JCROSS]"
            }

        case .jcrossStore(let key, let value):
            await MainActor.run {
                CortexEngine.shared?.remember(key: key, value: value, importance: 0.8, zone: .near)
            }
            return "✓ Stored in JCross memory: \(key) = \(value.prefix(60))"

        // ── Git / Safety ──────────────────────────────────────────────────

        case .gitCommit(let message):
            let ws = workspaceURL?.path ?? NSHomeDirectory() + "/verantyx-cli/VerantyxIDE"
            return await runShell("git add -A && git commit -m '\(message.replacingOccurrences(of: "'", with: "\\'"))'",
                                   workingDir: URL(fileURLWithPath: ws))

        case .gitRestore(let path):
            let ws = workspaceURL?.path ?? NSHomeDirectory() + "/verantyx-cli/VerantyxIDE"
            return await runShell("git restore \(path)", workingDir: URL(fileURLWithPath: ws))

        case .askHuman(let question):
            // Emit as a system event — AgentLoop will pause and return to chat
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .agentAskHuman,
                    object: question
                )
            }
            return "ASK_HUMAN_POSTED: \(question)\n[PAUSED — waiting for human response]"

        // ── Self-Fix ──────────────────────────────────────────────────────

        case .applyPatch(let relativePath, let content):
            return await MainActor.run {
                let sanitized = SelfEvolutionEngine.stripCodeFences(from: content)
                SelfEvolutionEngine.shared.registerPatch(for: relativePath, newContent: sanitized)
                return "✅ PATCH_REGISTERED: \(relativePath) (\(sanitized.components(separatedBy: "\n").count) lines)"
            }

        case .buildIDE:
            return await runIDEBuild()

        case .restartIDE:
            await MainActor.run {
                NotificationCenter.default.post(name: .agentRequestsRestart, object: nil)
            }
            return "RESTART_REQUESTED: User will be asked to restart the app."
        }
    }

    // MARK: - SEARCH_MULTI: parallel top-3 URLs

    private func executeSearchMulti(query: String) async -> String {
        // Step 1: get search result page
        let primary = await WebSearchEngine.shared.search(query: query)
        let primaryText = primary.contextSnippet

        // Step 2: extract additional URLs from the search result
        let urls = extractURLs(from: primaryText, limit: 2)

        var parts: [String] = ["[Source 1: \(primary.url)]\n\(String(primaryText.prefix(800)))"]

        // Step 3: fetch additional URLs in parallel
        await withTaskGroup(of: (Int, String).self) { group in
            for (i, url) in urls.enumerated() {
                group.addTask {
                    let r = await WebSearchEngine.shared.browse(url: url, preferredSource: .verantyxBrowser)
                    return (i + 2, "[Source \(i+2): \(r.url)]\n\(String(r.contextSnippet.prefix(600)))")
                }
            }
            for await (_, text) in group {
                parts.append(text)
            }
        }

        let synthesis = parts.joined(separator: "\n---\n")

        // Auto-save to JCross
        let summary = String(primaryText.prefix(150))
        await persistSearchResult(key: "search_\(query.prefix(30))", value: summary)

        return """
        [SEARCH_MULTI RESULTS for: \(query)]
        \(synthesis)
        [END SEARCH_MULTI]
        Synthesize the above sources to answer the question.
        """
    }

    private func extractURLs(from text: String, limit: Int) -> [String] {
        let pattern = #"https?://[^\s\]<"')>]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return Array(matches.prefix(limit).compactMap { m -> String? in
            Range(m.range, in: text).map { String(text[$0]) }
        })
    }

    // MARK: - Directory tree

    private func buildDirectoryTree(url: URL, depth: Int, maxDepth: Int) -> String {
        guard depth <= maxDepth else { return "" }
        let indent = String(repeating: "  ", count: depth)
        var result = "\(indent)\(url.lastPathComponent)/\n"

        guard let contents = try? fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return result }

        let sorted = contents.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for item in sorted.prefix(50) {  // cap at 50 per dir
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                result += buildDirectoryTree(url: item, depth: depth + 1, maxDepth: maxDepth)
            } else {
                result += "\(indent)  \(item.lastPathComponent)\n"
            }
        }
        return result
    }

    // MARK: - JCross auto-persistence

    private func persistSearchResult(key: String, value: String) async {
        await MainActor.run {
            CortexEngine.shared?.remember(
                key: key,
                value: value,
                importance: 0.72,
                zone: .near
            )
        }
    }

    // MARK: - Shell execution

    private func resolve(_ path: String, workspace: URL?) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if let ws = workspace  { return ws.appendingPathComponent(path) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(path)
    }

    private func runShell(_ command: String, workingDir: URL?) async -> String {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", command]
            process.currentDirectoryURL = workingDir ?? URL(fileURLWithPath: NSHomeDirectory())

            var env = ProcessInfo.processInfo.environment
            env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin") + ":/usr/local/bin:/opt/homebrew/bin"
            process.environment = env

            let stdoutPipe = Pipe(); let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError  = stderrPipe

            do { try process.run() } catch { return "✗ Could not launch: \(error)" }
            let out = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()

            var result = ""
            if !out.isEmpty { result += out.trimmingCharacters(in: .newlines) }
            if !err.isEmpty { result += (result.isEmpty ? "" : "\n") + "[stderr] " + err.trimmingCharacters(in: .newlines) }
            result += "\n[exit: \(process.terminationStatus)]"
            return result
        }.value
    }

    // MARK: - IDE Build

    private func runIDEBuild() async -> String {
        await Task.detached(priority: .userInitiated) {
            let projectPath = NSHomeDirectory() + "/verantyx-cli/VerantyxIDE/Verantyx.xcodeproj"
            guard FileManager.default.fileExists(atPath: projectPath) else {
                return "BUILD_ERROR: Verantyx.xcodeproj not found at \(projectPath)."
            }
            let cmd = """
            export PATH="$PATH:/opt/homebrew/bin"
            xcodebuild \
              -project '\(projectPath)' \
              -scheme Verantyx \
              -destination 'platform=macOS,arch=arm64' \
              CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO \
              build \
              2>&1 | grep -E '\\.swift:[0-9]+:[0-9]+: (error|warning):|BUILD SUCCEEDED|BUILD FAILED' \
                   | grep -v 'objc\\|deprecated' \
                   | head -40
            """
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-c", cmd]
            let pipe = Pipe()
            process.standardOutput = pipe; process.standardError = pipe
            do { try process.run() } catch { return "BUILD_ERROR: \(error.localizedDescription)" }
            let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            let output = String(raw.prefix(3000))
            if output.contains("BUILD SUCCEEDED") { return "BUILD SUCCEEDED ✅" }
            return "BUILD FAILED ❌\nErrors:\n\(output.isEmpty ? "(no output)" : output)\nFix errors with [APPLY_PATCH] and run [BUILD_IDE] again."
        }.value
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let agentRequestsRestart = Notification.Name("VerantyxAgentRequestsRestart")
    static let agentAskHuman        = Notification.Name("VerantyxAgentAskHuman")  // NEW
}
