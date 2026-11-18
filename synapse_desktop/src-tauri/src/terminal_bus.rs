//! The terminal messages of one connection: its requests start, attach to, list and end sessions of the
//! host, and what it streams is typed into and resized.

use crate::dispatch::{Handlers, HostError};
use crate::messages::{
    Nothing, TerminalAttachParams, TerminalCloseParams, TerminalInfo, TerminalList,
    TerminalStartParams,
};
use crate::protocol::{HostMessage, StreamData};
use crate::terminal::{Sessions, Sink, TerminalClientStream, TerminalHostStream};
use std::sync::Arc;
use tokio::sync::mpsc::UnboundedSender;

/// A connection's end of a session's stream: what the session prints goes out as the messages of the
/// stream.
pub struct ChannelSink {
    out: UnboundedSender<HostMessage>,
}

impl ChannelSink {
    pub fn sink(out: UnboundedSender<HostMessage>) -> Arc<dyn Sink> {
        Arc::new(ChannelSink { out })
    }
}

impl Sink for ChannelSink {
    fn send(&self, session: &str, message: TerminalHostStream) {
        if let Ok(serde_json::Value::Object(data)) = serde_json::to_value(message) {
            let _ = self.out.send(HostMessage::Stream {
                session: session.to_string(),
                data,
            });
        }
    }
}

/// Makes `handlers` answer the terminal requests for one connection.
pub fn terminal_handlers(
    handlers: &mut Handlers,
    sessions: Sessions,
    owner: String,
    sink: Arc<dyn Sink>,
) {
    let (s, o, k) = (sessions.clone(), owner.clone(), sink.clone());
    handlers.on::<TerminalStartParams, TerminalInfo, _, _>("terminal.start", move |params| {
        let (s, o, k) = (s.clone(), o.clone(), k.clone());
        async move { s.start(params, &o, k).await }
    });
    let (s, o, k) = (sessions.clone(), owner.clone(), sink);
    handlers.on::<TerminalAttachParams, TerminalInfo, _, _>("terminal.attach", move |params| {
        let (s, o, k) = (s.clone(), o.clone(), k.clone());
        async move { s.attach(&params.session, &o, k, params.cols, params.rows) }
    });
    let (s, o) = (sessions.clone(), owner.clone());
    handlers.on::<Nothing, TerminalList, _, _>("terminal.list", move |_| {
        let (s, o) = (s.clone(), o.clone());
        async move {
            Ok(TerminalList {
                sessions: s.list(&o),
            })
        }
    });
    let (s, o) = (sessions, owner);
    handlers.on::<TerminalCloseParams, (), _, _>("terminal.close", move |params| {
        let (s, o) = (s.clone(), o.clone());
        async move { s.close(&params.session, &o) }
    });
}

/// What the page types and the size it gives, for a session it is attached to. A stream of a session
/// that is not there or not this user's says nothing back.
pub fn terminal_stream(
    sessions: Sessions,
    owner: String,
    sink: Arc<dyn Sink>,
) -> Arc<dyn Fn(String, StreamData) + Send + Sync> {
    Arc::new(move |session, data| {
        let Ok(message) =
            serde_json::from_value::<TerminalClientStream>(serde_json::Value::Object(data))
        else {
            return;
        };
        let outcome: Result<(), HostError> = match message {
            TerminalClientStream::Input { data } => sessions.input(&session, &owner, &sink, &data),
            TerminalClientStream::Resize { cols, rows } => {
                sessions.resize(&session, &owner, &sink, cols, rows)
            }
        };
        let _ = outcome;
    })
}
