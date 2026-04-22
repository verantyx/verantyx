import SwiftUI
import AppKit

// MARK: - FileTreeView
// Left panel: file hierarchy + selected file content preview.
// VS Code-style: instant response on click, async content load.

struct FileTreeView: View {
    @EnvironmentObject var app: AppState
    @State private var expandedFolders: Set<String> = []
    @State private var isScanning = false

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
            .frame(maxHeight: .infinity)

            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)

            // ── Bottom: File content preview ──────────────────────────
            filePreviewPanel.frame(maxHeight: .infinity)
        }
        .onChange(of: app.workspaceFiles.count) { count in
            isScanning = false
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
                    Image(systemName: "arrow.clockwise").font(.system(size: 10))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }

            Button { app.openWorkspace() } label: {
                Image(systemName: "folder.badge.plus").font(.system(size: 10))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color(red: 0.1, green: 0.1, blue: 0.13))
    }

    // MARK: - Tree List

    private var treeList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(tree) { node in
                    TreeRowView(node: node, selectedFile: app.selectedFile,
                                expandedFolders: $expandedFolders) { url in
                        app.selectFile(url)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var scanningIndicator: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView().scaleEffect(0.8)
            Text("Scanning…")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "folder.badge.questionmark").font(.title2).foregroundStyle(.tertiary)
            Text("No workspace").font(.system(size: 11)).foregroundStyle(.secondary)
            Button("Open Folder…") { app.openWorkspace() }
                .buttonStyle(.borderedProminent).controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bottom file preview

    private var filePreviewPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                if let file = app.selectedFile {
                    Image(systemName: FileIcons.icon(for: file))
                        .font(.system(size: 9))
                        .foregroundStyle(FileIcons.color(for: file))
                    Text(file.lastPathComponent)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.primary).lineLimit(1)
                    Spacer()
                    let lines = app.selectedFileContent.components(separatedBy: "\n").count
                    Text("\(lines)L")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                } else {
                    Image(systemName: "doc.text").font(.system(size: 9)).foregroundStyle(.tertiary)
                    Text("no file selected")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    Spacer()
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(red: 0.10, green: 0.10, blue: 0.14))

            Divider().opacity(0.3)

            if app.selectedFile != nil && app.selectedFileContent.isEmpty {
                VStack { Spacer(); ProgressView().scaleEffect(0.6); Spacer() }
                    .frame(maxWidth: .infinity)
            } else if app.selectedFileContent.isEmpty {
                VStack {
                    Spacer()
                    Text("Select a file to preview")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(app.selectedFileContent)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(red: 0.82, green: 0.82, blue: 0.88))
                        .textSelection(.enabled).lineSpacing(2).padding(8)
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
                        nodeMap[currentPath] = TreeNode(id: currentPath, name: part,
                                                        depth: i, isDir: false, url: url, children: [])
                    } else {
                        nodeMap[currentPath] = TreeNode(id: currentPath, name: part,
                                                        depth: i, isDir: true, url: nil, children: [])
                    }
                    if !parentPath.isEmpty { nodeMap[parentPath]?.children.append(currentPath) }
                }
            }
        }

        var result: [TreeNode] = []
        func visit(_ id: String) {
            guard let node = nodeMap[id] else { return }
            result.append(node)
            if node.isDir && expandedFolders.contains(id) {
                for childId in node.children.sorted() { visit(childId) }
            }
        }
        let rootItems = nodeMap.keys.filter { !$0.contains("/") }.sorted()
        for id in rootItems { visit(id) }
        return result
    }

    private func relativePath(_ url: URL, from root: URL) -> String {
        let full = url.path, base = root.path
        if full.hasPrefix(base) { return String(full.dropFirst(base.count + 1)) }
        return url.lastPathComponent
    }
}

// MARK: - FileIcons
// Centralised icon + colour lookup for all file types.

enum FileIcons {

