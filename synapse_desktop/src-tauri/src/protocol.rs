//! The messages between the page and a host, whatever carries them. A request has an id and is
//! answered by one reply with the same id; a host publishes events to the clients subscribed to a
//! topic; a stream carries the bytes of a terminal. The same messages are defined for the Node host
//! in `shared/protocol.ts`; the shared example files keep the two alike.

use serde::{Deserialize, Deserializer, Serialize};
use serde_json::{Map, Value};

/// Changes with any change to a message that an older page or host would misread.
pub const PROTOCOL_VERSION: u32 = 1;

/// What went wrong, as a code and not as the status of an HTTP reply.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    /// The parameters are not the ones the message takes.
    BadRequest,
    /// What was asked for is not there.
    NotFound,
    /// The host refuses it: outside the folders it may touch, or not allowed.
    Forbidden,
    /// The state of things does not allow it.
    Conflict,
    TooLarge,
    /// Something the host depends on failed: a program, a harness.
    Unavailable,
    Internal,
}

/// The code that stands for the status a handler of the Node host gave.
pub fn code_of_status(status: u16) -> ErrorCode {
    match status {
        400 => ErrorCode::BadRequest,
        401 | 403 => ErrorCode::Forbidden,
        404 => ErrorCode::NotFound,
        409 => ErrorCode::Conflict,
        413 => ErrorCode::TooLarge,
        502 | 503 => ErrorCode::Unavailable,
        _ => ErrorCode::Internal,
    }
}

/// What a client subscribes to: the files of a place, the events of a run, or the usage of the
/// harnesses.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq, Hash)]
#[serde(try_from = "String", into = "String")]
pub struct Topic(String);

impl Topic {
    pub fn parse(text: &str) -> Option<Topic> {
        let id = |id: &str| {
            (1..=64).contains(&id.len())
                && id
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        };
        let valid = match (text.strip_prefix("run."), text.strip_prefix("note-run.")) {
            (Some(run), _) => id(run),
            (_, Some(run)) => id(run),
            _ => matches!(
                text,
                "usage" | "files.work" | "files.definitions" | "files.vault"
            ),
        };
        valid.then(|| Topic(text.to_string()))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for Topic {
    type Error = String;

    fn try_from(text: String) -> Result<Self, String> {
        Topic::parse(&text).ok_or_else(|| format!("{text} is not a topic"))
    }
}

impl From<Topic> for String {
    fn from(topic: Topic) -> String {
        topic.0
    }
}

/// Where an event stream resumes: the index of the last event a client has.
pub type Cursor = u64;

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum HostKind {
    Node,
    Tauri,
    Fake,
}

/// What a host can do, which the page adapts to instead of assuming.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Capabilities {
    pub host: HostKind,
    /// A shell can be started.
    pub shell: bool,
    /// The programs and skills can be installed into the harnesses from the app.
    pub install_actions: bool,
}

/// What a message of a stream carries: the object of one terminal message.
pub type StreamData = Map<String, Value>;

/// What the page sends.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum ClientMessage {
    Request {
        id: String,
        name: String,
        #[serde(default)]
        params: Value,
    },
    Subscribe {
        topic: Topic,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        after: Option<Cursor>,
    },
    Unsubscribe {
        topic: Topic,
    },
    Stream {
        session: String,
        data: StreamData,
    },
}

fn in_bounds(text: &str) -> bool {
    (1..=64).contains(&text.len())
}

impl ClientMessage {
    /// Reads a message from text; one that is not a message, or whose ids are not of the size ids
    /// have, is not one.
    pub fn parse(text: &str) -> Option<ClientMessage> {
        let message: ClientMessage = serde_json::from_str(text).ok()?;
        let valid = match &message {
            ClientMessage::Request { id, name, .. } => in_bounds(id) && in_bounds(name),
            ClientMessage::Stream { session, .. } => in_bounds(session),
            _ => true,
        };
        valid.then_some(message)
    }
}

/// A present value, `null` included, and none when the member is absent.
fn present<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Option<Value>, D::Error> {
    Value::deserialize(deserializer).map(Some)
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct ReplyError {
    pub code: ErrorCode,
    pub message: String,
}

/// What a host sends.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum HostMessage {
    /// The first message of a connection: which protocol the host speaks and what it can do.
    Hello {
        protocol: u32,
        capabilities: Capabilities,
    },
    /// The answer to a request: a result, which is `null` for a request with nothing to say, or an
    /// error.
    Reply {
        id: String,
        #[serde(
            default,
            deserialize_with = "present",
            skip_serializing_if = "Option::is_none"
        )]
        result: Option<Value>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<ReplyError>,
    },
    Event {
        topic: Topic,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cursor: Option<Cursor>,
        data: Value,
    },
    Stream {
        session: String,
        data: StreamData,
    },
}

impl HostMessage {
    pub fn result(id: &str, result: Value) -> HostMessage {
        HostMessage::Reply {
            id: id.to_string(),
            result: Some(result),
            error: None,
        }
    }

    pub fn error(id: &str, code: ErrorCode, message: impl Into<String>) -> HostMessage {
        HostMessage::Reply {
            id: id.to_string(),
            result: None,
            error: Some(ReplyError {
                code,
                message: message.into(),
            }),
        }
    }
}
