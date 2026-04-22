import Foundation

// MARK: - AgentTool
// Tool definitions that the AI can emit in its response.
// Parsed from a clean bracket-based syntax that local LLMs can follow reliably.
//
// Format the AI should output:
//
//   [MKDIR: path/to/dir]
//   [WRITE: path/to/file.py]
//   ```
//   file content here
//   ```
//   [/WRITE]
//   [RUN: python app.py]
//   [WORKSPACE: /absolute/or/relative/path]
//   [DONE: optional completion message]

enum AgentTool {
    case makeDir(String)
    case writeFile(path: String, content: String)
    case runCommand(String)
    case setWorkspace(String)
    case done(message: String)
    case readFile(String)
    // ── Browser tools ──────────────────────────────────────────────
    case browse(url: String)                   // verantyx-browser (stealth WKWebView)
    case search(query: String)                 // DuckDuckGo via verantyx-browser
    case evalJS(script: String)                // JS eval in verantyx-browser  
    case openSafari(url: String)               // Open URL in Safari via AppleScript
    case openChrome(url: String)               // Open URL in Chrome via AppleScript
    // ── Self-Fix build pipeline ───────────────────────────────────
    case applyPatch(relativePath: String, content: String)  // Write patch to IDE source
    case buildIDE                              // Run xcodebuild, return errors to AI
    case restartIDE                            // Ask user to restart (shows dialog)
}

// MARK: - AgentToolCall (result wrapper)

struct AgentToolCall: Identifiable {
    let id = UUID()
    let tool: AgentTool
    var result: String = ""
    var succeeded: Bool = true

    var displayLabel: String {
        switch tool {
        case .makeDir(let p):              return "mkdir \(p)"
        case .writeFile(let p, _):         return "write → \(p)"
        case .runCommand(let cmd):         return "$ \(cmd)"
        case .setWorkspace(let p):         return "workspace: \(p)"
        case .done(let m):                 return "✓ \(m)"
        case .readFile(let p):             return "read ← \(p)"
        case .browse(let url):             return "🌐 browse \(url)"
        case .search(let q):               return "🔍 search: \(q)"
        case .evalJS(let s):               return "⚡ eval_js: \(s.prefix(40))"
        case .openSafari(let url):         return "🧡 safari: \(url)"
        case .openChrome(let url):         return "🟢 chrome: \(url)"
        case .applyPatch(let p, _):        return "📦 patch → \(p)"
        case .buildIDE:                    return "🔨 xcodebuild"
        case .restartIDE:                  return "🔄 restart IDE"
        }
    }
}

// MARK: - AgentToolParser
// Parses AI output text into a sequence of AgentTool calls.
// Lenient: handles slight variations in model output.

struct AgentToolParser {

