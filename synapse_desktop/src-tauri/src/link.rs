//! A Link is a pipe that sends one kind of message and delivers the other: a WebSocket for the
//! served build, Tauri's IPC for the desktop build, and a pair of channels in a test. The two ends
//! are of two types: the client sends what the host receives, and the other way round. What carries
//! the messages reads and writes JSON and hands the host the typed messages here.

use crate::protocol::{ClientMessage, HostMessage};
use tokio::sync::mpsc::{unbounded_channel, UnboundedReceiver, UnboundedSender};

/// The host's end of a connection.
pub struct HostLink {
    pub incoming: UnboundedReceiver<ClientMessage>,
    pub outgoing: UnboundedSender<HostMessage>,
}

/// The page's end of a connection.
pub struct ClientLink {
    pub incoming: UnboundedReceiver<HostMessage>,
    pub outgoing: UnboundedSender<ClientMessage>,
}

/// The two ends of one connection. Dropping either end closes the other.
pub fn link_pair() -> (ClientLink, HostLink) {
    let (to_host, host_incoming) = unbounded_channel();
    let (to_client, client_incoming) = unbounded_channel();
    (
        ClientLink {
            incoming: client_incoming,
            outgoing: to_host,
        },
        HostLink {
            incoming: host_incoming,
            outgoing: to_client,
        },
    )
}
