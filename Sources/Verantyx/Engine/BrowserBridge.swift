import Foundation
import AppKit

// MARK: - BrowserBridge
//
// verantyx-browser (Rust/WKWebView) を JSON IPC (stdin/stdout) で制御する。
//
// ── 改善点 (v2) ──────────────────────────────────────────────────────────
//   ・リクエスト ID 対応: 全コマンドに UInt64 ID を付与、レスポンスで照合
//   ・lastResponse ポーリング廃止 → CheckedContinuation マップで即時 resolve
//   ・"navigating" レスポンスを中間状態として扱い "hitl_done" を最終完了とする
//   ・ping コマンドによるヘルスチェック
//   ・自動再接続: クラッシュ時に次のリクエストで再 launch を試みる

// MARK: - Data types

struct BrowserCommand: Codable {
    var cmd:  String
    var url:  String?
    var text: String?
    var id:   UInt64?
    var entropy: [[Double]]?
    var keyboard_entropy: [Double]?
    var target: [Double]?
}

struct BrowserResponse: Codable {
    var id:       UInt64?   // ← Rust 側からエコーバックされる
    var status:   String
    var message:  String?
    var url:      String?
    var markdown: String?
    var title:    String?
}

enum BrowserState: Equatable {
    case idle
    case launching
    case ready
    case navigating(String)
    case error(String)
}

// MARK: - Pending request types

private enum PendingKind {
    case markdown   // HITL_DONE / DOM → markdown を返す
    case eval       // EVAL_RES / EVAL_ERR → message を返す
    case pong       // ping → status == "pong"
}

private struct PendingRequest {
    let kind: PendingKind
    let continuation: CheckedContinuation<BrowserResponse, Error>
}

// MARK: - BrowserBridge Actor