    // System prompt section to inject so the model knows the tools
    static let toolInstructions = """
    You are VerantyxAgent, an autonomous AI coding assistant.
    You have access to these tools. Use them to complete the task:

    [MKDIR: path/to/directory]          — create a directory
    [WRITE: path/to/file.ext]           — start writing a file
    ```
    ... file content ...
    ```
    [/WRITE]                            — end of file content
    [RUN: command]                      — run a shell command
    [WORKSPACE: /absolute/path]         — set/open workspace folder
    [DONE: summary message]             — signal task completion
    [BROWSE: https://url]               — fetch a URL (stealth WebKit browser, returns Markdown)
    [SEARCH: query terms]               — web search (DuckDuckGo, returns page text)
    [EVAL_JS: javascript code]          — run JS in current browser page
    [SAFARI: https://url]               — open URL in Safari (uses your session/cookies)
    [CHROME: https://url]               — open URL in Chrome (uses your session/cookies)

    ── SELF-FIX TOOLS (only available in Self-Fix mode) ──
    [APPLY_PATCH: Sources/Verantyx/Views/Foo.swift]
    ```swift
    // complete new file content
    ```
    [/APPLY_PATCH]                      — write patched content to IDE source file
    [BUILD_IDE]                         — run xcodebuild on the IDE project; returns errors or BUILD SUCCEEDED
    [RESTART_IDE]                       — show restart confirmation dialog to user

    SELF-FIX WORKFLOW (use this pattern when modifying the IDE):
    1. Write the fix using [APPLY_PATCH: ...] ... [/APPLY_PATCH]
    2. Run [BUILD_IDE] to verify it compiles
    3. If errors: read them, fix the file with another [APPLY_PATCH], repeat [BUILD_IDE]
    4. When BUILD SUCCEEDED: use [RESTART_IDE] to ask user to restart
    5. Then [DONE: what was changed]

    RULES:
    - Always use [MKDIR] before [WRITE] if the directory doesn't exist
    - Paths relative to the workspace are OK (e.g. [MKDIR: calculator])
    - Use [WORKSPACE: ~/Desktop/MyProject] or similar Desktop paths
    - After creating all files, use [RUN] to verify the project works  
    - End every task with [DONE: brief summary]
    - You can write multiple files in sequence
    - Use [SEARCH: query] to look up documentation or current information
    - Use [BROWSE: url] to read specific pages for API docs or reference
    - Use [SAFARI: url] or [CHROME: url] when you need authenticated access

    EXAMPLE — user says "create a Python calculator":
    Okay, I'll create a Python calculator project.

    [WORKSPACE: ~/Desktop/calculator]
    [MKDIR: ~/Desktop/calculator]
    [WRITE: ~/Desktop/calculator/calculator.py]
    ```python
    def add(a, b): return a + b
    def subtract(a, b): return a - b
    def multiply(a, b): return a * b
    def divide(a, b): return a / b if b != 0 else "Error: division by zero"

    if __name__ == "__main__":
        print("=== Calculator ===")
        print(f"2 + 3 = {add(2, 3)}")
        print(f"10 - 4 = {subtract(10, 4)}")
        print(f"3 * 5 = {multiply(3, 5)}")
        print(f"10 / 2 = {divide(10, 2)}")
    ```
    [/WRITE]
    [RUN: python ~/Desktop/calculator/calculator.py]
    [DONE: Python calculator created at ~/Desktop/calculator]
    """

    // MARK: - Main parse method

    static func parse(from text: String) -> (toolCalls: [AgentTool], cleanText: String) {
        var tools: [AgentTool] = []
        var cleaned = text

        // ── 1. Parse [WRITE: path] ... ``` content ``` [/WRITE] ──────────
        let writePattern = #"\[WRITE:\s*([^\]]+)\]\s*```(?:\w+)?\n?([\s\S]*?)```\s*\[/WRITE\]"#
        if let regex = try? NSRegularExpression(pattern: writePattern) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches.reversed() {
                if let pathRange = Range(match.range(at: 1), in: text),
                   let contentRange = Range(match.range(at: 2), in: text),
                   let fullRange = Range(match.range, in: text) {
                    let path = expandHome(String(text[pathRange]).trimmingCharacters(in: .whitespaces))
                    let content = String(text[contentRange])
                    tools.insert(.writeFile(path: path, content: content), at: 0)
                    cleaned = cleaned.replacingCharacters(in: fullRange, with: "")
                }
            }
        }

