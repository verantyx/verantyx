import SwiftUI

// MARK: - FileTreeView
// Shows workspace files grouped by folder. Selecting a file loads it as context.

struct FileTreeView: View {
    @EnvironmentObject var app: AppState

    // Group files by parent directory relative to workspace root
    private var groupedFiles: [(folder: String, files: [URL])] {
        guard let root = app.workspaceURL else { return [] }
        var groups: [String: [URL]] = [:]
        for url in app.workspaceFiles {
            let parent = url.deletingLastPathComponent()
            let rel: String
            if parent == root {
                rel = "/"
            } else {
                let path = parent.path
                let base = root.path
                rel = path.hasPrefix(base) ? String(path.dropFirst(base.count + 1)) : parent.lastPathComponent
            }
            groups[rel, default: []].append(url)
        }
        let grouped: [(folder: String, files: [URL])] = groups.sorted { $0.key < $1.key }.map { (folder: $0.key, files: $0.value) }
        return grouped
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                Text(app.workspaceURL?.lastPathComponent ?? "No Workspace")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    app.refreshFiles()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            if app.workspaceFiles.isEmpty {
                emptyState
            } else {
                fileList
            }
        }
        .navigationTitle("")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "folder.badge.questionmark")
                .font(.title)
                .foregroundStyle(.tertiary)
            Text("No workspace open")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open Folder…") {
                app.openWorkspace()
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var fileList: some View {
        List(selection: Binding(
            get: { app.selectedFile },
            set: { if let url = $0 { app.selectFile(url) } }
        )) {
            ForEach(groupedFiles, id: \.folder) { group in
                if group.folder == "/" {
                    ForEach(group.files, id: \.path) { url in
                        fileRow(url)
                    }
                } else {
                    Section(header: Text(group.folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)) {
                        ForEach(group.files, id: \.path) { url in
                            fileRow(url)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func fileRow(_ url: URL) -> some View {
        Label {
            Text(url.lastPathComponent)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
        } icon: {
            Image(systemName: iconName(for: url))
                .foregroundStyle(iconColor(for: url))
                .font(.caption)
        }
        .tag(url)
        .help(url.path)
    }

    private func iconName(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "swift":           return "swift"
        case "py":              return "chevron.left.forwardslash.chevron.right"
        case "ts", "js":        return "j.square"
        case "md":              return "doc.text"
        case "json":            return "curlybraces"
        case "yaml", "toml":    return "gearshape"
        default:                return "doc"
        }
    }

    private func iconColor(for url: URL) -> Color {
        switch url.pathExtension.lowercased() {
        case "swift": return .orange
        case "py":    return .yellow
        case "ts":    return .blue
        case "js":    return Color(red: 0.9, green: 0.8, blue: 0.1)
        default:      return .secondary
        }
    }
}
