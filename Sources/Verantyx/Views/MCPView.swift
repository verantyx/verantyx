import SwiftUI

// MARK: - MCPView
// MCP management: server list, add/edit, connect, and KILL SWITCH dashboard.

struct MCPView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var mcp = MCPEngine.shared
    @State private var showAddSheet = false
    @State private var editingServer: MCPServerConfig? = nil
    @State private var selectedServerId: UUID? = nil

    var body: some View {
        VStack(spacing: 0) {
            killSwitchBanner   // top priority — always visible when something is running

            HSplitView {
                // ── Left: Server list ─────────────────────────────────
                serverList.frame(minWidth: 220, maxWidth: 300)

                // ── Right: Detail / tool list ─────────────────────────
                if let id = selectedServerId,
                   let server = mcp.servers.first(where: { $0.id == id }) {
                    serverDetail(server)
                } else {
                    emptyDetail
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            MCPServerEditSheet(config: .init(name: "", transport: .stdio, command: "", mode: .ai)) { saved in
                mcp.addServer(saved)
                showAddSheet = false
            }
            .frame(width: 500, height: 520)
        }
        .sheet(item: $editingServer) { server in
            MCPServerEditSheet(config: server) { saved in
                mcp.updateServer(saved)
                editingServer = nil
            }
            .frame(width: 500, height: 520)
        }
    }

    // MARK: - Kill Switch Banner

    @ViewBuilder
    private var killSwitchBanner: some View {
        if let call = mcp.activeCall, case .running = call.status {
            HStack(spacing: 12) {
                // Pulsing red indicator
                Circle()
                    .fill(Color.red)
                    .frame(width: 8, height: 8)
                    .opacity(0.9)

                VStack(alignment: .leading, spacing: 1) {
                    Text("MCP RUNNING")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 1.0, green: 0.4, blue: 0.4))
                    Text("\(call.serverName) → \(call.toolName)  [\(call.elapsedSeconds)s]")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // KILL SWITCH ─────────────────────────────────────────
                Button {
                    mcp.killActiveCall()
                    app.logProcess("KILL SWITCH — '\(call.toolName)' forcibly cancelled", kind: .system)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                        Text("KILL")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.red)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.red.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Color.red.opacity(0.6), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [.command, .shift])
                .help("Force cancel the running MCP tool call (⌘⇧Esc)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(red: 0.25, green: 0.08, blue: 0.08))
            .overlay(alignment: .bottom) {
                Rectangle().fill(Color.red.opacity(0.3)).frame(height: 1)
            }
        }
    }

    // MARK: - Server list

    private var serverList: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("MCP SERVERS")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await mcp.connectAll() }
                } label: {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(red: 0.4, green: 0.9, blue: 0.5))
                }
                .buttonStyle(.plain)
                .help("Connect all enabled servers")

                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(red: 0.09, green: 0.09, blue: 0.12))

            Divider().opacity(0.3)

            if mcp.servers.isEmpty {
                emptyServerList
            } else {
                List(mcp.servers, selection: $selectedServerId) { server in
                    ServerRow(server: server,
                              status: mcp.connectionStatus[server.id] ?? .disconnected)
                    .tag(server.id)
                    .contextMenu {
                        Button("Edit") { editingServer = server }
                        Button("Connect") { Task { await mcp.connect(server: server) } }
                        Button("Disconnect") { mcp.disconnect(serverId: server.id) }
                        Divider()
                        Button("Delete", role: .destructive) { mcp.removeServer(id: server.id) }
                    }
                }
                .listStyle(.sidebar)
            }

            Divider().opacity(0.3)

            // Quick templates
            HStack(spacing: 0) {
                Menu {
                    ForEach(MCPServerConfig.examples) { example in
                        Button(example.name) {
                            mcp.addServer(example)
                        }
                    }
                } label: {
                    Label("Add from template", systemImage: "square.on.square")
                        .font(.system(size: 10))
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                Spacer()
            }
            .background(Color(red: 0.09, green: 0.09, blue: 0.12))
        }
    }

    // MARK: - Server detail

    private func serverDetail(_ server: MCPServerConfig) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // Server info header
                HStack(spacing: 10) {
                    Image(systemName: transportIcon(server.transport))
                        .font(.system(size: 20))
                        .foregroundStyle(statusColor(for: server.id))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(server.name)
                            .font(.system(size: 15, weight: .bold))
                        Text(server.transport == .stdio ? server.command : server.url)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    // Mode badge
                    modeBadge(server.mode)
                }

                // Connection controls
                HStack(spacing: 8) {
                    let status = mcp.connectionStatus[server.id] ?? .disconnected
                    Button {
                        Task { await mcp.connect(server: server) }
                    } label: {
                        Label("Connect", systemImage: "bolt")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isConnecting(server.id))

                    Button {
                        mcp.disconnect(serverId: server.id)
                    } label: {
                        Label("Disconnect", systemImage: "eject")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Edit") { editingServer = server }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                    Spacer()

                    Text(statusLabel(status))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(statusColor(for: server.id))
                }

                Divider().opacity(0.3)

                // Available tools
                let tools = mcp.connectedTools.filter { $0.serverName == server.name }
                if tools.isEmpty {
                    Text("No tools discovered. Connect the server first.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("TOOLS (\(tools.count))")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        ForEach(tools) { tool in
                            ToolRow(tool: tool, serverMode: server.mode) { args in
                                Task {
                                    let result = await mcp.callTool(
                                        serverName: server.name, toolName: tool.name,
                                        arguments: args, mode: server.mode
                                    )
                                    app.addSystemMessage("[\(tool.name)] \(result.prefix(300))")
                                }
                            }
                        }
                    }
                }

                // Call history for this server
                let history = mcp.callHistory.filter { $0.serverName == server.name }
                if !history.isEmpty {
                    Divider().opacity(0.3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("CALL HISTORY")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        ForEach(history.prefix(10)) { record in
                            HStack(spacing: 6) {
                                Circle().fill(record.statusColor).frame(width: 6, height: 6)
                                Text(record.toolName)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(record.statusLabel)
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(record.statusColor)
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(Color(red: 0.10, green: 0.10, blue: 0.14))
    }

    private var emptyDetail: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("Select a server")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("or add one with the + button")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color(red: 0.10, green: 0.10, blue: 0.14))
    }

    private var emptyServerList: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "plus.circle.dashed")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("No MCP servers")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Add server") { showAddSheet = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func modeBadge(_ mode: MCPServerConfig.ExecutionMode) -> some View {
        HStack(spacing: 4) {
            Image(systemName: mode == .ai ? "infinity" : "timer")
                .font(.system(size: 8))
            Text(mode == .ai ? "AI" : "60s")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(mode == .ai
                         ? Color(red: 0.3, green: 1.0, blue: 0.5)
                         : Color(red: 0.9, green: 0.7, blue: 0.3))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background((mode == .ai
                     ? Color(red: 0.3, green: 1.0, blue: 0.5)
                     : Color(red: 0.9, green: 0.7, blue: 0.3)).opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 4))
    }

    private func transportIcon(_ t: MCPServerConfig.Transport) -> String {
        t == .stdio ? "terminal" : "network"
    }

    private func statusColor(for id: UUID) -> Color {
        switch mcp.connectionStatus[id] ?? .disconnected {
        case .connected:   return Color(red: 0.3, green: 0.9, blue: 0.5)
        case .connecting:  return Color(red: 0.9, green: 0.7, blue: 0.3)
        case .error:       return Color(red: 0.9, green: 0.4, blue: 0.4)
        case .disconnected: return Color(red: 0.5, green: 0.5, blue: 0.6)
        }
    }

    private func statusLabel(_ s: MCPEngine.ConnectionStatus) -> String {
        switch s {
        case .connected:      return "● connected"
        case .connecting:     return "○ connecting…"
        case .disconnected:   return "○ disconnected"
        case .error(let e):   return "✗ \(e.prefix(30))"
        }
    }

    private func isConnecting(_ id: UUID) -> Bool {
        if case .connecting = mcp.connectionStatus[id] ?? .disconnected { return true }
        return false
    }
}

