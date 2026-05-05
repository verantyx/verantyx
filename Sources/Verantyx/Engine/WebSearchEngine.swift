import Foundation

// MARK: - WebSearchEngine
// High-level search/browse interface for the AI agent.
// Chooses between verantyx-browser (stealth WebKit) and AppleScript (Safari/Chrome)
// based on user settings and what's available.

struct WebSearchResult {
    var query:    String
    var url:      String
    var markdown: String
    var source:   BrowseSource
    var truncated: Bool
    /// HTTP ステータスコード（0 = 不明 / JS レンダリング済み）
    var httpStatus: Int = 0

    /// ReAct エンジンが失敗と判定するか
    var isFailure: Bool {
        // 4xx/5xx エラー or 明示的なエラーマーカー
        if httpStatus >= 400 { return true }
        let lower = markdown.lowercased()
        return lower.hasPrefix("❌") ||
               lower.contains("404") ||
               lower.contains("not found") ||
               lower.contains("(empty page)") ||
               lower.contains("(empty response)")
    }

    /// 失敗理由の短い説明（再思考プロンプト用）
    var failureReason: String {
        if httpStatus == 404 { return "HTTP 404 Not Found" }
        if httpStatus >= 400 { return "HTTP \(httpStatus) Error" }
        if httpStatus >= 500 { return "HTTP \(httpStatus) Server Error" }
        if markdown.contains("(empty page)") { return "ページが空でした" }
        if markdown.contains("(empty response)") { return "レスポンスが空でした" }
        if markdown.hasPrefix("❌") { return String(markdown.prefix(120)) }
        return "コンテンツを取得できませんでした"
    }

    var contextSnippet: String {
        let limit = 6000
        if markdown.count <= limit { return markdown }
        return String(markdown.prefix(limit)) + "\n\n[… content truncated at 6000 chars …]"
    }
}

enum BrowseSource {
    case verantyxBrowser    // Rust WKWebView stealth
    case safari
    case chrome
    case arc
    case fetch              // URLSession fallback (no JS)
    case firefoxBridge      // Python script for Stealth Browser
}

// MARK: - WebSearchEngine

