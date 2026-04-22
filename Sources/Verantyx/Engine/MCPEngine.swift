import Foundation
import SwiftUI

// MARK: - MCPEngine
//
// Model Context Protocol client for Verantyx IDE.
// Supports:
//   • stdio transport (subprocess with JSON-RPC 2.0 over stdin/stdout)
//   • HTTP/SSE transport (POST to /messages endpoint)
//
// Two execution modes:
//   • .ai    — No timeout. AI agent can call tools indefinitely.
//              Kill switch available in MCPView for deadlock recovery.
//   • .human — 60-second timeout per tool call. Returns error on timeout.

// MARK: - Data models

struct MCPServerConfig: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var transport: Transport
    var command: String          // stdio: full command e.g. "npx -y @modelcontextprotocol/server-filesystem /"
    var url: String              // http: e.g. "http://localhost:3000"
    var envVars: [String: String]
    var isEnabled: Bool
    var mode: ExecutionMode

    enum Transport: String, Codable, CaseIterable {
        case stdio = "stdio"
        case http  = "http"
    }

    enum ExecutionMode: String, Codable, CaseIterable {
        case ai    = "AI Priority"     // no timeout
        case human = "Human Mode"      // 60s timeout
    }

    init(id: UUID = UUID(), name: String, transport: Transport = .stdio,
         command: String = "", url: String = "", envVars: [String: String] = [:],
         isEnabled: Bool = true, mode: ExecutionMode = .ai) {
        self.id = id; self.name = name; self.transport = transport
        self.command = command; self.url = url; self.envVars = envVars
        self.isEnabled = isEnabled; self.mode = mode
    }

    static let examples: [MCPServerConfig] = [
        MCPServerConfig(name: "Filesystem", transport: .stdio,
                        command: "npx -y @modelcontextprotocol/server-filesystem /",
                        mode: .ai),
        MCPServerConfig(name: "GitHub", transport: .stdio,
                        command: "npx -y @modelcontextprotocol/server-github",
                        envVars: ["GITHUB_PERSONAL_ACCESS_TOKEN": ""],
                        mode: .ai),
        MCPServerConfig(name: "Brave Search", transport: .stdio,
                        command: "npx -y @modelcontextprotocol/server-brave-search",
                        envVars: ["BRAVE_API_KEY": ""],
                        mode: .human),
        MCPServerConfig(name: "Local HTTP", transport: .http,
                        url: "http://localhost:3000",
                        mode: .human),
    ]
}

struct MCPTool: Identifiable, Codable {
    let id: UUID
    let name: String
    let description: String
    let inputSchema: [String: AnyCodable]
    let serverName: String

    init(name: String, description: String, inputSchema: [String: AnyCodable] = [:], serverName: String) {
        self.id = UUID(); self.name = name; self.description = description
        self.inputSchema = inputSchema; self.serverName = serverName
    }
}

// Utility wrapper for heterogeneous JSON values
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { value = v; return }
        if let v = try? c.decode(Int.self)  { value = v; return }
        if let v = try? c.decode(Double.self) { value = v; return }
        if let v = try? c.decode(String.self) { value = v; return }
        if let v = try? c.decode([String: AnyCodable].self) { value = v; return }
        if let v = try? c.decode([AnyCodable].self) { value = v; return }
        value = NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let v as Bool:   try c.encode(v)
        case let v as Int:    try c.encode(v)
        case let v as Double: try c.encode(v)
        case let v as String: try c.encode(v)
        case let v as [String: AnyCodable]: try c.encode(v)
        case let v as [AnyCodable]: try c.encode(v)
        default: try c.encodeNil()
        }
    }
}

// MARK: - MCPCallRecord (for process log / kill switch)

struct MCPCallRecord: Identifiable {
    let id = UUID()
    let serverName: String
    let toolName: String
    let startTime: Date
    var status: Status
    var elapsedSeconds: Int { Int(Date().timeIntervalSince(startTime)) }
    var task: Task<String, Error>?

    enum Status { case running, completed, timedOut, cancelled, failed(String) }

    var statusLabel: String {
        switch status {
        case .running:        return "RUNNING  \(elapsedSeconds)s"
        case .completed:      return "DONE"
        case .timedOut:       return "TIMEOUT"
        case .cancelled:      return "KILLED"
        case .failed(let e):  return "ERR: \(e.prefix(30))"
        }
    }

    var statusColor: Color {
        switch status {
        case .running:     return Color(red: 0.9, green: 0.7, blue: 0.2)
        case .completed:   return Color(red: 0.3, green: 0.9, blue: 0.5)
        case .timedOut:    return .orange
        case .cancelled:   return .red
        case .failed:      return Color(red: 0.9, green: 0.4, blue: 0.4)
        }
    }
}

// MARK: - MCPEngine (Actor)

@MainActor
final class MCPEngine: ObservableObject {

    static let shared = MCPEngine()

    // MARK: - Published state

