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
}

// MARK: - WebSearchEngine

actor WebSearchEngine {

    static let shared = WebSearchEngine()

    private let pool        = BrowserBridgePool.shared
    private let applescript = AppleScriptBridge.shared

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
            let markdown = try await pool.fetch(url)
            return WebSearchResult(
                query: query ?? url,
                url: url,
                markdown: markdown.isEmpty ? "(empty page)" : markdown,
                source: .verantyxBrowser,
                truncated: markdown.count > 6000
            )
        } catch {
            // verantyx-browser 失敗 → ニュース系 URL なら RSS/JSON API を試みる
            if let newsResult = await tryNewsAPIFallback(url: url, query: query) {
                return newsResult
            }
            // 最終フォールバック: URLSession
            return await browseWithFetch(
                url: url, query: query,
                note: "⚠️ verantyx-browser unavailable (\(error.localizedDescription)). Using HTTP fallback."
            )
        }
    }

    // MARK: - ニュース用 RSS/JSON API フォールバック
    //
    // NHK ニュース API や RSS を直接取得する。JS 不要で必ず取れる。

    private func tryNewsAPIFallback(url: String, query: String?) async -> WebSearchResult? {
        // NHK Web API (公開 JSON)
        let nhkApiURL = "https://www3.nhk.or.jp/news/json16/top_news_lv2.json"
        // NHK トップページ RSS
        let nhkRssURL = "https://www3.nhk.or.jp/rss/news/cat0.xml"
        // 検索クエリを DDG の JSON API (あれば) に送るのではなく、RSS を取得

        // NHK JSON API を試みる
        if let result = await fetchNewsJSON(url: nhkApiURL, query: query, sourceName: "NHK") {
            return result
        }
        // NHK RSS を試みる
        if let result = await fetchNewsRSS(url: nhkRssURL, query: query, sourceName: "NHK RSS") {
            return result
        }
        // Livedoor ニュース RSS (総合)
        let livedoorRSS = "https://news.livedoor.com/topics/rss/top.xml"
        if let result = await fetchNewsRSS(url: livedoorRSS, query: query, sourceName: "Livedoor") {
            return result
        }
        return nil
    }

    /// NHK の JSON API (トップニュース) を取得して Markdown 文字列に変換
    private func fetchNewsJSON(url: String, query: String?, sourceName: String) async -> WebSearchResult? {
        guard let reqURL = URL(string: url) else { return nil }
        var req = URLRequest(url: reqURL)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json, text/javascript, */*", forHTTPHeaderField: "Accept")
        req.setValue("ja,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.timeoutInterval = 10
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            // JSON を文字列化してキーだけパース（载せる形式が不明なため raw 文字列で返す）
            let raw = String(data: data, encoding: .utf8) ?? ""
            guard !raw.isEmpty else { return nil }
            // タイトルを抄出して箇所に返す
            let md = "# \(sourceName) 最新ニュース\n\n" + extractTitlesFromJSON(raw)
            return WebSearchResult(query: query ?? url, url: url, markdown: md, source: .fetch, truncated: false)
        } catch { return nil }
    }

    /// RSS XML を取得して Markdown リストに変換
    private func fetchNewsRSS(url: String, query: String?, sourceName: String) async -> WebSearchResult? {
        guard let reqURL = URL(string: url) else { return nil }
        var req = URLRequest(url: reqURL)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue("application/rss+xml, application/xml, text/xml", forHTTPHeaderField: "Accept")
        req.setValue("ja,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.timeoutInterval = 10
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let xml = String(data: data, encoding: .utf8) ?? ""
            guard !xml.isEmpty else { return nil }
            let md = parseRSSToMarkdown(xml, source: sourceName)
            guard !md.isEmpty else { return nil }
            return WebSearchResult(query: query ?? url, url: url, markdown: md, source: .fetch, truncated: false)
        } catch { return nil }
    }

    /// RSS XML から <title> / <pubDate> / <description> を抄出して Markdown リストに変換
    private func parseRSSToMarkdown(_ xml: String, source: String) -> String {
        var items: [(title: String, date: String, desc: String)] = []
        // 簡易パーサ（NSXMLParser 不要）
        let titlePattern   = try? NSRegularExpression(pattern: "<title><!\\[CDATA\\[(.+?)\\]\\]></title>|<title>(.+?)</title>", options: [.dotMatchesLineSeparators])
        let pubPattern     = try? NSRegularExpression(pattern: "<pubDate>(.+?)</pubDate>", options: [])
        let descPattern    = try? NSRegularExpression(pattern: "<description><!\\[CDATA\\[(.+?)\\]\\]></description>|<description>(.+?)</description>", options: [.dotMatchesLineSeparators])

        let ns = NSRange(xml.startIndex..., in: xml)
        let titles  = (titlePattern?.matches(in: xml, range: ns) ?? []).compactMap { m -> String? in
            for g in 1...2 { if let r = Range(m.range(at: g), in: xml) { return String(xml[r]) } }
            return nil
        }.filter { !$0.hasPrefix("NHK") && !$0.isEmpty }.prefix(20)
        let dates   = (pubPattern?.matches(in: xml, range: ns) ?? []).compactMap { m -> String? in
            if let r = Range(m.range(at: 1), in: xml) { return String(xml[r].prefix(25)) }
            return nil
        }.prefix(20)
        let descs   = (descPattern?.matches(in: xml, range: ns) ?? []).compactMap { m -> String? in
            for g in 1...2 { if let r = Range(m.range(at: g), in: xml) { return stripHTML(String(xml[r])).prefix(120) + "" } }
            return nil
        }.prefix(20)

        for i in 0..<min(titles.count, 15) {
            let t = titles[i]
            let d = i < dates.count ? dates[i] : ""
            let s = i < descs.count ? descs[i] : ""
            items.append((title: t, date: d, desc: String(s)))
        }
        guard !items.isEmpty else { return "" }

        var md = "# \(source) 最新ニュース\n"
        for item in items {
            md += "\n## \(item.title)\n"
            if !item.date.isEmpty { md += "*\(item.date)*\n" }
            if !item.desc.isEmpty { md += "\(item.desc)\n" }
        }
        return md
    }

    /// JSON文字列から "title": "..." 形式の値を抽出しリスト化
    private func extractTitlesFromJSON(_ json: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "\"title\":\\s*\"([^\"]+)\"") else { return json.prefix(3000).description }
        let ns = NSRange(json.startIndex..., in: json)
        let matches = regex.matches(in: json, range: ns).prefix(20)
        let titles = matches.compactMap { m -> String? in
            guard let r = Range(m.range(at: 1), in: json) else { return nil }
            return "- " + String(json[r])
        }
        return titles.isEmpty ? json.prefix(3000).description : titles.joined(separator: "\n")
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
