import SwiftUI

// MARK: - FileTreeView
// Left panel: top = file hierarchy, bottom = selected file content preview.
// VS Code-style: instant response on click, async content load.

struct FileTreeView: View {
    @EnvironmentObject var app: AppState
    @State private var expandedFolders: Set<String> = []
    @State private var isScanning = false

    // Tree nodes computed from workspaceFiles
    private var tree: [TreeNode] { buildTree() }

    var body: some View {
        VStack(spacing: 0) {

            // ── Top: File hierarchy ───────────────────────────────────
            VStack(spacing: 0) {
                treeHeader
                Divider().opacity(0.3)

                if isScanning {
                    scanningIndicator
                } else if app.workspaceFiles.isEmpty {
                    emptyState
                } else {
                    treeList
                }
            }
            .frame(maxHeight: .infinity)   // takes ~50% of available height

            // ── Divider (draggable feel via fixed 50/50 split) ────────
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)

            // ── Bottom: File content preview ──────────────────────────
            filePreviewPanel
                .frame(maxHeight: .infinity)
        }
        .onChange(of: app.workspaceFiles.count) { count in
            isScanning = false
            // Auto-expand first level
            if count > 0, let root = app.workspaceURL {
                expandedFolders.insert(root.lastPathComponent)
            }
        }
        .onChange(of: app.workspaceURL) { _ in
            isScanning = true
            expandedFolders.removeAll()
        }
    }

    // MARK: - Tree Header

    private var treeHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color(red: 0.5, green: 0.75, blue: 1.0))

            Text(app.workspaceURL?.lastPathComponent.uppercased() ?? "NO WORKSPACE")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if isScanning {
                ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
            } else {
                Button {
                    isScanning = true
                    app.refreshFiles()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Button {
                app.openWorkspace()
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(red: 0.1, green: 0.1, blue: 0.13))
    }

    // MARK: - Tree List

    private var treeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(tree) { node in
                    TreeRowView(
                        node: node,
                        selectedFile: app.selectedFile,
                        expandedFolders: $expandedFolders
                    ) { url in
                        app.selectFile(url)   // instant — async read inside
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Scanning indicator

    private var scanningIndicator: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView()
                .scaleEffect(0.8)
            Text("Scanning…")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "folder.badge.questionmark")
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text("No workspace")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Open Folder…") { app.openWorkspace() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bottom file preview

    private var filePreviewPanel: some View {
        VStack(spacing: 0) {
            // Sub-header
            HStack(spacing: 5) {
                if let file = app.selectedFile {
                    Image(systemName: iconName(for: file))
                        .font(.system(size: 9))
                        .foregroundStyle(iconColor(for: file))
                    Text(file.lastPathComponent)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer()
                    // Line count
                    let lines = app.selectedFileContent.components(separatedBy: "\n").count
                    Text("\(lines)L")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                } else {
                    Image(systemName: "doc.text")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text("no file selected")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(red: 0.10, green: 0.10, blue: 0.14))

            Divider().opacity(0.3)

            // Content
            if app.selectedFile != nil && app.selectedFileContent.isEmpty {
                // Loading state
                VStack {
                    Spacer()
                    ProgressView().scaleEffect(0.6)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else if app.selectedFileContent.isEmpty {
                // No selection
                VStack {
                    Spacer()
                    Text("Select a file to preview")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                // Syntax-highlighted (monospaced) text view
                ScrollView([.horizontal, .vertical]) {
                    Text(app.selectedFileContent)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(red: 0.82, green: 0.82, blue: 0.88))
                        .textSelection(.enabled)
                        .lineSpacing(2)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(red: 0.07, green: 0.07, blue: 0.10))
            }
        }
    }

    // MARK: - Tree builder

    private func buildTree() -> [TreeNode] {
        guard let root = app.workspaceURL else { return [] }
        var nodeMap: [String: TreeNode] = [:]

        for url in app.workspaceFiles {
            let rel = relativePath(url, from: root)
            let parts = rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

            var currentPath = ""
            for (i, part) in parts.enumerated() {
                let parentPath = currentPath
                currentPath = currentPath.isEmpty ? part : "\(currentPath)/\(part)"

                if nodeMap[currentPath] == nil {
                    if i == parts.count - 1 {
                        // File
                        nodeMap[currentPath] = TreeNode(id: currentPath, name: part,
                                                        depth: i, isDir: false, url: url, children: [])
                    } else {
                        // Folder
                        nodeMap[currentPath] = TreeNode(id: currentPath, name: part,
                                                        depth: i, isDir: true, url: nil, children: [])
                    }
                    // Add to parent
                    if !parentPath.isEmpty {
                        nodeMap[parentPath]?.children.append(currentPath)
                    }
                }
            }
        }

        // Flatten into display order (depth-first, respecting expansion)
        var result: [TreeNode] = []
        func visit(_ id: String) {
            guard let node = nodeMap[id] else { return }
            result.append(node)
            if node.isDir && expandedFolders.contains(id) {
                for childId in node.children.sorted() { visit(childId) }
            }
        }

        // Root-level items
        let rootItems = nodeMap.keys.filter { !$0.contains("/") }.sorted()
        for id in rootItems { visit(id) }

        return result
    }

    private func relativePath(_ url: URL, from root: URL) -> String {
        let full = url.path
        let base = root.path
        if full.hasPrefix(base) { return String(full.dropFirst(base.count + 1)) }
        return url.lastPathComponent
    }

    private func iconName(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "swift": return "swift"
        case "py":    return "chevron.left.forwardslash.chevron.right"
        case "ts","js": return "j.square"
        case "md":    return "doc.text"
        case "json":  return "curlybraces"
        case "yaml","toml": return "gearshape"
        case "sh":    return "terminal"
        case "rs":    return "r.square"
        default:      return "doc"
        }
    }

    private func iconColor(for url: URL) -> Color {
        switch url.pathExtension.lowercased() {
        case "swift": return .orange
        case "py":    return .yellow
        case "ts":    return Color(red: 0.3, green: 0.6, blue: 1.0)
        case "js":    return Color(red: 0.9, green: 0.8, blue: 0.1)
        case "rs":    return Color(red: 0.8, green: 0.4, blue: 0.2)
        default:      return .secondary
        }
    }
}

// MARK: - TreeNode

struct TreeNode: Identifiable {
    let id: String
    let name: String
    let depth: Int
    let isDir: Bool
    let url: URL?
    var children: [String]   // child ids
}

// MARK: - TreeRowView

struct TreeRowView: View {
    let node: TreeNode
    let selectedFile: URL?
    @Binding var expandedFolders: Set<String>
    let onSelect: (URL) -> Void

    private var isExpanded: Bool { expandedFolders.contains(node.id) }
    private var isSelected: Bool { node.url != nil && node.url == selectedFile }

    var body: some View {
        Button {
            if node.isDir {
                if isExpanded { expandedFolders.remove(node.id) }
                else          { expandedFolders.insert(node.id) }
            } else if let url = node.url {
                onSelect(url)
            }
        } label: {
            HStack(spacing: 4) {
                // Indent
                Spacer().frame(width: CGFloat(node.depth) * 12 + 4)

                // Folder chevron / file icon
                if node.isDir {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Image(systemName: isExpanded ? "folder.open" : "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(red: 0.5, green: 0.75, blue: 1.0))
                } else {
                    Spacer().frame(width: 10)
                    Image(systemName: fileIcon(for: node.name))
                        .font(.system(size: 9))
                        .foregroundStyle(fileColor(for: node.name))
                }

                Text(node.name)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isSelected ? .white : Color(red: 0.80, green: 0.80, blue: 0.86))
                    .lineLimit(1)

                Spacer()
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .background(
                isSelected
                    ? Color(red: 0.2, green: 0.4, blue: 0.8).opacity(0.4)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 3)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    private func fileIcon(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "py":    return "chevron.left.forwardslash.chevron.right"
        case "ts","js": return "j.square"
        case "md":    return "doc.text"
        case "json":  return "curlybraces"
        case "yaml","toml": return "gearshape"
        case "sh":    return "terminal"
        case "rs":    return "r.square"
        default:      return "doc"
        }
    }

    private func fileColor(for name: String) -> Color {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return .orange
        case "py":    return .yellow
        case "ts":    return Color(red: 0.3, green: 0.6, blue: 1.0)
        case "js":    return Color(red: 0.9, green: 0.8, blue: 0.1)
        case "rs":    return Color(red: 0.8, green: 0.4, blue: 0.2)
        default:      return Color(red: 0.55, green: 0.55, blue: 0.65)
        }
    }
}
