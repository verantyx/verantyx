import SwiftUI

// MARK: - MainSplitView
// 3-pane layout: FileTree | Chat | Diff

struct MainSplitView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            // ── Left: File tree ────────────────────────────────
            FileTreeView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } content: {
            // ── Center: Chat ──────────────────────────────────
            ChatPanelView()
                .navigationSplitViewColumnWidth(min: 340, ideal: 420, max: 600)
        } detail: {
            // ── Right: Diff ───────────────────────────────────
            DiffPanelView()
        }
        .toolbar {
            toolbarContent
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Workspace button
        ToolbarItem(placement: .navigation) {
            Button {
                app.openWorkspace()
            } label: {
                Label(app.workspaceURL?.lastPathComponent ?? "Open Workspace",
                      systemImage: "folder.badge.plus")
            }
            .help("Open workspace folder (⌘⇧O)")
        }

        // Model status pill
        ToolbarItem(placement: .automatic) {
            ModelStatusView()
        }
    }
}

// MARK: - Model status pill

struct ModelStatusView: View {
    @EnvironmentObject var app: AppState
    @State private var showModelPicker = false

    var body: some View {
        Button {
            showModelPicker.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(app.statusColor)
                    .frame(width: 8, height: 8)
                Text(app.statusLabel)
                    .font(.system(.callout, design: .monospaced))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showModelPicker, arrowEdge: .bottom) {
            ModelPickerView()
                .frame(width: 380)
        }
    }
}