    // SF Symbol name for a file extension
    static func icon(for url: URL) -> String { icon(ext: url.pathExtension) }
    static func icon(for name: String) -> String { icon(ext: (name as NSString).pathExtension) }

    static func icon(ext raw: String) -> String {
        switch raw.lowercased() {
        // Apple
        case "swift":              return "swift"
        case "xcodeproj","xcworkspace": return "hammer.fill"
        case "storyboard","xib":   return "rectangle.3.group"
        case "plist":              return "list.bullet.rectangle"
        // Python
        case "py","pyw","pyi":     return "chevron.left.forwardslash.chevron.right"
        case "ipynb":              return "brain.head.profile"
        // JavaScript / TypeScript
        case "ts","tsx":           return "t.square.fill"
        case "js","jsx","mjs":     return "j.square"
        case "vue":                return "v.square.fill"
        // Web
        case "html","htm":         return "globe"
        case "css","scss","sass","less": return "paintbrush.pointed"
        case "svg":                return "squareshape.controlhandles.on.squareshape.controlhandles"
        // Rust
        case "rs":                 return "r.square"
        // Go
        case "go":                 return "g.square"
        // Kotlin / Java / Scala
        case "kt","kts":           return "k.square"
        case "java":               return "j.circle.fill"
        case "scala":              return "s.square"
        // C / C++
        case "c":                  return "c.square"
        case "cpp","cc","cxx":     return "c.square.fill"
        case "h","hpp":            return "h.square"
        // Ruby / PHP
        case "rb","rake","gemspec": return "diamond.fill"
        case "php":                return "p.square"
        // Shell / scripts
        case "sh","bash","zsh","fish","ps1": return "terminal.fill"
        case "makefile","mk":      return "wrench.adjustable"
        // Config
        case "json","jsonc":       return "curlybraces"
        case "yaml","yml":         return "list.dash"
        case "toml":               return "gearshape"
        case "ini","cfg","conf":   return "slider.horizontal.3"
        case "env":                return "lock.shield"
        case "dockerfile":         return "shippingbox"
        case "gitignore","gitattributes": return "arrow.triangle.branch"
        // Docs
        case "md","mdx","markdown": return "doc.richtext"
        case "txt":                return "doc.text"
        case "pdf":                return "doc.fill"
        case "docx","doc":         return "doc.richtext.fill"
        // Data
        case "csv","tsv":          return "tablecells"
        case "xml":                return "angle.left.slash.angle.right"  // fallback
        case "sql":                return "cylinder.split.1x2"
        // Images
        case "png","jpg","jpeg","gif","webp","heic","tiff","bmp","ico":
                                   return "photo"
        // Audio / Video
        case "mp3","m4a","wav","aiff","flac": return "music.note"
        case "mp4","mov","avi","mkv":          return "video"
        // Archives
        case "zip","tar","gz","bz2","xz","rar","7z": return "archivebox"
        // Config lock
        case "lock":               return "lock.fill"
        // Package managers
        case "package":            return "shippingbox.fill"
        default:                   return "doc"
        }
    }

    // Colour for a file extension
    static func color(for url: URL) -> Color { color(ext: url.pathExtension) }
    static func color(for name: String) -> Color { color(ext: (name as NSString).pathExtension) }

