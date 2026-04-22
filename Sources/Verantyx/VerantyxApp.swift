import SwiftUI
import AppKit

// MARK: - AppDelegate for Close/Quit Guard

final class AppDelegate: NSObject, NSApplicationDelegate {

    var appState: AppState?

    // Called when Cmd+Q or File > Quit is pressed
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = appState, state.isDirty else { return .terminateNow }

        // Show confirmation on main thread synchronously (legacy Modal)
        let alert           = NSAlert()
        alert.messageText   = "このセッションを保存しますか？"
        alert.informativeText = "作業中のプロジェクトがあります。終了前にセッションを保存することを推奨します。"
        alert.addButton(withTitle: "保存して終了")
        alert.addButton(withTitle: "保存せずに終了")
        alert.addButton(withTitle: "キャンセル")
        alert.alertStyle  = .warning

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:   // 保存して終了
            state.sessions.updateActiveSession(messages: state.messages,
                                               workspacePath: state.workspaceURL?.path)
            return .terminateNow
        case .alertSecondButtonReturn:  // 保存せずに終了
            return .terminateNow
        default:                        // キャンセル
            return .terminateCancel
        }
    }

    // Called when the last window is closed via the red ● button
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // prevent auto-quit; guard handled in windowWillClose
    }
}

// MARK: - VerantyxApp

@main
struct VerantyxApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            MainSplitView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 580)
                .onAppear { delegate.appState = appState }
                // CloseButton guard via SwiftUI scene lifecycle
                .onReceive(
                    NotificationCenter.default.publisher(
                        for: NSWindow.willCloseNotification)) { notification in
                    guard let window = notification.object as? NSWindow,
                          window.isKeyWindow else { return }
                    guard appState.isDirty else { return }
                    // If dirty, re-open the window and show the alert
                    // (NSWindowDelegate would be cleaner but requires more wiring)
                    window.makeKeyAndOrderFront(nil)
                    showCloseGuard(window: window, state: appState)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Session") {
                Button("新しいセッション") {
                    appState.newChatSession()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button("セッションを保存") {
                    appState.saveCurrentSession()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

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
                    appState.newChatSession()
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

    // MARK: - Close Guard Alert

    private func showCloseGuard(window: NSWindow, state: AppState) {
        let alert           = NSAlert()
        alert.messageText   = "このセッションを保存しますか？"
        alert.informativeText = "作業中のプロジェクトがあります。終了前に保存することを推奨します。"
        alert.addButton(withTitle: "保存して閉じる")
        alert.addButton(withTitle: "保存せずに閉じる")
        alert.addButton(withTitle: "キャンセル")
        alert.alertStyle  = .warning

        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn:
                state.saveCurrentSession()
                window.close()
            case .alertSecondButtonReturn:
                window.close()
            default: break  // キャンセル — window was re-opened above
            }
        }
    }
}
