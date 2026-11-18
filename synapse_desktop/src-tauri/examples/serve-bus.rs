//! The host on its own, serving the bus as a WebSocket on localhost. The browser suite reaches the Rust
//! host through it, the way it reaches the Node host: the dev server proxies `/api` here and adds the
//! token of the launch. The desktop app does not use it.

use futures_util::{SinkExt, StreamExt};
use std::collections::HashSet;
use std::sync::Arc;
use synapse_desktop_host::environment::Environment;
use synapse_desktop_host::guards::{check_upgrade, Policy};
use synapse_desktop_host::host::Host;
use synapse_desktop_host::link::HostLink;
use synapse_desktop_host::protocol::{ClientMessage, HostKind};
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::Message;

// The ports and the paths the dev server and the page agree on (`shared/constants.ts`).
const WEB_PORT: u16 = 5173;
const SERVER_PORT: u16 = 5174;
// The end-to-end tests run beside a dev build, on ports of their own, and say so in the environment.
const E2E_WEB_PORT: u16 = 5183;
const E2E_SERVER_PORT: u16 = 5184;
const BUS_PATH: &str = "/api/bus";
const TOKEN_HEADER: &str = "x-synapse-desktop-token";

fn header<'a>(request: &'a Request, name: &str) -> Option<&'a str> {
    request.headers().get(name).and_then(|v| v.to_str().ok())
}

// The handshake callback's error type is the library's, and it is large.
#[allow(clippy::result_large_err)]
async fn connection(stream: TcpStream, host: Arc<Host>, policy: Arc<Policy>) {
    let check = |request: &Request, response: Response| -> Result<Response, ErrorResponse> {
        let refusal = if request.uri().path() != BUS_PATH {
            Some((404, "not found"))
        } else {
            check_upgrade(
                header(request, "host"),
                header(request, "origin"),
                header(request, TOKEN_HEADER),
                &policy,
            )
            .map(|r| (r.status, r.error))
        };
        match refusal {
            None => Ok(response),
            Some((status, error)) => {
                let mut refused = ErrorResponse::new(Some(error.to_string()));
                *refused.status_mut() = status.try_into().unwrap();
                Err(refused)
            }
        }
    };
    let config = WebSocketConfig::default()
        .max_message_size(Some(1024 * 1024))
        .max_frame_size(Some(1024 * 1024));
    let Ok(socket) =
        tokio_tungstenite::accept_hdr_async_with_config(stream, check, Some(config)).await
    else {
        return;
    };
    let (mut write, mut read) = socket.split();
    let (to_host, incoming) = tokio::sync::mpsc::unbounded_channel();
    let (outgoing, mut from_host) = tokio::sync::mpsc::unbounded_channel();
    host.connect(HostLink { incoming, outgoing });
    let sender = tokio::spawn(async move {
        while let Some(message) = from_host.recv().await {
            let Ok(text) = serde_json::to_string(&message) else {
                continue;
            };
            if write.send(Message::text(text)).await.is_err() {
                break;
            }
        }
        let _ = write.close().await;
    });
    while let Some(Ok(message)) = read.next().await {
        if let Message::Text(text) = message {
            if let Some(parsed) = ClientMessage::parse(&text) {
                let _ = to_host.send(parsed);
            }
        }
    }
    // Dropping the sender ends the host's end of the connection, which detaches its sessions.
    drop(to_host);
    sender.abort();
}

#[tokio::main]
async fn main() {
    let (web_port, server_port) = if std::env::var_os("SYNAPSE_DESKTOP_E2E").is_some() {
        (E2E_WEB_PORT, E2E_SERVER_PORT)
    } else {
        (WEB_PORT, SERVER_PORT)
    };
    let Ok(token) = std::env::var("SYNAPSE_DESKTOP_TOKEN") else {
        eprintln!("SYNAPSE_DESKTOP_TOKEN is not set");
        std::process::exit(1);
    };
    let policy = Arc::new(Policy {
        allowed_hosts: ["127.0.0.1", "localhost"]
            .iter()
            .map(|h| format!("{h}:{server_port}"))
            .collect::<HashSet<_>>(),
        allowed_origins: ["127.0.0.1", "localhost"]
            .iter()
            .map(|h| format!("http://{h}:{web_port}"))
            .collect::<HashSet<_>>(),
        token,
    });
    // The packages of this checkout, where the skills and harness files are when no installed
    // package says (the packages of the app are bundled with it in the desktop build).
    let packages = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../packages");
    let bundled = vec![packages.join("synapse-pipeline"), packages.join("synapse")];
    let host = Arc::new(Host::system(
        Environment::from_process(),
        HostKind::Tauri,
        bundled,
    ));
    let listener = match TcpListener::bind(("127.0.0.1", server_port)).await {
        Ok(listener) => listener,
        Err(error) => {
            eprintln!("port {server_port}: {error}");
            std::process::exit(1);
        }
    };
    println!("synapse-desktop host on http://127.0.0.1:{server_port}");
    let refreshing = host.clone();
    tokio::spawn(async move { refreshing.refresh_models().await });
    loop {
        let Ok((stream, _)) = listener.accept().await else {
            continue;
        };
        tokio::spawn(connection(stream, host.clone(), policy.clone()));
    }
}
