import Foundation
import os

// MARK: - MCPBridgeLauncher
//
// Automatically starts the Verantyx MCP Bridge (Node.js, port 5420) at IDE launch.
// The bridge exposes /skills/version and /health used by MCPSkillSync.
//
// Strategy:
//   1. Locate `node` binary via PATH resolution.
//   2. Find the server entry point: `<project>/src/verantyx/mcp/server.ts`
//   3. Launch using `node --import tsx <server.ts>` from the project root.
//   4. Monitor the process — restart on crash with exponential backoff (3s → 6s → 12s → cap 60s).
//   5. Verify the bridge is healthy via GET /health before reporting `isRunning = true`.
//   6. On app quit, terminate the child process.
//
// Usage (VerantyxApp.swift):
//   MCPBridgeLauncher.shared.start()          // call in .onAppear
//   MCPBridgeLauncher.shared.stop()           // call in applicationShouldTerminate

@MainActor
final class MCPBridgeLauncher: ObservableObject {

    static let shared = MCPBridgeLauncher()

    // ── Published state ────────────────────────────────────────────────────────
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var launchError: String? = nil

    // ── Constants ─────────────────────────────────────────────────────────────
    private let bridgePort     = 5420
    private let maxBackoff:  TimeInterval = 60
    private let healthURL      = URL(string: "http://127.0.0.1:5420/health")!
    private let healthTimeout:TimeInterval = 3.0

    // ── Internal state ────────────────────────────────────────────────────────
    private var process: Process?
    private var monitorTask: Task<Void, Never>?
    private var consecutiveCrashes = 0
    private var didStop = false

    /// EADDRINUSE 対策: 起動前に port 5420 を保持しているプロセスを kill する。
    private func killZombieOnPort() {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-ti", "tcp:\(bridgePort)"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError  = FileHandle.nullDevice
        try? lsof.run()
        lsof.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for pidStr in out.components(separatedBy: .newlines) {
            let trimmed = pidStr.trimmingCharacters(in: .whitespaces)
            guard let pid = Int32(trimmed), pid > 0 else { continue }
            kill(pid, SIGTERM)
            print("[MCPBridgeLauncher] 🔪 Killed zombie PID \(pid) holding port \(bridgePort)")
        }
        // ゾンビが終了するまで 0.3s 待機
        Thread.sleep(forTimeInterval: 0.3)
    }

    private init() {}

    // MARK: - Public API

    func start() {
        guard monitorTask == nil else { return }
        didStop = false
        consecutiveCrashes = 0
        launchError = nil
        monitorTask = Task { await self.runLoop() }
    }

    func stop() {
        didStop = true
        monitorTask?.cancel()
        monitorTask = nil
        terminateProcess()
    }

    // MARK: - Run Loop

    private func runLoop() async {
        while !Task.isCancelled && !didStop {
            // Backoff before respawn (skip on first launch)
            if consecutiveCrashes > 0 {
                let backoff = min(3.0 * pow(2.0, Double(consecutiveCrashes - 1)), maxBackoff)
                print("[MCPBridgeLauncher] Crash #\(consecutiveCrashes) — respawning in \(Int(backoff))s")
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                if Task.isCancelled || didStop { return }
            }

            await launch()
        }
    }

    // MARK: - Launch

    private func launch() async {
        guard let (nodeBin, serverScript, projectRoot) = resolvePaths() else {
            launchError = "Cannot locate node binary or MCP server script."
            print("[MCPBridgeLauncher] ❌ \(launchError!)")
            didStop = true   // don't retry — environment is broken
            return
        }

        // ─── 既存ゾンビを kill してから起動する ─────────────────────────────
        killZombieOnPort()

        let proc = Process()
        proc.executableURL = nodeBin

        // tsx をローカルの node_modules から使う
        let tsxBin = projectRoot
            .appendingPathComponent("node_modules/.bin/tsx")
        let usesTsx = FileManager.default.fileExists(atPath: tsxBin.path)

        if usesTsx {
            proc.arguments = ["--import", "tsx", serverScript.path]
        } else {
            proc.arguments = [serverScript.path]
        }

        proc.currentDirectoryURL = projectRoot
        proc.environment = buildEnv(nodeBin: nodeBin)

        // Pipe stderr so we can log it; stdout goes to /dev/null (stdio MCP path)
        let errPipe = Pipe()
        proc.standardError  = errPipe
        proc.standardOutput = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            launchError = "Failed to launch MCP bridge: \(error.localizedDescription)"
            print("[MCPBridgeLauncher] ❌ \(launchError!)")
            consecutiveCrashes += 1
            return
        }

        process = proc
        print("[MCPBridgeLauncher] ✅ Launched PID \(proc.processIdentifier) (tsx=\(usesTsx))")

