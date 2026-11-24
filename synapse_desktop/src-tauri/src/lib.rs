//! The host of Synapse Desktop. The page and the host exchange the messages of `protocol` over a
//! `Link`; `messages` has the parameters and result of each request, written by hand to match the
//! shared JSON examples, and `dispatch` serves one connection. The other modules do what the
//! messages ask, family by family.

pub mod agents;
pub mod changes;
pub mod cli;
pub mod config;
pub mod definitions;
pub mod dispatch;
pub mod environment;
pub mod families;
pub mod graphs;
pub mod guards;
pub mod history;
pub mod host;
pub mod inject;
pub mod link;
pub mod messages;
pub mod models;
pub mod note_runs;
pub mod protocol;
pub mod pty;
pub mod registries;
pub mod runs;
pub mod screen;
pub mod status;
pub mod terminal;
pub mod terminal_bus;
pub mod time;
pub mod topics;
pub mod transcripts;
pub mod vault;
