import Foundation
import SwiftUI
import AppKit

@MainActor
class SelfUpdater: ObservableObject {
    static let shared = SelfUpdater()
    
    @Published var isChecking = false
    @Published var updateAvailable = false
    @Published var latestVersion = ""
    @Published var downloadProgress: Double = 0.0
    @Published var isDownloading = false
    @Published var errorMessage: String? = nil
    
    private let repoURL = "https://api.github.com/repos/verantyx/verantyx/releases/latest"
    private var pkgDownloadURL: URL? = nil
    
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
    
    func checkForUpdates(background: Bool = false) async {
        isChecking = true
        errorMessage = nil
        defer { isChecking = false }
        
        do {
            guard let url = URL(string: repoURL) else { return }
            let (data, _) = try await URLSession.shared.data(from: url)
            
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tagName = json["tag_name"] as? String,
               let assets = json["assets"] as? [[String: Any]] {
                
                let latest = tagName.replacingOccurrences(of: "v", with: "")
                self.latestVersion = latest
                
                // Compare versions
                if latest.compare(currentVersion, options: .numeric) == .orderedDescending {
                    self.updateAvailable = true
                    
                    // Find PKG asset
                    if let pkgAsset = assets.first(where: { ($0["name"] as? String ?? "").hasSuffix(".pkg") }),
                       let urlString = pkgAsset["browser_download_url"] as? String,
                       let downloadURL = URL(string: urlString) {
                        self.pkgDownloadURL = downloadURL
                    }
                } else {
                    self.updateAvailable = false
                }
            }
        } catch {
            if !background {
                self.errorMessage = "Failed to check for updates: \(error.localizedDescription)"
            }
        }
    }
    
    func downloadAndInstallUpdate() {
        guard let url = pkgDownloadURL else { return }
        isDownloading = true
        errorMessage = nil
        
        let destination = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("VerantyxUpdate_\(latestVersion).pkg")
        
        // Remove old file if exists
        try? FileManager.default.removeItem(at: destination)
        
        let task = URLSession.shared.downloadTask(with: url) { [weak self] localURL, response, error in
            Task { @MainActor in
                self?.isDownloading = false
                
                if let error = error {
                    self?.errorMessage = "Download failed: \(error.localizedDescription)"
                    return
                }
                
                guard let localURL = localURL else { return }
                
                do {
                    try FileManager.default.moveItem(at: localURL, to: destination)
                    // Open the PKG installer
                    NSWorkspace.shared.open(destination)
                    
                    // Terminate ourself to let the installer work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        NSApplication.shared.terminate(nil)
                    }
                } catch {
                    self?.errorMessage = "Failed to prepare update: \(error.localizedDescription)"
                }
            }
        }
        
        // We can track progress if we use a delegate, but for simplicity we'll just show an indeterminate spinner
        task.resume()
    }
}
