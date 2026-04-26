import SwiftUI
import AppKit
import Darwin   // signal()

// MARK: - AppDelegate for Close/Quit Guard

final class AppDelegate: NSObject, NSApplicationDelegate {

    var appState: AppState?
    private var safeModeWindowController: NSWindowController?

    // MARK: - Safe Mode — Shift Key Hardware Hook
    //
    // This is the FIRST thing that runs, before ANY SwiftUI scene.
    // CGEventSource reads physical keyboard state directly from hardware.
    // AI cannot modify this logic because it runs before the agent system initializes.

    func applicationWillFinishLaunching(_ notification: Notification) {
        // ── SIGPIPE を無視する（最重要・最初に実行） ───────────────────────────
        // verantyx-browser (Rust) プロセスが予期せず終了した後にパイプへ書き込むと
        // デフォルトでは SIGPIPE がアプリ全体をクラッシュさせる（signal 13）。
        // SIG_IGN を設定することで write() が -1/EPIPE を返すだけになり、
        // Swift 側の throw BrowserError.notRunning で安全にハンドリングできる。
        signal(SIGPIPE, SIG_IGN)

        guard SafeModeGuard.shared.checkOnLaunch() else { return }

        // Show Safe Mode window BLOCKING the normal UI
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "⚠️ Verantyx — SAFE MODE"
        window.center()
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 0.08, green: 0.04, blue: 0.04, alpha: 1)
        window.contentView = NSHostingView(
            rootView: SafeModeWindow()
                .environmentObject(SafeModeGuard.shared)
        )

        let wc = NSWindowController(window: window)
        wc.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        safeModeWindowController = wc
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // MCP Bridge (port 5420) と verantyx-browser を先に終了
        MCPBridgeLauncher.shared.stop()
        ExtensionHostManager.shared.stop()
        Task.detached(priority: .utility) {
            await BrowserBridgePool.shared.shutdown()
        }

        guard let state = appState, state.isDirty else { return .terminateNow }

        // Show confirmation on main thread synchronously (legacy Modal)
        let alert             = NSAlert()
        alert.messageText     = "このセッションを保存しますか？"
        alert.informativeText = "作業中のプロジェクトがあります。終了前にセッションを保存することを推奨します。"
        alert.addButton(withTitle: "保存して終了")
        alert.addButton(withTitle: "保存せずに終了")
        alert.addButton(withTitle: "キャンセル")
        alert.alertStyle      = .warning

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:   // 保存して終了
            // ⚠️ IMPORTANT: ここは同期コンテキスト (applicationShouldTerminate) 。
            // updateActiveSession → save() → Task.detached { archiveProgressively() } は
            // 非同期 MCP ネットワーク呼び出しを起動しメインスレッドをブロックしてしまう。
            // 代わりに「JSON ディスク書き込みのみ」の同期パスを直接呼ぶ。
            state.sessions.saveForQuit(messages: state.messages,
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

    // ── Cortex Onboarding ────────────────────────────────────────────────
    // Shows once on first launch. User can suppress via "次回から表示しない".
    @AppStorage("cortex_onboarding_dismissed") private var cortexDismissed = false
    @State private var showCortexOnboarding = false

    var body: some Scene {
        WindowGroup {
            MainSplitView()
                .environmentObject(appState)
                .frame(minWidth: 900, minHeight: 580)
                .onAppear {
                    AppState.shared = appState
                    delegate.appState = appState

                    // ── 永続化設定を最初に復元（モデル/ワークスペース/APIキー等） ──
                    appState.loadPersistedSettings()

                    appState.registerCIErrorHook()
                    appState.registerRestartHook()
                    // ── MCP Bridge 自動起動（port 5420）──────────────────
                    // MCPSkillSync のポーリング開始前に Bridge を起動しておく。
                    // MCPBridgeLauncher が /health 疎通確認後に isRunning = true にする。
                    MCPBridgeLauncher.shared.start()
                    MCPSkillSync.shared.startPolling()
                    
                    // ── VS Code Extension Host 自動起動 ──────────────────
                    ExtensionHostManager.shared.start()

                    Task.detached(priority: .utility) {
                        await BrowserBridgePool.shared.warmUp()
                    }

                    let wsURL = appState.workspaceURL
                    Task.detached(priority: .utility) {
                        SessionMemoryArchiver.shared.indexSkills(workspaceRoot: wsURL)
                    }

                    if !cortexDismissed {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            showCortexOnboarding = true
                        }
                    }
                }
                // ── Cortex Onboarding Sheet ──────────────────────────────
                .sheet(isPresented: $showCortexOnboarding) {
                    CortexOnboardingSheet(isPresented: $showCortexOnboarding)
                        .preferredColorScheme(.dark)
                }
                // ── AI-triggered restart dialog ──────────────────────
                .alert("🔨 ビルド完了 — 再起動しますか？",
                       isPresented: $appState.showRestartAlert) {
                    Button("再起動する", role: .destructive) {
                        appState.performRestart()
                    }
                    Button("後で", role: .cancel) {
                        appState.showRestartAlert = false
                    }
                } message: {
                    Text("AI がパッチを適用してビルドに成功しました。\nアプリを終了してリビルドすると変更が有効になります。")
                }
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
                    appState.loadMLXModel(model: appState.activeMlxModel)
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
