//! How the host starts programs. This file holds one test: it counts the forks of its own process.

#![cfg(unix)]

mod support;

use serde_json::Value;
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use synapse_desktop_host::agents::{AgentRun, AgentRunner};
use synapse_desktop_host::cli::{CliRun, CliRunner};
use synapse_desktop_host::messages::{AppConfig, CliBinary, Harness};
use synapse_desktop_host::models::ProgramRunner;
use synapse_desktop_host::runs::RunStarter;

static FORKS: AtomicUsize = AtomicUsize::new(0);

// `fork` calls this in the parent before it makes the child; `posix_spawn` does not.
extern "C" fn count_a_fork() {
    FORKS.fetch_add(1, Ordering::SeqCst);
}

#[tokio::test]
async fn a_program_named_without_a_folder_is_started_without_forking_the_host() {
    let dir = tempfile::tempdir().unwrap();
    for name in ["synapse", "claude", "codex"] {
        support::executable(&dir.path().join(name), "#!/bin/sh\necho ran\n");
    }
    // A run makes its record folder as it begins; `$6` is the id it is given.
    support::executable(
        &dir.path().join("synapse-pipeline"),
        "#!/bin/sh\nmkdir -p \"$SYNAPSE_WORK_DIR/pipelines/$6\"\n",
    );
    let here = dir.path().to_string_lossy().to_string();
    let base = BTreeMap::from([("PATH".to_string(), format!("{here}:/usr/bin:/bin"))]);
    let config = AppConfig {
        work_dir: Some(here.clone()),
        definition_paths: vec![],
        default_harness: None,
        default_models: BTreeMap::new(),
        default_efforts: BTreeMap::new(),
        env: BTreeMap::new(),
        recent_vaults: vec![],
        terminal_folder: None,
        graph_repos: BTreeMap::new(),
    };
    // SAFETY: the handler only adds to an atomic.
    assert_eq!(
        unsafe { libc::pthread_atfork(Some(count_a_fork), None, None) },
        0
    );

    let mut command = CliRun::new(CliBinary::Synapse, &["status"], config.clone());
    command.cwd = Some(here.clone());
    let answer = CliRunner::system(base.clone()).run(command).await.unwrap();
    assert_eq!(answer.stdout, "ran\n");

    let models = ProgramRunner::system().run("codex", &[], &base).await;
    assert_eq!(models.stdout, "ran\n");

    let agent = AgentRun {
        env: BTreeMap::new(),
        harness: Harness::Claude,
        model: None,
        effort: None,
        system: String::new(),
        prompt: String::new(),
        stop: None,
    };
    let answer = AgentRunner::system(base.clone()).run(agent).await.unwrap();
    assert_eq!(answer.stdout, "ran\n");

    RunStarter::new("synapse-pipeline", base)
        .start("Widget", &Value::Null, &config, Some(&here), None)
        .await
        .unwrap();

    assert_eq!(FORKS.load(Ordering::SeqCst), 0);
}
