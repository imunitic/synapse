//! The desktop app: a window that shows the web app, with the host in the same process. The page and
//! the host talk by the messages of the protocol over a Link made of Tauri's IPC: `bus_connect` opens
//! one, `bus_send` sends the host a message, and what the host says comes back on the channel the
//! page gave. The host reads and writes files and runs programs itself, so the window is given no
//! file or shell access of its own.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use synapse_desktop_host::environment::{join_paths, split_paths, Environment};
use synapse_desktop_host::host::Host;
use synapse_desktop_host::link::link_pair;
use synapse_desktop_host::protocol::{ClientMessage, HostKind};
use synapse_desktop_host::status::{read_login_path, user_shell, with_login_path};
use tauri::ipc::Channel;
use tauri::{Manager, State};
use tokio::sync::mpsc::UnboundedSender;

type Connections = Arc<Mutex<HashMap<u64, UnboundedSender<ClientMessage>>>>;

struct App {
    host: Arc<Host>,
    connections: Connections,
    next: AtomicU64,
}

/// Opens a connection to the host. What the host says goes to `on_message`, and `{"kind":"close"}`
/// when the connection ends; the answer is the connection's number.
#[tauri::command]
async fn bus_connect(app: State<'_, App>, on_message: Channel<Value>) -> Result<u64, String> {
    let id = app.next.fetch_add(1, Ordering::SeqCst);
    let (mut client, host) = link_pair();
    app.host.connect(host);
    app.connections.lock().unwrap().insert(id, client.outgoing);
    let connections = app.connections.clone();
    tauri::async_runtime::spawn(async move {
        while let Some(message) = client.incoming.recv().await {
            let Ok(value) = serde_json::to_value(&message) else {
                continue;
            };
            // The page that opened the channel is gone: its connection ends with it.
            if on_message.send(value).is_err() {
                break;
            }
        }
        connections.lock().unwrap().remove(&id);
        let _ = on_message.send(json!({ "kind": "close" }));
    });
    Ok(id)
}

/// Sends the host a message. What is not a message is dropped, as the WebSocket host does.
#[tauri::command]
async fn bus_send(app: State<'_, App>, connection: u64, message: Value) -> Result<(), String> {
    let Some(parsed) = ClientMessage::parse(&message.to_string()) else {
        return Ok(());
    };
    let sender = app.connections.lock().unwrap().get(&connection).cloned();
    match sender {
        Some(sender) => sender
            .send(parsed)
            .map_err(|_| "the connection is closed".to_string()),
        None => Err("there is no such connection".to_string()),
    }
}

#[tauri::command]
async fn bus_close(app: State<'_, App>, connection: u64) -> Result<(), String> {
    // Dropping the sender ends the host's end of the connection, which detaches its sessions.
    app.connections.lock().unwrap().remove(&connection);
    Ok(())
}

/// What the app brings with it: its programs on the PATH of everything it starts, and the folders
/// with the skills and harness files of the `synapse` packages.
fn bundled(resources: &Path, environment: Environment) -> (Environment, Vec<PathBuf>) {
    let mut roots = vec![
        resources.join("packages").join("synapse-pipeline"),
        resources.join("packages").join("synapse"),
    ];
    let mut dirs = vec![resources.join("bin")];
    // A build that is run from the checkout, without a bundle, finds the programs and packages there.
    if cfg!(debug_assertions) {
        let checkout = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
        dirs.push(checkout.join("synapse_cli").join("bin"));
        dirs.push(checkout.join("synapse_pipeline").join("bin"));
        roots.push(checkout.join("packages").join("synapse-pipeline"));
        roots.push(checkout.join("packages").join("synapse"));
    }
    let existing = environment.env.get("PATH").cloned().unwrap_or_default();
    let mut parts: Vec<String> = dirs
        .iter()
        .filter(|d| d.is_dir())
        .map(|d| d.to_string_lossy().to_string())
        .collect();
    parts.extend(split_paths(&existing).into_iter().map(String::from));
    let mut environment = environment;
    environment.env.insert("PATH".into(), join_paths(&parts));
    (environment, roots)
}

/// This process's environment with the PATH of the user's login shell, read once at start: an app
/// opened from Finder or the Dock has only the system's short PATH, and the harnesses, shells and
/// programs it starts need the user's. The shell is given its usual time; when it does not answer,
/// the app goes on with the PATH it has.
fn login_environment() -> Environment {
    let environment = Environment::from_process();
    if cfg!(windows) {
        return environment;
    }
    let login = tauri::async_runtime::block_on(read_login_path(&user_shell(&environment)));
    with_login_path(environment, login.as_deref())
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let resources = app.path().resource_dir()?;
            let (environment, roots) = bundled(&resources, login_environment());
            let host = Arc::new(Host::system(environment, HostKind::Tauri, roots));
            let refreshing = host.clone();
            tauri::async_runtime::spawn(async move { refreshing.refresh_models().await });
            app.manage(App {
                host,
                connections: Arc::default(),
                next: AtomicU64::new(1),
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![bus_connect, bus_send, bus_close])
        .run(tauri::generate_context!())
        .expect("the app failed to run");
}
