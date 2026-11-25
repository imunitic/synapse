//! The host as a whole: every family of messages and the terminal sessions, made for one machine, and
//! the way a connection is served by them. Whatever carries the connection (a WebSocket for the served
//! build, Tauri's IPC for the desktop build) gives it a `HostLink`.

use crate::dispatch::{serve, Connection, Handlers, ServeOptions};
use crate::environment::Environment;
use crate::families::{agent_families, first_families, last_families, next_families, Context};
use crate::inject::{injected_dir, InjectDeps};
use crate::link::HostLink;
use crate::protocol::{Capabilities, HostKind};
use crate::terminal::{Sessions, TerminalDeps};
use crate::terminal_bus::{terminal_handlers, terminal_stream, ChannelSink};
use crate::topics::{subscriber, TopicTiming};
use std::path::PathBuf;
use std::sync::Arc;

/// The one user this host serves, to whom a session belongs.
const LOCAL_USER: &str = "local";

pub struct Host {
    context: Arc<Context>,
    sessions: Sessions,
    capabilities: Capabilities,
}

impl Host {
    /// A host that runs programs on this machine.
    pub fn system(environment: Environment, kind: HostKind, bundled_roots: Vec<PathBuf>) -> Host {
        let context = Arc::new(Context::system(environment.clone(), bundled_roots));
        let inject = InjectDeps {
            data_dir: injected_dir(&environment),
            bundled_roots: context.bundled_roots.clone(),
            environment: environment.clone(),
        };
        let mut deps = TerminalDeps::system(environment, context.config_file.clone(), inject);
        // A harness that just ended has likely changed its usage.
        let usage = context.usage.clone();
        deps.on_exit = Some(Arc::new(move || usage.nudge()));
        let sessions = Sessions::new(deps);
        Host {
            context,
            sessions,
            capabilities: Capabilities {
                host: kind,
                shell: true,
                install_actions: true,
            },
        }
    }

    pub fn context(&self) -> &Arc<Context> {
        &self.context
    }

    /// The models of the harnesses are read again, behind whatever is kept of them.
    pub async fn refresh_models(&self) {
        self.context.models.refresh_all().await;
    }

    /// Serves one connection until it closes. A connection that goes leaves its sessions running.
    pub fn connect(&self, link: HostLink) -> Connection {
        let sink = ChannelSink::sink(link.outgoing.clone());
        let mut handlers = Handlers::new();
        first_families(&mut handlers, self.context.clone());
        next_families(&mut handlers, self.context.clone());
        agent_families(&mut handlers, self.context.clone());
        last_families(&mut handlers, self.context.clone());
        terminal_handlers(
            &mut handlers,
            self.sessions.clone(),
            LOCAL_USER.into(),
            sink.clone(),
        );
        let mut options = ServeOptions::new(handlers, self.capabilities.clone());
        options.subscribe = Some(subscriber(self.context.clone(), TopicTiming::default()));
        options.on_stream = Some(terminal_stream(
            self.sessions.clone(),
            LOCAL_USER.into(),
            sink.clone(),
        ));
        options.report = Some(Arc::new(|error| eprintln!("{error}")));
        let (sessions, closing) = (self.sessions.clone(), sink);
        options.on_close = Some(Arc::new(move || sessions.detach_all(&closing)));
        serve(link, options)
    }
}
