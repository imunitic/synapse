//! Any web page the user visits can open a connection to a localhost server, so a connection has to
//! prove it comes from this app's own page: the host and the origin are the app's own, and the token
//! of this launch is given.

use std::collections::HashSet;

#[derive(Clone, Debug)]
pub struct Policy {
    pub allowed_hosts: HashSet<String>,
    pub allowed_origins: HashSet<String>,
    pub token: String,
}

/// Why a connection is refused: the HTTP status to answer with, and the reason.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
    pub status: u16,
    pub error: &'static str,
}

/// The same token, compared in the time of its length and not of how much of it matches.
fn same_token(given: &str, expected: &str) -> bool {
    let (a, b) = (given.as_bytes(), expected.as_bytes());
    a.len() == b.len() && a.iter().zip(b).fold(0u8, |d, (x, y)| d | (x ^ y)) == 0
}

/// None when the handshake may go on. A request with no Origin does not come from a page; it still
/// needs the token.
pub fn check_upgrade(
    host: Option<&str>,
    origin: Option<&str>,
    token: Option<&str>,
    policy: &Policy,
) -> Option<Refusal> {
    if !host.is_some_and(|h| policy.allowed_hosts.contains(h)) {
        return Some(Refusal {
            status: 403,
            error: "host not allowed",
        });
    }
    if origin.is_some_and(|o| !policy.allowed_origins.contains(o)) {
        return Some(Refusal {
            status: 403,
            error: "origin not allowed",
        });
    }
    if !token.is_some_and(|t| same_token(t, &policy.token)) {
        return Some(Refusal {
            status: 401,
            error: "missing or wrong token",
        });
    }
    None
}