        // Pipe stderr → Console asynchronously
        Task.detached(priority: .utility) {
            let handle = errPipe.fileHandleForReading
            while true {
                let data = handle.availableData
                if data.isEmpty { break }
                if let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines),
                   !line.isEmpty {
                    print("[MCPBridge] \(line)")
                }
            }
        }

        // Wait for /health to come up (up to 10s)
        let healthy = await waitForHealth()
        if healthy {
            isRunning     = true
            launchError   = nil
            consecutiveCrashes = 0
            print("[MCPBridgeLauncher] 🌐 Bridge healthy on port \(bridgePort)")
        } else {
            print("[MCPBridgeLauncher] ⚠️ Bridge did not become healthy within 10s")
        }

        // ─── Block until process exits ────────────────────────────────────────
        // atomic フラグで resume() が2回呼ばれないことを保証する
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let resumed = _AtomicFlag()
            proc.terminationHandler = { _ in
                if resumed.trySet() { cont.resume() }
            }
            // プロセスが handler 登録前に終了していたケース
            if !proc.isRunning {
                if resumed.trySet() { cont.resume() }
            }
        }

        isRunning = false
        process   = nil
        consecutiveCrashes += 1
        print("[MCPBridgeLauncher] ⚠️ Bridge exited (code \(proc.terminationStatus))")
    }

    // MARK: - Health check

    private func waitForHealth() async -> Bool {
        let deadline = Date().addingTimeInterval(10)
        let session  = URLSession(configuration: {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest  = healthTimeout
            c.timeoutIntervalForResource = healthTimeout
            c.waitsForConnectivity       = false
            return c
        }())

        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s
            if Task.isCancelled { return false }
            if let (_, resp) = try? await session.data(from: healthURL),
               (resp as? HTTPURLResponse)?.statusCode == 200 {
                return true
            }
        }
        return false
    }

    // MARK: - Path resolution

    /// Returns (nodeBinary, serverScript, projectRoot) or nil if not found.
    private func resolvePaths() -> (URL, URL, URL)? {
        // 1. node binary
        guard let nodeBin = findNode() else { return nil }

        // 2. Project root = verantyx-cli (two levels above VerantyxIDE)
        //    VerantyxIDE is at <project>/VerantyxIDE
        //    Bundle.main is inside DerivedData, so we use a fixed home-relative path.
        let candidates: [URL] = [
            // During development: resolve from the verantyx-browser sibling
            URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("verantyx-cli"),
            // Alternate locations
            URL(fileURLWithPath: "/Users/motonishikoudai/verantyx-cli"),
        ]

        for root in candidates {
            let serverScript = root
                .appendingPathComponent("src/verantyx/mcp/server.ts")
            if FileManager.default.fileExists(atPath: serverScript.path) {
                return (nodeBin, serverScript, root)
            }
        }
        return nil
    }

    private func findNode() -> URL? {
        // Fast path: known Homebrew / nvm location
        let knownPaths = [
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/bin/node",
            "\(NSHomeDirectory())/.nvm/versions/node/default/bin/node",
        ]
        for p in knownPaths {
            if FileManager.default.fileExists(atPath: p) {
                return URL(fileURLWithPath: p)
            }
        }
        // Fallback: ask `which node`
        let proc  = Process()
        let pipe  = Pipe()
        proc.executableURL    = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments        = ["node"]
        proc.standardOutput   = pipe
        proc.standardError    = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !output.isEmpty { return URL(fileURLWithPath: output) }
        return nil
    }

    private func buildEnv(nodeBin: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Ensure PATH includes the directory containing node
        let nodeDir = nodeBin.deletingLastPathComponent().path
        let existingPath = env["PATH"] ?? "/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = "\(nodeDir):\(existingPath)"
        // tsx needs this to resolve TypeScript at runtime
        env["NODE_NO_WARNINGS"] = "1"
        return env
    }

    // MARK: - Teardown

    private func terminateProcess() {
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()
        // Give it 2s to clean up, then force-kill
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if proc.isRunning { proc.interrupt() }
        }
        process = nil
    }
}

// MARK: - _AtomicFlag (internal helper)
//
// withCheckedContinuation で resume() が2回呼ばれることを防ぐための
// スレッドセーフな one-shot フラグ。
// - terminationHandler と「既に終了済み」ガードが両方発火するレースを防ぐ。

final class _AtomicFlag: @unchecked Sendable {
    private var _lock = os_unfair_lock()
    private var _set  = false

    /// 初回呼び出しのみ true を返す。以降は false。
    func trySet() -> Bool {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        guard !_set else { return false }
        _set = true
        return true
    }
}