    static func color(ext raw: String) -> Color {
        switch raw.lowercased() {
        case "swift":              return Color(red: 0.98, green: 0.49, blue: 0.18)  // Swift orange
        case "py","pyw","pyi","ipynb": return Color(red: 0.97, green: 0.77, blue: 0.25) // Python yellow
        case "ts","tsx":           return Color(red: 0.27, green: 0.56, blue: 0.93) // TS blue
        case "js","jsx","mjs":     return Color(red: 0.93, green: 0.80, blue: 0.18) // JS yellow
        case "vue":                return Color(red: 0.25, green: 0.75, blue: 0.56) // Vue green
        case "html","htm":         return Color(red: 0.90, green: 0.40, blue: 0.20) // HTML red-orange
        case "css","scss","sass","less": return Color(red: 0.40, green: 0.65, blue: 0.95) // CSS blue
        case "svg":                return Color(red: 0.95, green: 0.58, blue: 0.18) // SVG orange
        case "rs":                 return Color(red: 0.86, green: 0.37, blue: 0.20) // Rust orange
        case "go":                 return Color(red: 0.37, green: 0.75, blue: 0.85) // Go cyan
        case "kt","kts":           return Color(red: 0.62, green: 0.45, blue: 0.95) // Kotlin purple
        case "java":               return Color(red: 0.90, green: 0.31, blue: 0.27) // Java red
        case "scala":              return Color(red: 0.82, green: 0.19, blue: 0.19) // Scala deep red
        case "c":                  return Color(red: 0.56, green: 0.73, blue: 0.90) // C blue-grey
        case "cpp","cc","cxx":     return Color(red: 0.35, green: 0.55, blue: 0.87) // C++ blue
        case "h","hpp":            return Color(red: 0.60, green: 0.80, blue: 0.96) // Header light blue
        case "rb","rake","gemspec": return Color(red: 0.90, green: 0.20, blue: 0.28) // Ruby red
        case "php":                return Color(red: 0.48, green: 0.52, blue: 0.80) // PHP mauve
        case "sh","bash","zsh","fish","ps1": return Color(red: 0.45, green: 0.90, blue: 0.58) // Shell green
        case "json","jsonc":       return Color(red: 0.95, green: 0.75, blue: 0.35) // JSON amber
        case "yaml","yml","toml":  return Color(red: 0.70, green: 0.65, blue: 0.95) // Config lavender
        case "md","mdx","markdown": return Color(red: 0.60, green: 0.85, blue: 0.75) // MD teal
        case "dockerfile":         return Color(red: 0.25, green: 0.65, blue: 0.96) // Docker blue
        case "gitignore","gitattributes": return Color(red: 0.95, green: 0.45, blue: 0.32) // Git orange-red
        case "pdf":                return Color(red: 0.90, green: 0.25, blue: 0.25) // PDF red
        case "csv","tsv","sql":    return Color(red: 0.42, green: 0.78, blue: 0.56) // Data green
        case "png","jpg","jpeg","gif","webp","heic","tiff","bmp","ico":
                                   return Color(red: 0.88, green: 0.55, blue: 0.90) // Image purple-pink
        case "mp3","m4a","wav","aiff","flac": return Color(red: 0.95, green: 0.65, blue: 0.35) // Audio amber
        case "mp4","mov","avi","mkv": return Color(red: 0.58, green: 0.38, blue: 0.92) // Video violet
        case "zip","tar","gz","bz2","xz","rar","7z": return Color(red: 0.75, green: 0.55, blue: 0.32) // Archive tan
        case "lock":               return Color(red: 0.55, green: 0.55, blue: 0.65) // Lock grey
        case "plist","xcodeproj","xcworkspace": return Color(red: 0.98, green: 0.49, blue: 0.18)
        default:                   return Color(red: 0.55, green: 0.55, blue: 0.65)
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
    var children: [String]
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
                Spacer().frame(width: CGFloat(node.depth) * 12 + 4)

                if node.isDir {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary).frame(width: 10)
                    Image(systemName: isExpanded ? "folder.open" : "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(red: 0.5, green: 0.75, blue: 1.0))
                } else {
                    Spacer().frame(width: 10)
                    Image(systemName: FileIcons.icon(for: node.name))
                        .font(.system(size: 9))
                        .foregroundStyle(FileIcons.color(for: node.name))
                }

                Text(node.name)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(isSelected ? .white : Color(red: 0.80, green: 0.80, blue: 0.86))
                    .lineLimit(1)

                Spacer()
            }
            .padding(.vertical, 3).padding(.horizontal, 4)
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
}