actor WebSearchEngine {

    static let shared = WebSearchEngine()

    private let pool        = BrowserBridgePool.shared
    private let applescript = AppleScriptBridge.shared

    // MARK: - Main: search

    func search(
        query: String,
        engine: SearchEngine = .google,
        preferredSource: BrowseSource = .safari,
        entropy: [[Double]]? = nil,
        keyboardEntropy: [Double]? = nil,
        videoFrames: [String]? = nil
    ) async -> WebSearchResult {

        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let searchURL = engine.searchURL(for: encodedQuery)

        return await browse(url: searchURL, preferredSource: preferredSource, originalQuery: query, entropy: entropy, keyboardEntropy: keyboardEntropy, videoFrames: videoFrames)
    }

    // MARK: - Main: browse URL

    func browse(
        url: String,
        preferredSource: BrowseSource = .safari,
        originalQuery: String? = nil,
        entropy: [[Double]]? = nil,
        keyboardEntropy: [Double]? = nil,
        videoFrames: [String]? = nil
    ) async -> WebSearchResult {
        
        // ── COMPLETE VERSION: Qwen3.6-27B Video Analysis Pipeline ──
        var finalEntropy = entropy
        var finalTarget: [Double]? = nil
        
        if let frames = videoFrames, !frames.isEmpty {
            // 1. Harvesting Phase via Video (Qwen3.6-27B)
            if let extracted = await QwenVideoAnalyzer.shared.extractEntropyFromVideo(base64Frames: frames) {
                finalEntropy = extracted
            }
            
            // 2. Targeting Phase via Screenshot (Qwen3.6-27B)
            // Using the last frame as the current browser state representation
            if let target = await QwenVideoAnalyzer.shared.identifyTargetCoordinates(screenshotBase64: frames.last!) {
                finalTarget = target
            }
        }

        let result: WebSearchResult
        switch preferredSource {
        case .verantyxBrowser:
            result = await browseWithRustBrowser(url: url, query: originalQuery, entropy: finalEntropy, keyboardEntropy: keyboardEntropy, target: finalTarget)

        case .safari:
            result = await browseWithAppleScript(url: url, browser: .safari, query: originalQuery)

        case .chrome:
            result = await browseWithAppleScript(url: url, browser: .chrome, query: originalQuery)

        case .arc:
            result = await browseWithAppleScript(url: url, browser: .arc, query: originalQuery)

        case .firefoxBridge:
            result = await browseWithFirefoxBridge(url: url, query: originalQuery)

        case .fetch:
            result = await browseWithFetch(url: url, query: originalQuery)
        }
        
        // Handle entropy invalidation and rate limits
        if !result.isFailure {
            print("Telemetry: Biometric entropy successfully consumed for search. [\(url)]")
            await MainActor.run {
                AppState.shared?.lastEntropy = nil
                AppState.shared?.lastEntropyTimestamp = nil
                AppState.shared?.lastVideoFrames = nil
                AppState.shared?.lastKeyboardEntropy = nil
            }
        } else if result.httpStatus == 429 || result.markdown.contains("429") || result.markdown.contains("Rate limit") {
            print("Telemetry: Search provider rate limit (429) detected. Triggering 60s cooldown.")
            await MainActor.run {
                AppState.shared?.searchCooldownUntil = Date().addingTimeInterval(60) // 1 min cooldown
            }
        }
        
        return result
    }

    private func browseWithRustBrowser(url: String, query: String?, entropy: [[Double]]? = nil, keyboardEntropy: [Double]? = nil, target: [Double]? = nil) async -> WebSearchResult {
        if let points = entropy, !points.isEmpty {
            await MainActor.run { AppState.shared?.isAgentControllingMouse = true }
            // Estimate duration: ~10ms per point + 100ms click
            let estimatedDuration = Double(points.count) * 0.01 + 0.1
            Task {
                try? await Task.sleep(nanoseconds: UInt64(estimatedDuration * 1_000_000_000))
                await MainActor.run { AppState.shared?.isAgentControllingMouse = false }
            }
        }
        
        do {
            var markdown = ""
            if let q = query, url.contains("duckduckgo.com") {
                markdown = try await pool.interactiveSearch(query: q, searchURL: url, entropy: entropy, keyboardEntropy: keyboardEntropy, target: target)
            } else {
                markdown = try await pool.fetch(url, entropy: entropy, keyboardEntropy: keyboardEntropy, target: target)
            }
            
            // Clean up heavy Markdown image tags and domain links that verantyx-browser produces
            if let imgRegex = try? NSRegularExpression(pattern: "\\[<img.*?\\]\\([^)]+\\)", options: [.caseInsensitive, .dotMatchesLineSeparators]) {
                markdown = imgRegex.stringByReplacingMatches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown), withTemplate: "")
            }
            if let linkJunkRegex = try? NSRegularExpression(pattern: "\\[ www\\.[^]]+\\]\\([^)]+\\)", options: [.caseInsensitive]) {
                markdown = linkJunkRegex.stringByReplacingMatches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown), withTemplate: "")
            }
            
            // Remove DDG UI clutter from markdown
            if let ddgRegex = try? NSRegularExpression(pattern: "All Regions\\s+Argentina\\s+Australia.*?(Past Year)", options: [.dotMatchesLineSeparators, .caseInsensitive]) {
                markdown = ddgRegex.stringByReplacingMatches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown), withTemplate: "")
            }
            // Remove DDG long tracking URLs to save tokens
            if let ddgUrlRegex = try? NSRegularExpression(pattern: "\\(https://duckduckgo\\.com/y\\.js\\?[^)]+\\)", options: [.caseInsensitive]) {
                markdown = ddgUrlRegex.stringByReplacingMatches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown), withTemplate: "()")
            }
            // Remove DDG Ad disclaimer
            if let ddgAdRegex = try? NSRegularExpression(pattern: "Viewing ads is privacy protected.*?private-search\\)\\)\\.", options: [.dotMatchesLineSeparators, .caseInsensitive]) {
                markdown = ddgAdRegex.stringByReplacingMatches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown), withTemplate: "")
            }
            
            return WebSearchResult(
                query: query ?? url,
                url: url,
                markdown: markdown.isEmpty ? "(empty page)" : markdown,
                source: .verantyxBrowser,
                truncated: markdown.count > 6000
            )
        } catch {
            // verantyx-browser 失敗 → Firefox Bridge で再試行
            let fbResult = await browseWithFirefoxBridge(url: url, query: query)
            if !fbResult.isFailure {
                return fbResult
            }
            // 最終フォールバック: URLSession
            return await browseWithFetch(url: url, query: query)
        }
    }



    // MARK: - AppleScript (Safari / Chrome)

    private func browseWithAppleScript(url: String, browser: AppleScriptBridge.SystemBrowser, query: String?) async -> WebSearchResult {
        do {
            _ = try await applescript.open(url, in: browser)
            try await Task.sleep(nanoseconds: 4_000_000_000) // wait for load
            let text = try await applescript.getPageText(from: browser)
            let currentURL = (try? await applescript.getCurrentURL(from: browser)) ?? url

            return WebSearchResult(
                query: query ?? url,
                url: currentURL,
                markdown: text.isEmpty ? "(empty page)" : text,
                source: browser == .safari ? .safari : .safari,
                truncated: text.count > 6000
            )
        } catch {
            return WebSearchResult(
                query: query ?? url,
                url: url,
                markdown: "❌ \(browser.rawValue) error: \(error.localizedDescription)",
                source: browser == .safari ? .safari : .safari,
                truncated: false
            )
        }
    }

    // MARK: - Firefox Bridge (Python)

    private func browseWithFirefoxBridge(url: String, query: String?) async -> WebSearchResult {
        let actualQuery = query ?? url
        do {
            let bridgePath = "/Users/motonishikoudai/verantyx-cli/firefox_agent_bridge.py"
            guard FileManager.default.fileExists(atPath: bridgePath) else {
                return WebSearchResult(query: actualQuery, url: url, markdown: "❌ firefox_agent_bridge.py not found at \(bridgePath)", source: .firefoxBridge, truncated: false)
            }
            
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["python3", bridgePath, "--search", actualQuery]
            proc.environment = [
                "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/Library/Frameworks/Python.framework/Versions/3.13/bin:/Library/Frameworks/Python.framework/Versions/3.12/bin"
            ]
            
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = pipe
            
            try proc.run()
            proc.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            if proc.terminationStatus != 0 {
                return WebSearchResult(query: actualQuery, url: url, markdown: "❌ Firefox Bridge Error: \(output)", source: .firefoxBridge, truncated: false)
            }
            
            let text = stripHTML(output)
            return WebSearchResult(query: actualQuery, url: url, markdown: text, source: .firefoxBridge, truncated: text.count > 6000)
        } catch {
            return WebSearchResult(query: actualQuery, url: url, markdown: "❌ Firefox Bridge Exception: \(error.localizedDescription)", source: .firefoxBridge, truncated: false)
        }
    }

    // MARK: - URLSession fallback (no JS, visible headers)

    private func browseWithFetch(url: String, query: String?, note: String? = nil) async -> WebSearchResult {
        do {
            guard let reqURL = URL(string: url) else {
                return WebSearchResult(query: query ?? url, url: url,
                                      markdown: "❌ 無効なURL: \(url)",
                                      source: .fetch, truncated: false, httpStatus: 0)
            }
            var request = URLRequest(url: reqURL)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)
            // ── HTTP ステータスを捕捉 ────────────────────────────────────
            let httpStatus = (response as? HTTPURLResponse)?.statusCode ?? 0

            // 4xx / 5xx は即座に失敗として返す
            if httpStatus >= 400 {
                return WebSearchResult(
                    query: query ?? url,
                    url: url,
                    markdown: "❌ HTTP \(httpStatus): \(url)",
                    source: .fetch,
                    truncated: false,
                    httpStatus: httpStatus
                )
            }

            let html = String(data: data, encoding: .utf8) ?? ""
            
            var text = ""
            // Specific parsing for DuckDuckGo HTML to avoid massive country list clutter
            if url.contains("duckduckgo.com/html"), let snippetRegex = try? NSRegularExpression(pattern: "class=\"result__snippet\"[^>]*>(.*?)</a>", options: [.dotMatchesLineSeparators, .caseInsensitive]) {
                let ns = NSRange(html.startIndex..., in: html)
                let snippets = snippetRegex.matches(in: html, range: ns).compactMap { m -> String? in
                    guard let r = Range(m.range(at: 1), in: html) else { return nil }
                    return String(html[r])
                }
                if !snippets.isEmpty {
                    text = stripHTML(snippets.joined(separator: "\n\n"))
                } else {
                    text = stripHTML(html)
                }
            } else {
                text = stripHTML(html)
            }
            
            var result = text
            if let note = note {
                result = note + "\n\n" + text
            }

            return WebSearchResult(
                query: query ?? url,
                url: url,
                markdown: result.isEmpty ? "(empty response)" : result,
                source: .fetch,
                truncated: result.count > 6000,
                httpStatus: httpStatus
            )
        } catch {
            return WebSearchResult(
                query: query ?? url,
                url: url,
                markdown: "❌ Fetch error: \(error.localizedDescription)",
                source: .fetch,
                truncated: false,
                httpStatus: 0
            )
        }
    }

    // MARK: - Helpers

    private func stripHTML(_ html: String) -> String {
        // Remove scripts, styles, then tags
        var text = html
        let patterns = [
            "<script[^>]*>[\\s\\S]*?</script>",
            "<style[^>]*>[\\s\\S]*?</style>",
            "<!--[\\s\\S]*?-->",
            "<[^>]+>"
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
            }
        }
        
        // Remove DuckDuckGo UI clutter (country list, date filters) that takes up ~800 chars
        if let ddgRegex = try? NSRegularExpression(pattern: "All Regions\\s+Argentina\\s+Australia.*?(Past Year)", options: [.dotMatchesLineSeparators, .caseInsensitive]) {
            text = ddgRegex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        
        // Collapse whitespace
        text = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // Decode common HTML entities
        text = text
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;",  with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")

        return String(text.prefix(12000))
    }
}
