use serde::{Deserialize, Serialize};
use std::io::{self, BufRead, Write};
use std::sync::{Arc, Mutex};
use tao::{
    event::{Event, WindowEvent},
    event_loop::{ControlFlow, EventLoopBuilder},
    window::WindowBuilder,
};
use wry::WebViewBuilder;
use std::thread;

/// Command from Swift BrowserBridge → Rust stealth_bridge
#[derive(Debug, Deserialize)]
pub struct BridgeCommand {
    pub cmd:  String,
    pub url:  Option<String>,
    pub id:   Option<u64>,   // リクエスト ID — レスポンスにエコーバック
    pub text: Option<String>,
}

/// Response from Rust stealth_bridge → Swift BrowserBridge
#[derive(Debug, Serialize)]
pub struct BridgeResponse {
    pub id:       Option<u64>,   // ← New: リクエスト ID エコーバック
    pub status:   String,
    pub message:  Option<String>,
    pub url:      Option<String>,
    pub title:    Option<String>,
    pub markdown: Option<String>,
}

// ── JSON 1行出力ヘルパー ────────────────────────────────────────────────────
macro_rules! emit {
    ($resp:expr) => {{
        println!("{}", serde_json::to_string(&$resp).unwrap());
        std::io::stdout().flush().unwrap();
    }};
}

pub fn run_event_loop(visible: bool) -> anyhow::Result<()> {
    let event_loop = EventLoopBuilder::<BridgeCommand>::with_user_event().build();
    let proxy      = event_loop.create_proxy();

    // ── IPC ハンドラーとイベントループ間でリクエスト ID を共有 ─────────────
    let pending_id: Arc<Mutex<Option<u64>>> = Arc::new(Mutex::new(None));
    let pending_id_ipc = Arc::clone(&pending_id);

    // ── stdin リーダースレッド ─────────────────────────────────────────────
    thread::spawn(move || {
        let stdin  = io::stdin();
        let reader = stdin.lock();
        for line_res in reader.lines() {
            if let Ok(line) = line_res {
                if let Ok(cmd) = serde_json::from_str::<BridgeCommand>(&line) {
                    if proxy.send_event(cmd).is_err() { break; }
                }
            }
        }
    });

    // ── ステルスウィンドウ ─────────────────────────────────────────────────
    let window = WindowBuilder::new()
        .with_title("vx-agent-stealth")
        .with_visible(visible)
        .build(&event_loop)?;

    // ── 初期化 JS: readyState + 300ms ネットワーク静止検知 ───────────────
    // 旧: MutationObserver 固定2秒 → 新: document.readyState 完了後 300ms 安定で通知
    let init_js = r#"
        (function() {
            let networkTimer = null;

            const observer = new MutationObserver(() => { scheduleIdleCheck(); });

            function scheduleIdleCheck() {
                if (networkTimer) clearTimeout(networkTimer);
                networkTimer = setTimeout(() => {
                    if (document.readyState === 'complete' || document.readyState === 'interactive') {
                        notifyDone();
                    }
                }, 300);
            }

            function notifyDone() {
                if (window.__vx_notified) return;
                window.__vx_notified = true;
                observer.disconnect();
                window.ipc.postMessage('HITL_DONE:' + document.documentElement.outerHTML);
            }

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', () => {
                    observer.observe(document.body || document.documentElement,
                        { childList: true, subtree: true, characterData: true });
                    scheduleIdleCheck();
                    window.ipc.postMessage('PAGE_READY:1');
                });
            } else {
                observer.observe(document.body || document.documentElement,
                    { childList: true, subtree: true, characterData: true });
                scheduleIdleCheck();
                window.ipc.postMessage('PAGE_READY:1');
            }

            // フォールバック: 10秒で強制送信
            setTimeout(notifyDone, 10000);
        })();
    "#;

    // ── WebView 構築 ───────────────────────────────────────────────────────
    let webview = WebViewBuilder::new()
        .with_initialization_script(init_js)
        .with_ipc_handler(move |req: wry::http::Request<String>| {
            let body = req.into_body();
            let id   = *pending_id_ipc.lock().unwrap();

            if body.starts_with("DOM:") {
                let md = html2md::parse_html(&body[4..]);
                emit!(BridgeResponse { id, status: "ok".into(), message: None, url: None, title: None, markdown: Some(md) });

            } else if body.starts_with("RAW_DOM:") {
                emit!(BridgeResponse { id, status: "raw_dom".into(), message: Some(body[8..].to_string()), url: None, title: None, markdown: None });

            } else if body.starts_with("HITL_DONE:") {
                let md = html2md::parse_html(&body[10..]);
                emit!(BridgeResponse { id, status: "hitl_done".into(), message: None, url: None, title: None, markdown: Some(md) });

            } else if body.starts_with("PAGE_READY:") {
                emit!(BridgeResponse { id, status: "ok".into(), message: Some("ready".into()), url: None, title: None, markdown: None });

            } else if body.starts_with("EVAL_RES:") {
                emit!(BridgeResponse { id, status: "eval_ok".into(), message: Some(body[9..].to_string()), url: None, title: None, markdown: None });

            } else if body.starts_with("EVAL_ERR:") {
                emit!(BridgeResponse { id, status: "eval_err".into(), message: Some(body[9..].to_string()), url: None, title: None, markdown: None });
            }
        })
        .with_html("<html><body><div id='vx-ready'></div></body></html>")
        .build(&window)?;

    // ── イベントループ ─────────────────────────────────────────────────────
    event_loop.run(move |event, _, control_flow| {
        *control_flow = ControlFlow::Wait;

        match event {
            Event::UserEvent(cmd) => {
                // pending_id を更新 → 次の IPC レスポンスに付与される
                if let Some(cmd_id) = cmd.id {
                    *pending_id.lock().unwrap() = Some(cmd_id);
                }

                match cmd.cmd.as_str() {
                    "navigate" => {
                        if let Some(url) = cmd.url {
                            let _ = webview.evaluate_script("window.__vx_notified = false;");
                            webview.load_url(&url);
                            let id = *pending_id.lock().unwrap();
                            emit!(BridgeResponse { id, status: "navigating".into(), message: Some("started".into()), url: None, title: None, markdown: None });
                        }
                    }
                    "get_page" => {
                        let _ = webview.evaluate_script(
                            "(function(){window.ipc.postMessage('DOM:'+document.documentElement.outerHTML);})();"
                        );
                    }
                    "get_raw_page" => {
                        let _ = webview.evaluate_script(
                            "(function(){window.ipc.postMessage('RAW_DOM:'+document.documentElement.outerHTML);})();"
                        );
                    }
                    "eval_js" => {
                        if let Some(script) = cmd.text {
                            let wrapped = format!(r#"
                                (function(){{
                                    try{{let r=(function(){{{script}}})();if(r!==undefined)window.ipc.postMessage('EVAL_RES:'+r);}}
                                    catch(e){{window.ipc.postMessage('EVAL_ERR:'+e.toString());}}
                                }})();
                            "#);
                            let _ = webview.evaluate_script(&wrapped);
                        }
                    }
                    "ping" => {
                        let id = *pending_id.lock().unwrap();
                        emit!(BridgeResponse { id, status: "pong".into(), message: Some("alive".into()), url: None, title: None, markdown: None });
                    }
                    "quit" => {
                        *control_flow = ControlFlow::Exit;
                        std::process::exit(0);
                    }
                    _ => {}
                }
            }
            Event::WindowEvent { event: WindowEvent::CloseRequested, .. } => {
                *control_flow = ControlFlow::Exit;
            }
            _ => {}
        }
    });
}