        // ── 1b. Parse [APPLY_PATCH: path] ... ``` content ``` [/APPLY_PATCH] ──
        let patchPattern = #"\[APPLY_PATCH:\s*([^\]]+)\]\s*```(?:\w+)?\n?([\s\S]*?)```\s*\[/APPLY_PATCH\]"#
        if let regex = try? NSRegularExpression(pattern: patchPattern) {
            let matches = regex.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned))
            for match in matches.reversed() {
                if let pathRange = Range(match.range(at: 1), in: cleaned),
                   let contentRange = Range(match.range(at: 2), in: cleaned),
                   let fullRange = Range(match.range, in: cleaned) {
                    let path    = String(cleaned[pathRange]).trimmingCharacters(in: .whitespaces)
                    let content = String(cleaned[contentRange])
                    tools.insert(.applyPatch(relativePath: path, content: content), at: 0)
                    cleaned = cleaned.replacingCharacters(in: fullRange, with: "")
                }
            }
        }

        // ── 2. Parse single-line tags ──────────────────────────────────────
        let lines = cleaned.components(separatedBy: "\n")
        var resultLines: [String] = []

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let m = match(trimmed, pattern: #"^\[MKDIR:\s*([^\]]+)\]$"#) {
                tools.append(.makeDir(expandHome(m)))
            } else if let m = match(trimmed, pattern: #"^\[RUN:\s*([^\]]+)\]$"#) {
                tools.append(.runCommand(m))
            } else if let m = match(trimmed, pattern: #"^\[WORKSPACE:\s*([^\]]+)\]$"#) {
                tools.append(.setWorkspace(expandHome(m)))
            } else if let m = match(trimmed, pattern: #"^\[DONE[:\s]*([^\]]*)\]$"#) {
                tools.append(.done(message: m.isEmpty ? "Task complete." : m))
            } else if let m = match(trimmed, pattern: #"^\[READ:\s*([^\]]+)\]$"#) {
                tools.append(.readFile(expandHome(m)))
            // ── Browser tools ────────────────────────────────────────
            } else if let m = match(trimmed, pattern: #"^\[BROWSE:\s*([^\]]+)\]$"#) {
                tools.append(.browse(url: m))
            } else if let m = match(trimmed, pattern: #"^\[SEARCH:\s*([^\]]+)\]$"#) {
                tools.append(.search(query: m))
            } else if let m = match(trimmed, pattern: #"^\[EVAL_JS:\s*([^\]]+)\]$"#) {
                tools.append(.evalJS(script: m))
            } else if let m = match(trimmed, pattern: #"^\[SAFARI:\s*([^\]]+)\]$"#) {
                tools.append(.openSafari(url: m))
            } else if let m = match(trimmed, pattern: #"^\[CHROME:\s*([^\]]+)\]$"#) {
                tools.append(.openChrome(url: m))
            // ── Self-Fix build pipeline ───────────────────────────
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

    private static func match(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text)
        else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespaces)
    }

    static func expandHome(_ path: String) -> String {
        if path.hasPrefix("~/") {
            return NSHomeDirectory() + path.dropFirst(1)
        }
        return path
    }
}

// MARK: - AgentToolExecutor
// Executes tool calls and returns result strings for feeding back to AI.