actor BrowserBridge {

    static let shared = BrowserBridge()

    // ── プロセス状態 ────────────────────────────────────────────────────────
    private var process:      Process?
    private var stdinPipe:    Pipe?
    private var stdoutPipe:   Pipe?
    private var readerTask:   Task<Void, Never>?

    // ── リクエスト管理 ───────────────────────────────────────────────────────
    private var nextID:    UInt64 = 1
    private var pending:   [UInt64: PendingRequest] = [:]
    /// PAGE_READY 待ち専用 Continuation（穎動中に最大1個）
    private var readyCont: CheckedContinuation<Void, Error>?

    private(set) var state: BrowserState = .idle

    // ── バイナリパス ────────────────────────────────────────────────────────
    //
    // 解決順序（配信時・開発時の両方に対応）:
    //   1. Bundle.main の MacOS/ フォルダ内（配信 .app パッケージ）
    //   2. Bundle.main の Resources/ フォルダ内（XcodeGen 経由でコピーされる）
    //   3. Cargo debug ビルド出力（開発専用）
    //   4. Cargo release ビルド出力（開発専用）
    var binaryPath: String {
        // ① アプリバンドル内を最優先（配信時は必ずここにある）
        let bundleMacOS = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/verantyx-browser").path
        if FileManager.default.fileExists(atPath: bundleMacOS) { return bundleMacOS }

        // ② Bundle.main forResource（Resources/ にコピーされたケース）
        if let bundleRes = Bundle.main.path(forResource: "verantyx-browser", ofType: nil) {
            return bundleRes
        }

        // ③④ 開発時 Cargo ビルド出力
        let root    = projectRoot
        let debug   = "\(root)/VerantyxIDE/verantyx-browser/target/debug/verantyx-browser"
        let release = "\(root)/VerantyxIDE/verantyx-browser/target/release/verantyx-browser"
        let fallbackDebug = "\(root)/verantyx-browser/target/debug/verantyx-browser"
        let fallbackRelease = "\(root)/verantyx-browser/target/release/verantyx-browser"

        if FileManager.default.fileExists(atPath: debug)   { return debug }
        if FileManager.default.fileExists(atPath: release) { return release }
        if FileManager.default.fileExists(atPath: fallbackDebug)   { return fallbackDebug }
        if FileManager.default.fileExists(atPath: fallbackRelease) { return fallbackRelease }

        // フォールバック（起動失敗エラーで詳細パスをログ出力させる）
        return debug
    }

    private var projectRoot: String {
        var url = Bundle.main.bundleURL
        
        // 1. バンドル階層から親を辿る（標準構成用）
        for _ in 0..<8 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("verantyx-browser").path) {
                return url.path
            }
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("VerantyxIDE/verantyx-browser").path) {
                return url.path
            }
        }
        
        // 2. #fileマクロベースの相対位置（ソースファイルからの相対位置）
        let srcPath = URL(fileURLWithPath: #file)
        var parent = srcPath
        for _ in 0..<8 {
            parent = parent.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: parent.appendingPathComponent("verantyx-browser").path) {
                return parent.path
            }
            if FileManager.default.fileExists(atPath: parent.appendingPathComponent("VerantyxIDE/verantyx-browser").path) {
                return parent.path
            }
        }
        
        // 3. ハードコードフォールバック（開発時の確実な代替手段）
        return "/Users/motonishikoudai/verantyx-cli"
    }

    // MARK: - Launch

    func launch(visible: Bool = true) async throws {
        // .error(...) は内容問わず再起動を許可（空文字列のみ一致していたバグを修正）
        if case .launching = state { return }
        if case .ready     = state { return }
        state = .launching

        let path = binaryPath
        guard FileManager.default.fileExists(atPath: path) else {
            let msg = "Binary not found: \(path)"
            state = .error(msg)
            throw BrowserError.binaryNotFound(path)
        }

        let proc   = Process()
        let stdin  = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()

        proc.executableURL     = URL(fileURLWithPath: path)
        proc.arguments         = ["--bridge"] + (visible ? ["--visible"] : [])
        proc.standardInput     = stdin
        proc.standardOutput    = stdout
        proc.standardError     = stderr
        proc.qualityOfService  = .userInitiated

        try proc.run()
        
        if visible {
            let pid = proc.processIdentifier
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s wait
                if let app = NSRunningApplication(processIdentifier: pid) {
                    app.activate(options: [.activateIgnoringOtherApps])
                }
            }
        }

        self.process   = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout

        // ── stdout リーダータスク ──────────────────────────────────────────
        readerTask = Task.detached(priority: .high) { [weak self] in
            let handle = stdout.fileHandleForReading
            var buffer = ""
            while true {
                let data = handle.availableData
                if data.isEmpty {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    if Task.isCancelled { break }
                    continue
                }
                guard let chunk = String(data: data, encoding: .utf8) else { continue }
                buffer += chunk
                while let nl = buffer.range(of: "\n") {
                    let line = String(buffer[..<nl.lowerBound]).trimmingCharacters(in: .whitespaces)
                    buffer.removeSubrange(..<nl.upperBound)
                    guard !line.isEmpty else { continue }
                    if let resp = try? JSONDecoder().decode(BrowserResponse.self, from: Data(line.utf8)) {
                        await self?.handleResponse(resp)
                    }
                }
                if Task.isCancelled { break }
            }
        }

        // PAGE_READY を待つ（最大 6 秒）
        try await waitForReady(timeout: 6)
        state = .ready
    }

    // MARK: - Public API

    /// URL に移動して Markdown を返す（HITL_DONE 待ち）
    func fetch(_ url: String, entropy: [[Double]]? = nil, keyboardEntropy: [Double]? = nil, target: [Double]? = nil) async throws -> String {
        try await ensureRunning()
        
        // --- Activate the browser window before injecting trajectory ---
        if let pid = self.process?.processIdentifier {
            await MainActor.run {
                if let app = NSRunningApplication(processIdentifier: pid) {
                    app.activate(options: [.activateIgnoringOtherApps])
                }
            }
            // Give macOS a tiny fraction of a second to bring the window forward
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        
        let id = makeID()
        let resp: BrowserResponse = try await withCheckedThrowingContinuation { cont in
            pending[id] = PendingRequest(kind: .markdown, continuation: cont)
            try? send(BrowserCommand(cmd: "navigate", url: url, id: id, entropy: entropy, keyboard_entropy: keyboardEntropy, target: target))
            // タイムアウト: 20秒
            Task { try? await Task.sleep(nanoseconds: 20_000_000_000); self.expire(id: id) }
        }
        return resp.markdown ?? ""
    }

    /// 現在ページを Markdown で取得
    func getPage() async throws -> String {
        try await ensureRunning()
        let id = makeID()
        let resp: BrowserResponse = try await withCheckedThrowingContinuation { cont in
            pending[id] = PendingRequest(kind: .markdown, continuation: cont)
            try? send(BrowserCommand(cmd: "get_page", id: id))
            Task { try? await Task.sleep(nanoseconds: 12_000_000_000); self.expire(id: id) }
        }
        return resp.markdown ?? ""
    }

    /// JavaScript を実行して結果を返す
    func evalJS(_ script: String) async throws -> String {
        try await ensureRunning()
        let id = makeID()
        let resp: BrowserResponse = try await withCheckedThrowingContinuation { cont in
            pending[id] = PendingRequest(kind: .eval, continuation: cont)
            try? send(BrowserCommand(cmd: "eval_js", text: script, id: id))
            Task { try? await Task.sleep(nanoseconds: 12_000_000_000); self.expire(id: id) }
        }
        return resp.message ?? ""
    }

    /// テキストをキーボードエントロピー（タイピングリズム）に従って入力する
    func typeText(_ text: String, keyboardEntropy: [Double]? = nil) async throws {
        try await ensureRunning()
        
        // Activate browser window to ensure it has focus before typing
        if let pid = self.process?.processIdentifier {
            await MainActor.run {
                if let app = NSRunningApplication(processIdentifier: pid) {
                    app.activate(options: [.activateIgnoringOtherApps])
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        
        let id = makeID()
        let _: BrowserResponse = try await withCheckedThrowingContinuation { cont in
            pending[id] = PendingRequest(kind: .eval, continuation: cont)
            try? send(BrowserCommand(cmd: "type_text", text: text, id: id, keyboard_entropy: keyboardEntropy))
            // The rust binary might not return anything for type_text, but we send it anyway.
            // Wait, we previously modified this to fire-and-forget. Let's keep it fire-and-forget.
            pending.removeValue(forKey: id)
            cont.resume(returning: BrowserResponse(id: id, status: "ok", message: "type_started"))
        }
    }

    /// Performs a hardware-level click at the given relative (x, y) coordinates within the browser window.
    func hidClick(x: Double, y: Double) async throws {
        guard let proc = process, proc.isRunning else { throw BrowserError.notRunning }
        let pid = proc.processIdentifier

        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]],
              let windowInfo = windowList.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }),
              let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
              let windowX = boundsDict["X"] as? Double,
              let windowY = boundsDict["Y"] as? Double else {
            throw BrowserError.ioError("Could not find window bounds for HID click")
        }

        // Calculate absolute screen coordinates
        let screenX = windowX + x
        let screenY = windowY + y

        let point = CGPoint(x: screenX, y: screenY)

        // Ensure browser is active
        await MainActor.run {
            if let app = NSRunningApplication(processIdentifier: pid) {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Dispatch HID events
        guard let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw BrowserError.ioError("Failed to create CGEvent")
        }

        mouseDown.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms click hold
        mouseUp.post(tap: .cghidEventTap)
    }

    /// ヘルスチェック（プロセスが生きているか確認）
    func ping() async -> Bool {
        guard let proc = process, proc.isRunning else { return false }
        let id = makeID()
        do {
            return try await withCheckedThrowingContinuation { cont in
                pending[id] = PendingRequest(kind: .pong, continuation: cont)
                try? send(BrowserCommand(cmd: "ping", id: id))
                Task {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    self.expire(id: id)
                }
            }.status == "pong"
        } catch {
            return false
        }
    }

    /// プロセスを終了する
    func quit() {
        try? send(BrowserCommand(cmd: "quit"))
        process?.terminate()
        process    = nil
        readerTask?.cancel()
        readerTask = nil
        state      = .idle
        // 残 pending をすべてキャンセル
        for (_, req) in pending {
            req.continuation.resume(throwing: BrowserError.notRunning)
        }
        pending.removeAll()
    }

    // MARK: - Private: response routing

    private func handleResponse(_ resp: BrowserResponse) {
        // PAGE_READY → readyCont を優先して resume
        if resp.status == "ok", resp.message == "ready" || resp.message == "ready_timeout" {
            if let cont = readyCont {
                readyCont = nil
                cont.resume(returning: ())
                return
            }
        }

        guard let id = resp.id, let req = pending[id] else { return }

        switch req.kind {
        case .markdown:
            // "navigating" は中間状態 — hitl_done / ok (with markdown) が最終
            if resp.status == "navigating" { return }
            pending.removeValue(forKey: id)
            req.continuation.resume(returning: resp)
        case .eval:
            guard resp.status == "eval_ok" || resp.status == "eval_err" else { return }
            pending.removeValue(forKey: id)
            if resp.status == "eval_err" {
                req.continuation.resume(throwing: BrowserError.jsError(resp.message ?? "unknown"))
            } else {
                req.continuation.resume(returning: resp)
            }
        case .pong:
            guard resp.status == "pong" else { return }
            pending.removeValue(forKey: id)
            req.continuation.resume(returning: resp)
        }
    }

    // MARK: - Private: helpers

    private func makeID() -> UInt64 {
        let id = nextID
        nextID &+= 1
        return id
    }

    private func send(_ cmd: BrowserCommand) throws {
        guard let pipe = stdinPipe else { throw BrowserError.notRunning }
        let data = try JSONEncoder().encode(cmd)
        var line = data
        line.append(0x0A)  // newline delimiter

        // SIGPIPE-safe write: fileHandleForWriting.write() は SIGPIPE を
        // 内部で握り潰さず、かつ SIG_IGN 無効時にクラッシュする。
        // FileHandle の fileDescriptor に直接 write(2) することで
        // EPIPE エラーをキャッチして BrowserError.notRunning を投げる。
        let fd = pipe.fileHandleForWriting.fileDescriptor
        var remaining = line.count
        var offset = 0
        
        while remaining > 0 {
            let result = line.withUnsafeBytes { ptr -> Int in
                Darwin.write(fd, ptr.baseAddress! + offset, remaining)
            }
            if result < 0 {
                let code = errno
                throw code == EPIPE
                    ? BrowserError.notRunning                          // プロセスが既に死んでいる
                    : BrowserError.ioError("write(2) errno=\(code)")  // その他 I/O エラー
            }
            remaining -= result
            offset += result
        }
    }

    private func expire(id: UInt64) {
        guard let req = pending[id] else { return }
        pending.removeValue(forKey: id)
        req.continuation.resume(throwing: BrowserError.timeout)
        self.quit() // Forcefully terminate the stuck process so it restarts on next fetch
    }

    private func waitForReady(timeout: Double) async throws {
        // Void Continuation で PAGE_READY を待つ（型安全）
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.readyCont = cont
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if self.readyCont != nil {
                    self.readyCont = nil
                    cont.resume(returning: ())
                }
            }
        }
    }

    func ensureRunning() async throws {
        if let proc = process, proc.isRunning { return }
        state = .idle
        try await launch()
    }

    /// Captures a screenshot of the verantyx-browser window.
    func takeScreenshot() async throws -> String {
        guard let proc = process, proc.isRunning else { throw BrowserError.notRunning }
        let pid = proc.processIdentifier

        // Get window list
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            throw BrowserError.ioError("Failed to get window list")
        }

        // Find window for this process
        guard let windowInfo = windowList.first(where: { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }),
              let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID else {
            throw BrowserError.ioError("Could not find window for PID \(pid)")
        }

        // Create image
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, .boundsIgnoreFraming) else {
            throw BrowserError.ioError("Failed to create image from window")
        }

        let bitmapRep = NSBitmapImageRep(cgImage: image)
        guard let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw BrowserError.ioError("Failed to encode image to JPEG")
        }

        return jpegData.base64EncodedString()
    }
}

