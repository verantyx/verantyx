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
}

// MARK: - WebSearchEngine

actor WebSearchEngine {

    static let shared = WebSearchEngine()

    private let browser   = BrowserBridge.shared
    private let applescript = AppleScriptBridge.shared
    private var browserLaunched = false

    // MARK: - Main: search

    func search(
        query: String,
        engine: SearchEngine = .duckduckgo,
        preferredSource: BrowseSource = .verantyxBrowser
    ) async -> WebSearchResult {

        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let searchURL = engine.searchURL(for: encodedQuery)

        return await browse(url: searchURL, preferredSource: preferredSource, originalQuery: query)
    }

    // MARK: - Main: browse URL

    func browse(
        url: String,
        preferredSource: BrowseSource = .verantyxBrowser,
        originalQuery: String? = nil
    ) async -> WebSearchResult {

        switch preferredSource {
        case .verantyxBrowser:
            return await browseWithRustBrowser(url: url, query: originalQuery)

        case .safari:
            return await browseWithAppleScript(url: url, browser: .safari, query: originalQuery)

        case .chrome:
            return await browseWithAppleScript(url: url, browser: .chrome, query: originalQuery)

        case .arc:
            return await browseWithAppleScript(url: url, browser: .arc, query: originalQuery)

        case .fetch:
            return await browseWithFetch(url: url, query: originalQuery)
        }
    }

    // MARK: - verantyx-browser (Rust/WKWebView stealth)

    private func browseWithRustBrowser(url: String, query: String?) async -> WebSearchResult {
        do {
            // Launch once and keep alive
            if !browserLaunched {
                try await browser.launch(visible: false)
                browserLaunched = true
            }

            let markdown = try await browser.fetch(url)
            return WebSearchResult(
                query: query ?? url,
                url: url,
                markdown: markdown.isEmpty ? "(empty page)" : markdown,
                source: .verantyxBrowser,
                truncated: markdown.count > 6000
            )
        } catch {
            // Fallback to URLSession if binary not found
            return await browseWithFetch(url: url, query: query, note: "⚠️ verantyx-browser unavailable (\(error.localizedDescription)). Using HTTP fallback.")
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
                source: browser == .safari ? .safari : .chrome,
                truncated: text.count > 6000
            )
        } catch {
            return WebSearchResult(
                query: query ?? url,
                url: url,
                markdown: "❌ \(browser.rawValue) error: \(error.localizedDescription)",
                source: browser == .safari ? .safari : .chrome,
                truncated: false
            )
        }
    }

    // MARK: - URLSession fallback (no JS, visible headers)

    private func browseWithFetch(url: String, query: String?, note: String? = nil) async -> WebSearchResult {
        do {
            var request = URLRequest(url: URL(string: url)!)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")
            request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15

            let (data, _) = try await URLSession.shared.data(for: request)
            let html = String(data: data, encoding: .utf8) ?? ""

            // Very simple HTML→text
            let text = stripHTML(html)
            var result = text
            if let note = note {
                result = note + "\n\n" + text
            }

            return WebSearchResult(
                query: query ?? url,
                url: url,
                markdown: result.isEmpty ? "(empty response)" : result,
                source: .fetch,
                truncated: result.count > 6000
            )
        } catch {
            return WebSearchResult(
                query: query ?? url,
                url: url,
                markdown: "❌ Fetch error: \(error.localizedDescription)",
                source: .fetch,
                truncated: false
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