// MARK: - ServerRow

struct ServerRow: View {
    let server: MCPServerConfig
    let status: MCPEngine.ConnectionStatus

    private var statusDot: Color {
        switch status {
        case .connected:    return Color(red: 0.3, green: 0.9, blue: 0.5)
        case .connecting:   return Color(red: 0.9, green: 0.7, blue: 0.3)
        case .error:        return Color(red: 0.9, green: 0.4, blue: 0.4)
        case .disconnected: return Color(red: 0.4, green: 0.4, blue: 0.5)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(statusDot).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Text(server.transport.rawValue)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            // Mode badge — tiny
            Text(server.mode == .ai ? "AI" : "60s")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundStyle(server.mode == .ai
                                 ? Color(red: 0.3, green: 0.9, blue: 0.5)
                                 : Color(red: 0.9, green: 0.7, blue: 0.3))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))

            // Enabled toggle
            Circle()
                .fill(server.isEnabled ? Color(red: 0.3, green: 0.7, blue: 1.0) : .secondary)
                .frame(width: 5, height: 5)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - ToolRow

struct ToolRow: View {
    let tool: MCPTool
    let serverMode: MCPServerConfig.ExecutionMode
    let onCall: ([String: Any]) -> Void
    @State private var showCallSheet = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "function")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(tool.name)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                if !tool.description.isEmpty {
                    Text(tool.description)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer()
            // Mode timeout indicator
            Text(serverMode == .ai ? "∞" : "60s")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(serverMode == .ai
                                 ? Color(red: 0.3, green: 0.9, blue: 0.5)
                                 : Color(red: 0.9, green: 0.7, blue: 0.3))

            Button("Run") { onCall([:]) }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .font(.system(size: 9))
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(Color.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 4))
    }
}

