import Foundation
import AppKit

// MARK: - WorkspaceManager
// NSOpenPanel-based file I/O. No sandbox — full filesystem access.

final class WorkspaceManager {

    // MARK: - Folder picker (NSOpenPanel)

    func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Open Workspace Folder"
        panel.message = "Select your project folder. Verantyx will have full read/write access."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Open"

        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    // MARK: - Directory scan

    /// Returns all files recursively matching given extensions.
    func listFiles(in root: URL, extensions: [String]) -> [URL] {
        var results: [URL] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        for case let url as URL in enumerator {
            // Skip common noise folders
            let components = url.pathComponents
            if components.contains(".git") ||
               components.contains("node_modules") ||
               components.contains(".build") ||
               components.contains("DerivedData") { continue }

            guard let vals = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                  vals.isRegularFile == true else { continue }

            if extensions.contains(url.pathExtension.lowercased()) {
                results.append(url)
            }
        }
        return results.sorted { $0.path < $1.path }
    }

    // MARK: - File I/O

    func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    func write(_ url: URL, content: String) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - Relative path helper

    func relativePath(of url: URL, from root: URL) -> String {
        let full = url.path
        let base = root.path
        if full.hasPrefix(base) {
            return String(full.dropFirst(base.count + 1))
        }
        return url.lastPathComponent
    }
}