    @Published var servers: [MCPServerConfig] = [] {
        didSet { saveServers() }
    }
    @Published var connectedTools: [MCPTool] = []
    @Published var activeCall: MCPCallRecord?
    @Published var callHistory: [MCPCallRecord] = []
    @Published var connectionStatus: [UUID: ConnectionStatus] = [:] // server id → status

    enum ConnectionStatus { case disconnected, connecting, connected, error(String) }

    // MARK: - Private state

    private var stdioProcesses: [UUID: Process] = [:]

    private static let storageKey = "mcp_servers_v1"

    /// Current execution mode — updated when OperationMode changes.
    @Published var currentExecutionMode: MCPServerConfig.ExecutionMode = .human

    /// Called by AppState when OperationMode switches.
    func setMode(_ mode: MCPServerConfig.ExecutionMode) {
        DispatchQueue.main.async {
            self.currentExecutionMode = mode
        }
    }

    init() { loadServers() }

    // MARK: - Server CRUD

    func addServer(_ config: MCPServerConfig) { servers.append(config) }

    func removeServer(id: UUID) {
        terminateProcess(for: id)
        servers.removeAll { $0.id == id }
        connectedTools.removeAll { $0.serverName == servers.first { $0.id == id }?.name ?? "" }
        connectionStatus.removeValue(forKey: id)
    }

    func updateServer(_ config: MCPServerConfig) {
        if let idx = servers.firstIndex(where: { $0.id == config.id }) {
            servers[idx] = config
        }
    }

    // MARK: - Connect / discover tools

    func connectAll() async {
        for server in servers where server.isEnabled {
            await connect(server: server)
        }
    }

    func connect(server: MCPServerConfig) async {
        connectionStatus[server.id] = .connecting
        do {
            let tools = try await discoverTools(server: server)
            connectedTools.removeAll { $0.serverName == server.name }
            connectedTools.append(contentsOf: tools)
            connectionStatus[server.id] = .connected
        } catch {
            connectionStatus[server.id] = .error(error.localizedDescription)
        }
    }

    func disconnect(serverId: UUID) {
        terminateProcess(for: serverId)
        if let server = servers.first(where: { $0.id == serverId }) {
            connectedTools.removeAll { $0.serverName == server.name }
        }
        connectionStatus[serverId] = .disconnected
    }

    // MARK: - Tool execution

    /// Call a tool. Mode defaults to currentExecutionMode (set by OperationMode).
    func callTool(serverName: String, toolName: String,
                  arguments: [String: Any],
                  mode: MCPServerConfig.ExecutionMode? = nil) async -> String {
        let resolvedMode = mode ?? currentExecutionMode
        guard let server = servers.first(where: { $0.name == serverName && $0.isEnabled }) else {
            return "[MCP] Server '\(serverName)' not found or disabled"
        }

        var record = MCPCallRecord(serverName: serverName, toolName: toolName,
                                   startTime: Date(), status: .running)
        activeCall = record

        // Log to process log
        NotificationCenter.default.post(
            name: .mcpToolCalled,
            object: nil,
            userInfo: ["server": serverName, "tool": toolName]
        )

        // Build async task
        let execTask = Task<String, Error> {
            try await self.executeToolRequest(server: server, toolName: toolName, arguments: arguments)
        }
        record.task = execTask

        do {
            let result: String
            if resolvedMode == .human {
                // 60-second timeout for human mode
                result = try await withTimeout(seconds: 60, task: execTask)
            } else {
                // AI mode — no system timeout, but task is cancellable via kill switch
                result = try await execTask.value
            }
            var completed = record
            completed.status = .completed
            callHistory.insert(completed, at: 0)
            if callHistory.count > 100 { callHistory.removeLast(50) }
            activeCall = nil
            return result
        } catch is CancellationError {
            var cancelled = record
            cancelled.status = .cancelled
            callHistory.insert(cancelled, at: 0)
            activeCall = nil
            return "[MCP] Tool call cancelled by user"
        } catch MCPError.timeout {
            var to = record
            to.status = .timedOut
            callHistory.insert(to, at: 0)
            activeCall = nil
            return "[MCP] Tool '\(toolName)' timed out after 60s"
        } catch {
            var failed = record
            failed.status = .failed(error.localizedDescription)
            callHistory.insert(failed, at: 0)
            activeCall = nil
            return "[MCP] Error: \(error.localizedDescription)"
        }
    }

    /// KILL SWITCH — cancel the currently running tool call immediately.
    func killActiveCall() {
        activeCall?.task?.cancel()
        if var a = activeCall {
            a.status = .cancelled
            callHistory.insert(a, at: 0)
        }
        activeCall = nil
    }

    // MARK: - Private: tool discovery

    private func discoverTools(server: MCPServerConfig) async throws -> [MCPTool] {
        switch server.transport {
        case .stdio:
            return try await discoverToolsStdio(server: server)
        case .http:
            return try await discoverToolsHTTP(server: server)
        }
    }

    private func discoverToolsStdio(server: MCPServerConfig) async throws -> [MCPTool] {
        // Send initialize + tools/list over stdio
        let response = try await sendStdioRequest(server: server,
            method: "tools/list", params: [:])
        return parseTools(from: response, serverName: server.name)
    }