// MARK: - MCPServerEditSheet

struct MCPServerEditSheet: View {
    @State var config: MCPServerConfig
    let onSave: (MCPServerConfig) -> Void
    @Environment(\.dismiss) var dismiss

    @State private var newEnvKey = ""
    @State private var newEnvVal = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(config.id == UUID() ? "New MCP Server" : "Edit: \(config.name)")
                .font(.system(size: 14, weight: .bold))

            Divider()

            // Name
            FormRow("Name") {
                TextField("e.g. Filesystem, GitHub, Brave Search", text: $config.name)
                    .textFieldStyle(.roundedBorder)
            }

            // Transport
            FormRow("Transport") {
                Picker("", selection: $config.transport) {
                    ForEach(MCPServerConfig.Transport.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }

            // Command / URL
            if config.transport == .stdio {
                FormRow("Command") {
                    TextField("npx -y @modelcontextprotocol/server-filesystem /", text: $config.command)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }
            } else {
                FormRow("URL") {
                    TextField("http://localhost:3000", text: $config.url)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                }
            }

            // Execution mode
            FormRow("Mode") {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("", selection: $config.mode) {
                        ForEach(MCPServerConfig.ExecutionMode.allCases, id: \.self) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)

                    Group {
                        if config.mode == .ai {
                            Label("No timeout. Kill switch available. Suitable for AI agent use.",
                                  systemImage: "infinity")
                                .foregroundStyle(Color(red: 0.3, green: 0.9, blue: 0.5))
                        } else {
                            Label("60-second timeout per tool call. Safe for interactive use.",
                                  systemImage: "timer")
                                .foregroundStyle(Color(red: 0.9, green: 0.7, blue: 0.3))
                        }
                    }
                    .font(.system(size: 10))
                }
            }

            // Enabled
            FormRow("Enabled") {
                Toggle("", isOn: $config.isEnabled)
                    .toggleStyle(.switch)
                    .scaleEffect(0.8)
            }

            // Environment variables
            if !config.envVars.isEmpty || !newEnvKey.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Environment Variables")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    ForEach(Array(config.envVars.keys.sorted()), id: \.self) { key in
                        HStack {
                            Text(key)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 160, alignment: .leading)
                            SecureField("value", text: Binding(
                                get: { config.envVars[key] ?? "" },
                                set: { config.envVars[key] = $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 10, design: .monospaced))
                            Button { config.envVars.removeValue(forKey: key) } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            // Add env var
            HStack(spacing: 6) {
                TextField("KEY", text: $newEnvKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 130)
                TextField("value", text: $newEnvVal)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                Button("Add Env Var") {
                    guard !newEnvKey.isEmpty else { return }
                    config.envVars[newEnvKey] = newEnvVal
                    newEnvKey = ""; newEnvVal = ""
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(newEnvKey.isEmpty)
            }

            Spacer()

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Save") {
                    onSave(config)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(config.name.isEmpty)
            }
        }
        .padding(20)
        .background(Color(red: 0.10, green: 0.10, blue: 0.14))
    }
}

// MARK: - FormRow helper

struct FormRow<Content: View>: View {
    let label: String
    let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Color(red: 0.72, green: 0.72, blue: 0.85))
                .frame(width: 90, alignment: .trailing)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
