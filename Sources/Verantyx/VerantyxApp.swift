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
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request Accessibility (for CGEvent HID clicks)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if !AXIsProcessTrusted() {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            
            // Request Screen Recording (for CGWindowListCreateImage)
            if #available(macOS 10.15, *) {
                if !CGPreflightScreenCaptureAccess() {
                    CGRequestScreenCaptureAccess()
                }
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // ── ダーティ状態がなければ即座に非同期シャットダウンを開始 ──
        guard let state = appState, state.isDirty else {
            performAsyncShutdown(state: appState, shouldSave: false)
            return .terminateLater
        }

        // ── ダーティ状態があればダイアログを表示 ──
        let alert             = NSAlert()
        alert.messageText     = AppLanguage.shared.t("Save this session?", "このセッションを保存しますか？")
        alert.informativeText = AppLanguage.shared.t("You have an active project. We recommend saving before quitting.", "作業中のプロジェクトがあります。終了前にセッションを保存することを推奨します。")
        alert.addButton(withTitle: AppLanguage.shared.t("Save & Quit", "保存して終了"))
        alert.addButton(withTitle: AppLanguage.shared.t("Quit without saving", "保存せずに終了"))
        alert.addButton(withTitle: AppLanguage.shared.t("Cancel", "キャンセル"))
        alert.alertStyle      = .warning

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            performAsyncShutdown(state: state, shouldSave: true)
            return .terminateLater
        case .alertSecondButtonReturn:
            performAsyncShutdown(state: state, shouldSave: false)
            return .terminateLater
        default:
            return .terminateCancel
        }
    }

    /// メインスレッドをブロックせずに非同期で安全にシャットダウンを行う
    private func performAsyncShutdown(state: AppState?, shouldSave: Bool) {
        Task {
            if shouldSave, let state = state {
                // ⚠️ ここは UI が固まらないようにバックグラウンドで保存するのもありだが、
                // 終了処理中なので安全のため確実に待つ
                await MainActor.run {
                    state.sessions.saveForQuit(messages: state.messages,
                                               workspacePath: state.workspaceURL?.path)
                }
            }

            // フェーズ1: @MainActor を持つマネージャーを停止
            await MainActor.run {
                MCPBridgeLauncher.shared.stop()
                ExtensionHostManager.shared.stop()
            }

            // フェーズ2: GlobalTaskSupervisor 経由で BrowserBridge などを停止
            GlobalTaskSupervisor.shared.register(priority: .userInitiated) {
                // BrowserBridgePool is deprecated
            }
            await GlobalTaskSupervisor.shared.shutdown(timeout: 2.0)

            // 完了したらシステムに終了許可を出す
            await MainActor.run {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
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
                    MCPBridgeLauncher.shared.start {
                        CortexHandshakeServer.shared.start()
                        CortexWebSocketServer.shared.start()
                    }
                    MCPSkillSync.shared.startPolling()
                    ExtensionHostManager.shared.start()

                    // ── WHY Hook + Agent Payload バンドルインストール ─────────
                    // DMG に同梱済み。ダウンロード不要。バージョン更新時のみ実行。
                    WHYHookInstaller.shared.installIfNeeded(workspaceURL: appState.workspaceURL)

                    let wsURL = appState.workspaceURL
                    Task.detached(priority: .utility) {
                        await SessionMemoryArchiver.shared.indexSkills(workspaceRoot: wsURL)
                    }

                    // ── L2.5 インデックス起動 (0.3秒後: UIが描画された後) ──────
                    // MainActor をブロックしないよう Task.detached(priority: .utility) で実行する。
                    // loadAndIncrementalUpdate 内部の await をバックグラウンドで完結させ、
                    // 完了通知のみ MainActor で受け取る。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        Task.detached(priority: .utility) {
                            guard await appState.operationMode == .human else { return }
                            guard let ws = await appState.workspaceURL else { return }
                            await L25IndexEngine.shared.loadAndIncrementalUpdate(workspaceURL: ws)
                            let count = await L25IndexEngine.shared.projectMap?.fileCount ?? 0
                            if count > 0 {
                                await MainActor.run {
                                    appState.addSystemMessage(AppLanguage.shared.t("🗺️ L2.5 ready: \(count) files", "🗺️ L2.5 準備完了: \(count) ファイル"))
                                }
                            }
                        }
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
                .alert(appState.t("🔨 Build Complete — Restart?", "🔨 ビルド完了 — 再起動しますか？"),
                       isPresented: $appState.showRestartAlert) {
                    Button(appState.t("Restart", "再起動する"), role: .destructive) {
                        appState.performRestart()
                    }
                    Button(appState.t("Later", "後で"), role: .cancel) {
                        appState.showRestartAlert = false
                    }
                } message: {
                    Text(appState.t("AI has successfully applied a patch and built it.\nQuit and rebuild the app to apply changes.", "AI がパッチを適用してビルドに成功しました。\nアプリを終了してリビルドすると変更が有効になります。"))
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
                Button(appState.t("New Session", "新しいセッション")) {
                    appState.newChatSession()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button(appState.t("Save Session", "セッションを保存")) {
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
        alert.messageText   = AppLanguage.shared.t("Save this session?", "このセッションを保存しますか？")
        alert.informativeText = AppLanguage.shared.t("You have an active project. We recommend saving before closing.", "作業中のプロジェクトがあります。終了前に保存することを推奨します。")
        alert.addButton(withTitle: AppLanguage.shared.t("Save & Close", "保存して閉じる"))
        alert.addButton(withTitle: AppLanguage.shared.t("Close without saving", "保存せずに閉じる"))
        alert.addButton(withTitle: AppLanguage.shared.t("Cancel", "キャンセル"))
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
