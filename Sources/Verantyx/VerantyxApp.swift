import SwiftUI

@main
struct VerantyxApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainSplitView()
                .environmentObject(appState)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Workspace") {
                Button("Open Folder…") {
                    appState.openWorkspace()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}
