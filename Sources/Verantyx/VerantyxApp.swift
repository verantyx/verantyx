import SwiftUI

@main
struct VerantyxApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainSplitView()
                .environmentObject(appState)
                // Minimum size only — user can freely resize/maximize
                .frame(minWidth: 900, minHeight: 580)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        // defaultSize lets the OS pick a good initial size on first launch
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Workspace") {
                Button("Open Folder…") {
                    appState.openWorkspace()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Button("Refresh Files") {
                    appState.refreshFiles()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }

            CommandMenu("Model") {
                Button("Connect Ollama") {
                    appState.connectOllama()
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])

                Button("Start MLX Server") {
                    appState.startMLXServer(model: appState.activeMlxModel)
                }

                Divider()

                Button("Clear Chat") {
                    appState.messages.removeAll()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }

            CommandMenu("Tools") {
                Button("Toggle Process Log") {
                    appState.showProcessLog.toggle()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }
}
