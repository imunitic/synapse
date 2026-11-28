//! A program in a real pseudo-terminal: what it prints comes first, then how it ended; what is typed
//! reaches it.

#![cfg(unix)]

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use synapse_desktop_host::pty::{system_spawn, EndSignal, PtyEvent, SpawnOptions};

fn options(cwd: &str) -> SpawnOptions {
    SpawnOptions {
        cwd: cwd.into(),
        env: BTreeMap::from([("PATH".to_string(), "/usr/bin:/bin".to_string())]),
        cols: 80,
        rows: 24,
    }
}

fn collecting() -> (
    Arc<Mutex<Vec<PtyEvent>>>,
    synapse_desktop_host::pty::OnEvent,
) {
    let seen: Arc<Mutex<Vec<PtyEvent>>> = Default::default();
    let kept = seen.clone();
    (
        seen,
        Arc::new(move |event| kept.lock().unwrap().push(event)),
    )
}

async fn until(done: impl Fn() -> bool) {
    for _ in 0..400 {
        if done() {
            return;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    panic!("timed out");
}

fn text(seen: &Mutex<Vec<PtyEvent>>) -> String {
    seen.lock()
        .unwrap()
        .iter()
        .filter_map(|e| {
            if let PtyEvent::Data(d) = e {
                Some(d.clone())
            } else {
                None
            }
        })
        .collect()
}

#[tokio::test]
async fn what_a_program_prints_comes_before_how_it_ended() {
    let (seen, on_event) = collecting();
    let args = vec!["-c".to_string(), "printf hello; exit 3".to_string()];
    let _pty = (system_spawn())("/bin/sh", &args, options("/"), on_event).unwrap();
    until(|| {
        seen.lock()
            .unwrap()
            .iter()
            .any(|e| matches!(e, PtyEvent::Exit(_)))
    })
    .await;
    let events = seen.lock().unwrap().clone();
    assert_eq!(events.last(), Some(&PtyEvent::Exit(3)));
    assert!(text(&seen).contains("hello"));
}

#[tokio::test]
async fn what_is_typed_reaches_the_program_and_a_kill_ends_it() {
    let (seen, on_event) = collecting();
    let pty = (system_spawn())("/bin/cat", &[], options("/"), on_event).unwrap();
    pty.write("ping\r");
    until(|| text(&seen).contains("ping")).await;
    pty.kill();
    until(|| {
        seen.lock()
            .unwrap()
            .iter()
            .any(|e| matches!(e, PtyEvent::Exit(_)))
    })
    .await;
}

#[tokio::test]
async fn a_program_that_is_not_there_is_refused_with_the_reason() {
    let (_, on_event) = collecting();
    let error = (system_spawn())("/no/such/program", &[], options("/"), on_event).err();
    assert!(error.is_some());
}

#[tokio::test]
async fn terminating_the_group_ends_what_the_program_started() {
    let (seen, on_event) = collecting();
    let args = vec!["-c".to_string(), "sleep 60 & echo $!; wait".to_string()];
    let pty = (system_spawn())("/bin/sh", &args, options("/"), on_event).unwrap();
    until(|| text(&seen).contains('\n')).await;
    let pid: i32 = text(&seen)
        .lines()
        .next()
        .and_then(|line| line.trim().parse().ok())
        .expect("the background pid");
    pty.signal(EndSignal::Terminate);
    // SAFETY: `kill` with signal 0 only asks whether the process is there.
    until(|| unsafe { libc::kill(pid, 0) } != 0).await;
}

#[tokio::test]
async fn terminating_an_interactive_shell_ends_its_background_jobs() {
    // An interactive shell puts each background job in a process group of its own; the SIGHUP it
    // gets reaches the job because the shell passes it on, as when a terminal window is closed.
    let (seen, on_event) = collecting();
    let args = vec![
        "--norc".to_string(),
        "--noprofile".to_string(),
        "-i".to_string(),
    ];
    let pty = (system_spawn())("/bin/bash", &args, options("/"), on_event).unwrap();
    pty.write("sleep 60 & echo \"BG=$!=GB\"\r");
    let background = || {
        let text = text(&seen);
        let start = text.rfind("BG=")? + 3;
        let end = start + text[start..].find("=GB")?;
        text[start..end].parse::<i32>().ok()
    };
    until(|| background().is_some()).await;
    let pid = background().unwrap();
    pty.signal(EndSignal::Terminate);
    // SAFETY: `kill` with signal 0 only asks whether the process is there.
    until(|| unsafe { libc::kill(pid, 0) } != 0).await;
}
