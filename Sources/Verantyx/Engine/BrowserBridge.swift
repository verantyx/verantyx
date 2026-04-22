import Foundation

// MARK: - BrowserBridge
// Controls verantyx-browser (Rust/WKWebView) via JSON IPC over stdin/stdout.
// The browser runs invisibly in bridge mode — gives the AI a real browser engine
// without sending identifying headers (stealth WebKit, not Chromium CDP).
//
// Protocol:
//   Swift → Rust:  {"cmd": "navigate", "url": "..."}   (JSON lines on stdin)
//   Rust → Swift:  {"status": "ok", "markdown": "..."}  (JSON lines on stdout)

// MARK: - Bridge data types

struct BrowserCommand: Codable {
    var cmd:  String
    var url:  String?
    var text: String?
    var id:   UInt64?
}

struct BrowserResponse: Codable {
    var status:   String
    var message:  String?
    var url:      String?
    var markdown: String?
    var title:    String?
}

// MARK: - BrowserState

enum BrowserState: Equatable {
    case idle
    case launching
    case ready
    case navigating(String)
    case error(String)
}

// MARK: - BrowserBridge Actor

actor BrowserBridge {

    static let shared = BrowserBridge()

    // ── Binary path ────────────────────────────────────────────────
    private var binaryPath: String {
        // 1. Debug build (development)
        let debug = "\(projectRoot)/verantyx-browser/target/debug/verantyx-browser"
        if FileManager.default.fileExists(atPath: debug) { return debug }
        // 2. Release build
        let release = "\(projectRoot)/verantyx-browser/target/release/verantyx-browser"
        if FileManager.default.fileExists(atPath: release) { return release }
        // 3. In-bundle (future distribution)
        return Bundle.main.path(forResource: "verantyx-browser", ofType: nil) ?? debug
    }

    private var projectRoot: String {
        // Walk up from the bundle to find the workspace root
        var url = Bundle.main.bundleURL
        for _ in 0..<6 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("verantyx-browser").path) {
                return url.path
            }
        }
        return URL(fileURLWithPath: #file)
            .deletingLastPathComponent()         // Engine/
            .deletingLastPathComponent()         // Verantyx/
            .deletingLastPathComponent()         // Sources/
            .deletingLastPathComponent()         // VerantyxIDE/
            .deletingLastPathComponent()         // verantyx-cli/
            .path
    }

    // ── Process state ──────────────────────────────────────────────
    private var process: Process?
    private var stdin:   Pipe?
    private var stdout:  Pipe?
    private var stdoutReader: Task<Void, Never>?

    private var pendingCallbacks: [String: CheckedContinuation<BrowserResponse, Error>] = [:]
    private var lastResponse: BrowserResponse?
    private(set) var state: BrowserState = .idle

    // ── Launch ─────────────────────────────────────────────────────

    func launch(visible: Bool = false) async throws {
        guard state == .idle || state == .error("") else { return }
        state = .launching

        let path = binaryPath
        guard FileManager.default.fileExists(atPath: path) else {
            state = .error("Binary not found: \(path). Run: cd verantyx-browser && cargo build --package vx-browser")
            throw BrowserError.binaryNotFound(path)
        }

        let proc  = Process()
        let stdin  = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments     = ["--bridge"] + (visible ? ["--visible"] : [])
        proc.standardInput  = stdin
        proc.standardOutput = stdout
        proc.standardError  = stderr
        proc.qualityOfService = .userInitiated

        try proc.run()

        self.process = proc
        self.stdin   = stdin
        self.stdout  = stdout

        // Background reader task — parses JSON lines from Rust stdout
        stdoutReader = Task.detached(priority: .high) { [weak self] in
            let outHandle = stdout.fileHandleForReading
            var buffer = ""
            while true {
                let data = outHandle.availableData
                if data.isEmpty { try? await Task.sleep(nanoseconds: 10_000_000); continue }
                guard let chunk = String(data: data, encoding: .utf8) else { continue }
                buffer += chunk
                while let newlineRange = buffer.range(of: "\n") {
                    let line = String(buffer[..<newlineRange.lowerBound]).trimmingCharacters(in: .whitespaces)
                    buffer.removeSubrange(..<newlineRange.upperBound)
                    if !line.isEmpty {
                        if let resp = try? JSONDecoder().decode(BrowserResponse.self, from: Data(line.utf8)) {
                            await self?.handleResponse(resp)
                        }
                    }
                }
                if Task.isCancelled { break }
            }
        }

        // Wait for initial PAGE_READY acknowledgment (up to 5 s)
        try await waitForReady(timeout: 5)
        state = .ready
    }

    private func waitForReady(timeout: Double) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let resp = lastResponse, resp.status == "ok" && resp.message == "ready" {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        // If no PAGE_READY — browser is still usable, just no initial blank DOM confirmation
    }

    // ── Commands ───────────────────────────────────────────────────

    /// Navigate to a URL. Returns when the browser has loaded (or timeout).
    func navigate(to url: String) async throws -> String {
        try ensureRunning()
        state = .navigating(url)
        try send(BrowserCommand(cmd: "navigate", url: url))

        // Give WKWebView time to load — wait for HITL_DONE or hitl_done
        let markdown = try await waitForPage(timeout: 15)
        state = .ready
        return markdown
    }

    /// Navigate and immediately get page content as Markdown.
    func fetch(_ url: String) async throws -> String {
        let _ = try await navigate(to: url)
        // Small delay for dynamic content
        try await Task.sleep(nanoseconds: 1_500_000_000)
        return try await getPage()
    }

    /// Get current page as Markdown.
    func getPage() async throws -> String {
        try ensureRunning()
        try send(BrowserCommand(cmd: "get_page"))
        return try await waitForMarkdown(timeout: 10)
    }

    /// Execute JavaScript in the current page.
    func evalJS(_ script: String) async throws -> String {
        try ensureRunning()
        try send(BrowserCommand(cmd: "eval_js", text: script))
        return try await waitForEval(timeout: 10)
    }

    /// Quit the browser process.
    func quit() {
        try? send(BrowserCommand(cmd: "quit"))
        process?.terminate()
        process = nil
        stdoutReader?.cancel()
        state = .idle
    }

    // ── Private helpers ────────────────────────────────────────────

    private func send(_ cmd: BrowserCommand) throws {
        guard let stdin = stdin else { throw BrowserError.notRunning }
        let data = try JSONEncoder().encode(cmd)
        var line = data
        line.append(0x0A) // newline
        stdin.fileHandleForWriting.write(line)
    }

    private func handleResponse(_ resp: BrowserResponse) {
        lastResponse = resp
    }

    private func waitForPage(timeout: Double) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let resp = lastResponse {
                if resp.status == "hitl_done", let md = resp.markdown { lastResponse = nil; return md }
                if resp.status == "ok", let md = resp.markdown { lastResponse = nil; return md }
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        return "(page loading timed out)"
    }

    private func waitForMarkdown(timeout: Double) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let resp = lastResponse, let md = resp.markdown { lastResponse = nil; return md }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        return "(could not fetch page content)"
    }

    private func waitForEval(timeout: Double) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let resp = lastResponse {
                if resp.status == "eval_ok" { let m = resp.message ?? ""; lastResponse = nil; return m }
                if resp.status == "eval_err" { let m = resp.message ?? "unknown"; lastResponse = nil; throw BrowserError.jsError(m) }
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw BrowserError.timeout
    }

    private func ensureRunning() throws {
        guard let proc = process, proc.isRunning else {
            state = .idle
            throw BrowserError.notRunning
        }
    }
}

// MARK: - BrowserError

enum BrowserError: Error, LocalizedError {
    case binaryNotFound(String)
    case notRunning
    case timeout
    case jsError(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let p): return "verantyx-browser not found at \(p). Build it first."
        case .notRunning:            return "Browser not running. Call launch() first."
        case .timeout:               return "Browser operation timed out."
        case .jsError(let e):        return "JS error: \(e)"
        }
    }
}