// MARK: - BrowserError

enum BrowserError: Error, LocalizedError {
    case binaryNotFound(String)
    case notRunning
    case timeout
    case jsError(String)
    case ioError(String)           // write(2) / pipe I/O failure

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let p): return "verantyx-browser not found at \(p). Run: cargo build -p vx-browser"
        case .notRunning:            return "Browser not running."
        case .timeout:               return "Browser operation timed out."
        case .jsError(let e):        return "JS error: \(e)"
        case .ioError(let e):        return "Browser I/O error: \(e)"
        }
    }
}

// MARK: - SafariVisionBridge

class SafariVisionBridge {
    static let shared = SafariVisionBridge()

    private let appName = "Safari"

    func navigate(_ url: String) async throws {
        let script = """
        tell application "Safari"
            activate
            if (count every document) = 0 then
                make new document
            end if
            set URL of document 1 to "\(url)"
        end tell
        """
        try await runAppleScript(script)
        try await Task.sleep(nanoseconds: 2_000_000_000) // Wait for load
    }

    func takeScreenshot() async throws -> String {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            throw BrowserError.ioError("Please grant Screen Recording permission in System Settings -> Privacy & Security, then restart the app.")
        }

        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            throw BrowserError.ioError("Failed to get window list")
        }

        // Find the FIRST REAL Safari window (layer 0, reasonable size)
        guard let windowInfo = windowList.first(where: { info in
            guard (info[kCGWindowOwnerName as String] as? String) == appName else { return false }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { return false }
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let height = bounds["Height"] as? Double, height > 100 else { return false }
            return true
        }),
              let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID else {
            throw BrowserError.ioError("Could not find main window for \(appName)")
        }

        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, windowID, .boundsIgnoreFraming) else {
            throw BrowserError.ioError("Failed to create image from window. Check Screen Recording permissions.")
        }

        let bitmapRep = NSBitmapImageRep(cgImage: image)
        guard let jpegData = bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
            throw BrowserError.ioError("Failed to encode image to JPEG")
        }

        return jpegData.base64EncodedString()
    }

    func hidClick(x: Double, y: Double) async throws {
        let options = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]],
              let windowInfo = windowList.first(where: { info in
                  guard (info[kCGWindowOwnerName as String] as? String) == appName else { return false }
                  guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { return false }
                  guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                        let height = bounds["Height"] as? Double, height > 100 else { return false }
                  return true
              }),
              let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: Any],
              let windowX = boundsDict["X"] as? Double,
              let windowY = boundsDict["Y"] as? Double else {
            throw BrowserError.ioError("Could not find main window bounds for \(appName)")
        }

        // Activate Safari
        let script = """
        tell application "Safari" to activate
        """
        try? await runAppleScript(script)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let screenX = windowX + x
        let screenY = windowY + y
        let point = CGPoint(x: screenX, y: screenY)

        guard let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            throw BrowserError.ioError("Failed to create CGEvent")
        }

        mouseDown.post(tap: .cghidEventTap)
        try? await Task.sleep(nanoseconds: 50_000_000)
        mouseUp.post(tap: .cghidEventTap)
    }

    func typeText(_ text: String) async throws {
        // Activate Safari
        let script = """
        tell application "Safari" to activate
        """
        try? await runAppleScript(script)
        try? await Task.sleep(nanoseconds: 100_000_000)

        let source = CGEventSource(stateID: .hidSystemState)
        for char in text {
            let s = String(char)
            var buf = [UInt16](repeating: 0, count: s.utf16.count)
            let _ = s.utf16.map { $0 }.withUnsafeBufferPointer { ptr in
                for i in 0..<ptr.count { buf[i] = ptr[i] }
            }

            if let eventDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                eventDown.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf)
                eventDown.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
            if let eventUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                eventUp.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf)
                eventUp.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func runAppleScript(_ script: String) async throws {
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                if let appleScript = NSAppleScript(source: script) {
                    var errorInfo: NSDictionary?
                    appleScript.executeAndReturnError(&errorInfo)
                    if let err = errorInfo {
                        cont.resume(throwing: BrowserError.ioError("AppleScript error: \(err)"))
                    } else {
                        cont.resume(returning: ())
                    }
                } else {
                    cont.resume(throwing: BrowserError.ioError("Failed to compile AppleScript"))
                }
            }
        }
    }
}