    private func discoverToolsHTTP(server: MCPServerConfig) async throws -> [MCPTool] {
        guard let url = URL(string: server.url + "/tools/list") else {
            throw MCPError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": [:]
        ])
        req.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return parseTools(from: json, serverName: server.name)
    }

    // MARK: - Private: tool execution

    private func executeToolRequest(server: MCPServerConfig,
                                    toolName: String,
                                    arguments: [String: Any]) async throws -> String {
        let params: [String: Any] = ["name": toolName, "arguments": arguments]

        switch server.transport {
        case .stdio:
            let resp = try await sendStdioRequest(server: server,
                                                  method: "tools/call", params: params)
            return extractTextContent(from: resp)
        case .http:
            guard let url = URL(string: server.url + "/tools/call") else {
                throw MCPError.invalidURL
            }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": UUID().uuidString,
                "method": "tools/call", "params": params
            ])
            // No URLSession timeout for AI mode — Task.cancel() handles it
            let (data, _) = try await URLSession.shared.data(for: req)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            return extractTextContent(from: json)
        }
    }

    // MARK: - Private: stdio subprocess

    private func sendStdioRequest(server: MCPServerConfig,
                                  method: String,
                                  params: [String: Any]) async throws -> [String: Any] {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let process = Process()
                    let components = server.command.components(separatedBy: " ")
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = components

                    var env = ProcessInfo.processInfo.environment
                    server.envVars.forEach { env[$0.key] = $0.value }
                    process.environment = env

                    let stdin  = Pipe()
                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardInput  = stdin
                    process.standardOutput = stdout
                    process.standardError  = stderr

                    try process.run()

                    // MCP handshake — initialize first
                    let initReq: [String: Any] = [
                        "jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": [
                            "protocolVersion": "2024-11-05",
                            "capabilities": ["tools": [:], "resources": [:]],
                            "clientInfo": ["name": "Verantyx", "version": "0.1"]
                        ]
                    ]
                    let toolReq: [String: Any] = [
                        "jsonrpc": "2.0", "id": 2, "method": method, "params": params
                    ]
                    let notif: [String: Any] = [
                        "jsonrpc": "2.0", "method": "notifications/initialized"
                    ]

                    func sendJSON(_ obj: [String: Any]) {
                        if let data = try? JSONSerialization.data(withJSONObject: obj),
                           let line = String(data: data, encoding: .utf8) {
                            if let d = (line + "\n").data(using: .utf8) {
                                stdin.fileHandleForWriting.write(d)
                            }
                        }
                    }

                    sendJSON(initReq)
                    Thread.sleep(forTimeInterval: 0.3)
                    sendJSON(notif)
                    sendJSON(toolReq)
                    Thread.sleep(forTimeInterval: 0.5)

                    stdin.fileHandleForWriting.closeFile()

                    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                    process.terminate()
                    process.waitUntilExit()

                    // Parse last JSON-RPC response from stdout
                    let lines = String(data: outputData, encoding: .utf8)?
                        .components(separatedBy: "\n")
                        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        ?? []

                    var lastResult: [String: Any] = [:]
                    for line in lines.reversed() {
                        if let d = line.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                           json["id"] != nil {
                            lastResult = json
                            break
                        }
                    }
                    continuation.resume(returning: lastResult)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Private: helpers

    private func parseTools(from json: [String: Any], serverName: String) -> [MCPTool] {
        guard let result = json["result"] as? [String: Any],
              let toolsList = result["tools"] as? [[String: Any]] else { return [] }
        return toolsList.compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            let desc = t["description"] as? String ?? ""
            return MCPTool(name: name, description: desc, serverName: serverName)
        }
    }

    private func extractTextContent(from json: [String: Any]) -> String {
        if let result = json["result"] as? [String: Any] {
            if let content = result["content"] as? [[String: Any]] {
                return content.compactMap { block in
                    block["type"] as? String == "text" ? block["text"] as? String : nil
                }.joined(separator: "\n")
            }
            if let text = result["text"] as? String { return text }
        }
        if let error = json["error"] as? [String: Any] {
            return "[MCP Error] \(error["message"] as? String ?? "Unknown")"
        }
        return json.description
    }

    private func terminateProcess(for id: UUID) {
        stdioProcesses[id]?.terminate()
        stdioProcesses.removeValue(forKey: id)
    }

    // MARK: - Timeout helper

    private func withTimeout<T>(seconds: Double, task: Task<T, Error>) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await task.value }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                task.cancel()
                throw MCPError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Persistence

    private func saveServers() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func loadServers() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([MCPServerConfig].self, from: data) {
            servers = decoded
        }
    }
}

// MARK: - Errors

enum MCPError: LocalizedError {
    case timeout
    case invalidURL
    case noResponse
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .timeout:         return "MCP tool call timed out"
        case .invalidURL:      return "Invalid MCP server URL"
        case .noResponse:      return "No response from MCP server"
        case .decodingFailed:  return "Failed to decode MCP response"
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    static let mcpToolCalled = Notification.Name("mcpToolCalled")
}
