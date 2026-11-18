//! A connection has to prove it comes from the app's own page. The same cases as the Node host's
//! `guards.test.ts`.

use std::collections::HashSet;
use synapse_desktop_host::guards::{check_upgrade, Policy, Refusal};

fn policy() -> Policy {
    Policy {
        allowed_hosts: HashSet::from(["127.0.0.1:5174".to_string()]),
        allowed_origins: HashSet::from(["http://127.0.0.1:5173".to_string()]),
        token: "secret".into(),
    }
}

fn refusal(status: u16, error: &'static str) -> Option<Refusal> {
    Some(Refusal { status, error })
}

#[test]
fn a_connection_from_the_apps_page_with_the_token_may_go_on() {
    let p = policy();
    assert_eq!(
        check_upgrade(
            Some("127.0.0.1:5174"),
            Some("http://127.0.0.1:5173"),
            Some("secret"),
            &p
        ),
        None
    );
    // No Origin: not a page, but it has the token.
    assert_eq!(
        check_upgrade(Some("127.0.0.1:5174"), None, Some("secret"), &p),
        None
    );
}

#[test]
fn a_host_an_origin_or_a_token_that_is_not_the_apps_is_refused() {
    let p = policy();
    assert_eq!(
        check_upgrade(Some("evil.test:5174"), None, Some("secret"), &p),
        refusal(403, "host not allowed")
    );
    assert_eq!(
        check_upgrade(None, None, Some("secret"), &p),
        refusal(403, "host not allowed")
    );
    assert_eq!(
        check_upgrade(
            Some("127.0.0.1:5174"),
            Some("http://evil.test"),
            Some("secret"),
            &p
        ),
        refusal(403, "origin not allowed")
    );
    for token in [None, Some("wrong"), Some("secre"), Some("secrets")] {
        assert_eq!(
            check_upgrade(Some("127.0.0.1:5174"), None, token, &p),
            refusal(401, "missing or wrong token")
        );
    }
}