actor AgentToolExecutor {

    private let fileManager = FileManager.default

    func execute(_ tool: AgentTool, workspaceURL: URL?) async -> String {
        switch tool {

        case .makeDir(let path):
            let url = resolve(path, workspace: workspaceURL)
            do {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
                return "✓ Created directory: \(url.path)"
            } catch {
                return "✗ mkdir failed: \(error.localizedDescription)"
            }

        case .writeFile(let path, let content):
            let url = resolve(path, workspace: workspaceURL)
            // Ensure parent directory exists
            let parentDir = url.deletingLastPathComponent()
            try? fileManager.createDirectory(at: parentDir, withIntermediateDirectories: true)
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                return "✓ Wrote \(url.lastPathComponent) (\(content.components(separatedBy: "\n").count) lines)"
            } catch {
                return "✗ write failed for \(path): \(error.localizedDescription)"
            }

        case .runCommand(let cmd):
            return await runShell(cmd, workingDir: workspaceURL)

        case .setWorkspace(let path):
            // Workspace switch is handled by AppState; just confirm
            return "✓ Workspace set to: \(path)"

        case .done(let msg):
            return "✓ \(msg)"

        case .readFile(let path):
            let url = resolve(path, workspace: workspaceURL)
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                return "FILE CONTENT (\(url.lastPathComponent)):\n\(content.prefix(4000))"
            }
            return "✗ Could not read: \(path)"

        // ── Browser tools ────────────────────────────────────────────────

        case .browse(let url):
            let result = await WebSearchEngine.shared.browse(url: url, preferredSource: .verantyxBrowser)
            return """
            [WEB PAGE: \(result.url)]
            \(result.contextSnippet)
            [END WEB PAGE]
            """

        case .search(let query):
            let result = await WebSearchEngine.shared.search(query: query)
            return """
            [SEARCH RESULTS for: \(query)]
            Source: \(result.url)
            \(result.contextSnippet)
            [END SEARCH RESULTS]
            """

        case .evalJS(let script):
            do {
                let result = try await BrowserBridge.shared.evalJS(script)
                return "[JS RESULT] \(result)"
            } catch {
                return "[JS ERROR] \(error.localizedDescription)"
            }

        case .openSafari(let url):
            let result = await WebSearchEngine.shared.browse(url: url, preferredSource: .safari)
            return """
            [SAFARI: \(result.url)]
            \(result.contextSnippet)
            [END SAFARI]
            """

        case .openChrome(let url):
            let result = await WebSearchEngine.shared.browse(url: url, preferredSource: .chrome)
            return """
            [CHROME: \(result.url)]
            \(result.contextSnippet)
            [END CHROME]
            """

        // ── Self-Fix build pipeline ───────────────────────────────────

        case .applyPatch(let relativePath, let content):
            // Sanitize fences and write to IDE source via SelfEvolutionEngine
            return await MainActor.run {
                let sanitized = SelfEvolutionEngine.stripCodeFences(from: content)
                SelfEvolutionEngine.shared.registerPatch(for: relativePath, newContent: sanitized)
                return "✅ PATCH_REGISTERED: \(relativePath) (\(sanitized.components(separatedBy: "\n").count) lines)"
            }

        case .buildIDE:
            return await runIDEBuild()

        case .restartIDE:
            // Fire the restart request on MainActor and return a message for the AI
            await MainActor.run {
                NotificationCenter.default.post(name: .agentRequestsRestart, object: nil)
            }
            return "RESTART_REQUESTED: User will be asked to restart the app."
        }
    }

    private func resolve(_ path: String, workspace: URL?) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        if let ws = workspace { return ws.appendingPathComponent(path) }
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

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError  = stderrPipe

            do { try process.run() } catch { return "✗ Could not launch: \(error)" }
            let out = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()

            var result = ""
            if !out.isEmpty { result += out.trimmingCharacters(in: .newlines) }
            if !err.isEmpty {
                if !result.isEmpty { result += "\n" }
                result += "[stderr] " + err.trimmingCharacters(in: .newlines)
            }
            result += "\n[exit: \(process.terminationStatus)]"
            return result.isEmpty ? "[exit: \(process.terminationStatus)]" : result
        }.value
    }

    // ── BUILD_IDE: xcodebuild with error filtering ────────────────────────
    // Returns only actionable error/warning lines (not all the noise).
    // Caps output at 3000 chars so it fits in AI context.

    private func runIDEBuild() async -> String {
        await Task.detached(priority: .userInitiated) {
            // Locate the Xcode project next to the running app's bundle
            let derivedData = NSHomeDirectory() + "/Library/Developer/Xcode/DerivedData"
            // Find the xcodeproj we want to build
            let projectPath = NSHomeDirectory() + "/verantyx-cli/VerantyxIDE/Verantyx.xcodeproj"

            guard FileManager.default.fileExists(atPath: projectPath) else {
                return "BUILD_ERROR: Verantyx.xcodeproj not found at \(projectPath). Please open workspace first."
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
            process.standardOutput = pipe
            process.standardError  = pipe

            do { try process.run() } catch {
                return "BUILD_ERROR: Could not launch xcodebuild — \(error.localizedDescription)"
            }

            let rawOutput = String(
                data: pipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            process.waitUntilExit()

            let exitCode = process.terminationStatus
            let output   = String(rawOutput.prefix(3000))

            if output.contains("BUILD SUCCEEDED") {
                return "BUILD SUCCEEDED ✅ — all patches compiled without errors."
            } else {
                return """
                BUILD FAILED ❌ (exit \(exitCode))
                Errors:
                \(output.isEmpty ? "(no output captured)" : output)
                Fix the errors above using [APPLY_PATCH:...] and run [BUILD_IDE] again.
                """
            }
        }.value
    }
}

// MARK: - Notification names for agent → UI communication

extension Notification.Name {
    /// Posted by AgentToolExecutor when AI emits [RESTART_IDE].
    /// AppState listens and shows a restart confirmation alert.
    static let agentRequestsRestart = Notification.Name("VerantyxAgentRequestsRestart")
}
