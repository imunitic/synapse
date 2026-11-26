//! Runs of a pipeline: starting one with an id of the host's own drawing, stopping it and what it
//! started, and asking it about itself over its socket. The same cases as the Node host's `runs.test.ts`
//! and `run-socket.test.ts`.

// Some cases need a Unix shell or socket; what only they use is unused on Windows.
#![cfg_attr(windows, allow(unused_imports, dead_code))]

mod support;

use serde_json::json;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use synapse_desktop_host::messages::{AppConfig, RunRequest};
#[cfg(unix)]
use synapse_desktop_host::runs::is_private_folder;
use synapse_desktop_host::runs::{
    ask_run, fnv1a_64_hex, socket_endpoint, socket_path, AskError, NotStartedHere, RunNotStarted,
    RunStarter, MAX_SOCKET_PATH,
};
use tempfile::tempdir;

fn config(work: Option<&Path>) -> AppConfig {
    AppConfig {
        work_dir: work.map(|w| w.to_string_lossy().to_string()),
        definition_paths: vec![],
        default_harness: None,
        default_models: BTreeMap::new(),
        env: BTreeMap::new(),
        recent_vaults: vec![],
        terminal_folder: None,
        graph_repos: BTreeMap::new(),
    }
}

#[test]
fn the_socket_is_execution_sock_in_the_record_folder_or_a_named_pipe_on_windows() {
    assert_eq!(
        socket_path(Path::new("/w/pipelines"), "exec-1", false),
        PathBuf::from("/w/pipelines/exec-1/execution.sock")
    );
    assert_eq!(
        socket_path(Path::new("/w/pipelines"), "exec-1", true),
        PathBuf::from("\\\\.\\pipe\\synapse-pipeline-exec-1")
    );
}

// The same values as `synapse-pipeline`'s Socket_Paths tests and the Node host's: the first two are
// the published FNV-1a 64 test values, the third the example the three share.
#[test]
fn the_hash_is_fnv1a_64() {
    assert_eq!(fnv1a_64_hex(b""), "cbf29ce484222325");
    assert_eq!(fnv1a_64_hex(b"a"), "af63dc4c8601ec8c");
    assert_eq!(
        fnv1a_64_hex(b"/Users/example/.cache/synapse/work/pipelines/probe1"),
        "04096b4c0fbf6a6c"
    );
}

#[test]
fn a_socket_path_that_fits_stays_in_the_record_folder_and_a_longer_one_goes_to_the_short_folder() {
    // With "/execution.sock", exactly MAX_SOCKET_PATH bytes.
    let longest = format!(
        "/{}",
        "r".repeat(MAX_SOCKET_PATH - 1 - "execution.sock".len() - 1)
    );
    assert_eq!(
        socket_endpoint(Path::new(&longest), 501),
        PathBuf::from(format!("{longest}/execution.sock"))
    );
    let over = format!(
        "/{}",
        "r".repeat(MAX_SOCKET_PATH - "execution.sock".len() - 1)
    );
    let got = socket_endpoint(Path::new(&over), 501);
    assert_eq!(
        got,
        PathBuf::from(format!(
            "/tmp/synapse-pipeline-501/{}.sock",
            fnv1a_64_hex(over.as_bytes())
        ))
    );
    assert!(got.as_os_str().len() <= MAX_SOCKET_PATH);
}

#[cfg(unix)]
mod socket_folders {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn uid() -> u32 {
        unsafe { libc::getuid() }
    }

    #[test]
    fn the_record_folder_is_hashed_as_it_is_on_disk() {
        let dir = tempdir().unwrap();
        let base = std::fs::canonicalize(dir.path()).unwrap();
        let deep = base.join("d".repeat(90)).join("pipelines");
        std::fs::create_dir_all(deep.join("Exec-Case")).unwrap();
        let expected = socket_endpoint(&deep.join("Exec-Case"), uid());
        assert_eq!(socket_path(&deep, "Exec-Case", false), expected);
        // On a file system that ignores case, another spelling is the same folder and the same socket.
        if deep.join("exec-case").exists() {
            assert_eq!(socket_path(&deep, "exec-case", false), expected);
        }
        // A link to the records folder gives the socket of the folder it points to.
        std::os::unix::fs::symlink(&deep, base.join("link")).unwrap();
        assert_eq!(
            socket_path(&base.join("link"), "Exec-Case", false),
            expected
        );
    }

    #[test]
    fn only_a_folder_of_this_users_own_with_no_access_for_others_is_private() {
        let dir = tempdir().unwrap();
        let own = dir.path().join("own");
        std::fs::create_dir(&own).unwrap();
        std::fs::set_permissions(&own, std::fs::Permissions::from_mode(0o700)).unwrap();
        assert!(is_private_folder(&own, uid()));
        assert!(!is_private_folder(&own, uid() + 1), "another user's");
        std::fs::set_permissions(&own, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(!is_private_folder(&own, uid()), "others may enter it");
        std::fs::set_permissions(&own, std::fs::Permissions::from_mode(0o700)).unwrap();
        let link = dir.path().join("link");
        std::os::unix::fs::symlink(&own, &link).unwrap();
        assert!(!is_private_folder(&link, uid()), "a symbolic link");
        let file = dir.path().join("file");
        std::fs::write(&file, "").unwrap();
        assert!(!is_private_folder(&file, uid()), "a file");
        assert!(!is_private_folder(&dir.path().join("missing"), uid()));
    }
}

#[cfg(unix)]
mod unix {
    use super::*;
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::UnixListener;

    /// A stand-in for the synapse-pipeline of an npm install: a shim that runs the real thing as its
    /// child. It does what `run --id` does: makes the record folder named by the id, or refuses an id
    /// that is taken, and then goes on and waits.
    const STUB: &str = r#"#!/bin/sh
input=$(cat)
pipeline="$2"
id=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--id" ]; then id="$2"; fi
  shift
done
dir="$SYNAPSE_WORK_DIR/pipelines/$id"
if [ -d "$dir" ]; then
  echo "error: execution $id already exists" >&2
  exit 1
fi
mkdir -p "$dir"
echo "$pipeline $input" > "$dir/started-with"
pwd -P > "$dir/folder"
echo $$ > "$dir/pid"
sleep 30 &
echo $! > "$dir/child.pid"
wait
"#;

    const FAILING_STUB: &str =
        "#!/bin/sh\ncat > /dev/null\necho \"error: step Develop has no harness\" >&2\nexit 1\n";

    fn script(dir: &Path, name: &str, text: &str) -> String {
        let path = dir.join(name);
        support::executable(&path, text);
        path.to_string_lossy().to_string()
    }

    fn alive(pid: i32) -> bool {
        // SAFETY: signal 0 only asks whether the process is there.
        unsafe { libc::kill(pid, 0) == 0 }
    }

    /// `start` returns when the record folder exists, as the real program makes it first; the stub
    /// writes what else it keeps a moment after.
    async fn read_when_written(path: &Path) -> String {
        for _ in 0..200 {
            if let Ok(text) = std::fs::read_to_string(path) {
                if text.ends_with('\n') {
                    return text;
                }
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        panic!("{} was never written", path.display());
    }

    async fn pids_of(work: &Path, id: &str) -> (i32, i32) {
        let record = work.join("pipelines").join(id);
        let pid = read_when_written(&record.join("pid"))
            .await
            .trim()
            .parse()
            .unwrap();
        let child = read_when_written(&record.join("child.pid"))
            .await
            .trim()
            .parse()
            .unwrap();
        (pid, child)
    }

    fn setup() -> (tempfile::TempDir, PathBuf) {
        let dir = tempdir().unwrap();
        let work = dir.path().join("work");
        std::fs::create_dir_all(work.join("pipelines")).unwrap();
        (dir, work)
    }

    #[tokio::test]
    async fn the_program_is_given_the_id_it_returns_in_the_form_the_program_draws_its_own() {
        let (dir, work) = setup();
        let starter = RunStarter::new(
            &script(dir.path(), "stub", STUB),
            std::env::vars().collect(),
        );
        let id = starter
            .start("P", &json!({ "task": "x" }), &config(Some(&work)), None)
            .await
            .unwrap();
        assert!(
            regex::Regex::new(r"^exec-[0-9a-f]{8}$")
                .unwrap()
                .is_match(&id),
            "{id}"
        );
        let started =
            read_when_written(&work.join("pipelines").join(&id).join("started-with")).await;
        assert_eq!(started.trim(), "P {\"task\":\"x\"}");
        starter.stop(&id).unwrap();
    }

    #[tokio::test]
    async fn stopping_a_run_stops_what_it_started() {
        let (dir, work) = setup();
        let starter = RunStarter::new(
            &script(dir.path(), "stub", STUB),
            std::env::vars().collect(),
        );
        let id = starter
            .start("P", &json!({}), &config(Some(&work)), None)
            .await
            .unwrap();
        let (pid, child) = pids_of(&work, &id).await;
        assert!(alive(pid) && alive(child));

        starter.stop(&id).unwrap();
        for _ in 0..40 {
            if !alive(pid) && !alive(child) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        assert!(!alive(pid));
        // The process the first one started goes with it.
        assert!(!alive(child));
    }

    #[tokio::test]
    async fn two_runs_of_the_same_pipeline_and_input_have_an_id_each_and_stopping_one_leaves_the_other(
    ) {
        let (dir, work) = setup();
        let starter = RunStarter::new(
            &script(dir.path(), "stub", STUB),
            std::env::vars().collect(),
        );
        let cfg = config(Some(&work));
        let input = json!({ "task": "same" });
        let (first, second) = tokio::join!(
            starter.start("P", &input, &cfg, None),
            starter.start("P", &input, &cfg, None)
        );
        let (first, second) = (first.unwrap(), second.unwrap());
        assert_ne!(first, second);
        let a = pids_of(&work, &first).await;
        let b = pids_of(&work, &second).await;
        starter.stop(&first).unwrap();
        for _ in 0..40 {
            if !alive(a.0) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        assert!(!alive(a.0));
        assert!(alive(b.0));
        starter.stop(&second).unwrap();
    }

    #[tokio::test]
    async fn a_run_that_was_not_started_here_cannot_be_stopped() {
        let (dir, _) = setup();
        let starter = RunStarter::new(
            &script(dir.path(), "stub", STUB),
            std::env::vars().collect(),
        );
        assert_eq!(starter.stop("exec-unknown"), Err(NotStartedHere));
    }

    #[tokio::test]
    async fn what_the_binary_printed_is_reported_when_the_run_is_refused() {
        let (dir, work) = setup();
        let starter = RunStarter::new(
            &script(dir.path(), "failing", FAILING_STUB),
            std::env::vars().collect(),
        );
        let error = starter
            .start("P", &json!({}), &config(Some(&work)), None)
            .await
            .unwrap_err();
        assert!(
            error.0.contains("step Develop has no harness"),
            "{}",
            error.0
        );
    }

    #[tokio::test]
    async fn a_run_does_not_start_without_a_work_directory_or_with_a_binary_that_cannot_be_run() {
        let (dir, work) = setup();
        let starter = RunStarter::new(
            &script(dir.path(), "stub", STUB),
            std::env::vars().collect(),
        );
        assert_eq!(
            starter.start("P", &json!({}), &config(None), None).await,
            Err(RunNotStarted("no work directory is set".into()))
        );
        let missing = RunStarter::new(
            &dir.path().join("missing").to_string_lossy(),
            std::env::vars().collect(),
        );
        let error = missing
            .start("P", &json!({}), &config(Some(&work)), None)
            .await
            .unwrap_err();
        assert!(error.0.contains("could not be run"));
    }

    fn real(path: &Path) -> String {
        std::fs::canonicalize(path)
            .unwrap()
            .to_string_lossy()
            .to_string()
    }

    #[tokio::test]
    async fn a_run_works_in_the_folder_it_is_given() {
        let (dir, work) = setup();
        let folder = dir.path().join("repo");
        std::fs::create_dir(&folder).unwrap();
        let starter = RunStarter::new(
            &script(dir.path(), "stub", STUB),
            std::env::vars().collect(),
        );
        let id = starter
            .start(
                "P",
                &json!({}),
                &config(Some(&work)),
                Some(&folder.to_string_lossy()),
            )
            .await
            .unwrap();
        let ran = read_when_written(&work.join("pipelines").join(&id).join("folder")).await;
        assert_eq!(ran.trim(), real(&folder));
        starter.stop(&id).unwrap();
    }

    #[tokio::test]
    async fn a_run_given_no_folder_or_a_blank_one_works_in_the_home_folder() {
        let (dir, work) = setup();
        let home = dir.path().join("home");
        std::fs::create_dir(&home).unwrap();
        let mut env: BTreeMap<String, String> = std::env::vars().collect();
        env.insert("HOME".into(), home.to_string_lossy().to_string());
        let starter = RunStarter::new(&script(dir.path(), "stub", STUB), env);
        for folder in [None, Some("  ")] {
            let id = starter
                .start("P", &json!({}), &config(Some(&work)), folder)
                .await
                .unwrap();
            let ran = read_when_written(&work.join("pipelines").join(&id).join("folder")).await;
            assert_eq!(ran.trim(), real(&home), "{folder:?}");
            starter.stop(&id).unwrap();
        }
    }

    #[tokio::test]
    async fn a_relative_folder_is_refused_with_its_name_and_leaves_no_record() {
        let (dir, work) = setup();
        let starter = RunStarter::new(
            &script(dir.path(), "stub", STUB),
            std::env::vars().collect(),
        );
        for folder in ["project", "."] {
            assert_eq!(
                starter
                    .start("P", &json!({}), &config(Some(&work)), Some(folder))
                    .await,
                Err(RunNotStarted(format!(
                    "the folder {folder} is not an absolute path"
                )))
            );
        }
        assert_eq!(
            std::fs::read_dir(work.join("pipelines")).unwrap().count(),
            0
        );
    }

    #[tokio::test]
    async fn a_folder_that_does_not_exist_is_refused_with_its_name_and_leaves_no_record() {
        let (dir, work) = setup();
        let missing = dir.path().join("missing").to_string_lossy().to_string();
        let starter = RunStarter::new(
            &script(dir.path(), "stub", STUB),
            std::env::vars().collect(),
        );
        assert_eq!(
            starter
                .start("P", &json!({}), &config(Some(&work)), Some(&missing))
                .await,
            Err(RunNotStarted(format!(
                "the folder {missing} does not exist"
            )))
        );
        assert_eq!(
            std::fs::read_dir(work.join("pipelines")).unwrap().count(),
            0
        );
    }

    // The socket ----------------------------------------------------------------------------

    /// A Unix socket path is limited to about 100 characters, which the system temporary folder of
    /// macOS can use up on its own.
    fn short_dir() -> tempfile::TempDir {
        tempfile::Builder::new()
            .prefix("sd-")
            .tempdir_in("/tmp")
            .unwrap()
    }

    /// Listens on a socket and answers each request line with what `reply` says, or not at all.
    async fn listen(
        dir: &Path,
        reply: impl Fn(String) -> Option<String> + Send + Sync + 'static,
    ) -> (PathBuf, std::sync::Arc<std::sync::Mutex<String>>) {
        let path = dir.join("run.sock");
        let listener = UnixListener::bind(&path).unwrap();
        let seen = std::sync::Arc::new(std::sync::Mutex::new(String::new()));
        let kept = seen.clone();
        let reply = std::sync::Arc::new(reply);
        tokio::spawn(async move {
            while let Ok((mut stream, _)) = listener.accept().await {
                let (kept, reply) = (kept.clone(), reply.clone());
                tokio::spawn(async move {
                    let mut text = String::new();
                    let mut chunk = [0u8; 1024];
                    while !text.contains('\n') {
                        let n = stream.read(&mut chunk).await.unwrap_or(0);
                        if n == 0 {
                            return;
                        }
                        text.push_str(&String::from_utf8_lossy(&chunk[..n]));
                    }
                    *kept.lock().unwrap() = text.trim().to_string();
                    if let Some(answer) = reply(text.trim().to_string()) {
                        let _ = stream.write_all(answer.as_bytes()).await;
                    }
                });
            }
        });
        (path, seen)
    }

    #[tokio::test]
    async fn the_request_is_sent_as_one_json_line_and_the_answer_is_returned() {
        let dir = short_dir();
        let (path, seen) = listen(dir.path(), |_| {
            Some(json!({ "ok": true, "result": { "status": "running" } }).to_string())
        })
        .await;
        let answer = ask_run(&path, &RunRequest::Info).await.unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&seen.lock().unwrap()).unwrap(),
            json!({ "command": "info" })
        );
        assert!(answer.ok);
        assert_eq!(answer.result, Some(json!({ "status": "running" })));

        // The other requests are as the program reads them.
        ask_run(&path, &RunRequest::Events { after: Some(12) })
            .await
            .unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&seen.lock().unwrap()).unwrap(),
            json!({ "command": "events", "after": 12 })
        );
        ask_run(
            &path,
            &RunRequest::Query {
                expression: json!({ "var": "state" }),
            },
        )
        .await
        .unwrap();
        assert_eq!(
            serde_json::from_str::<serde_json::Value>(&seen.lock().unwrap()).unwrap(),
            json!({ "command": "query", "expression": { "var": "state" } })
        );
    }

    #[tokio::test]
    async fn an_error_answer_is_returned_as_it_is() {
        let dir = short_dir();
        let (path, _) = listen(dir.path(), |_| {
            Some(json!({ "ok": false, "error": "unknown command" }).to_string())
        })
        .await;
        let answer = ask_run(&path, &RunRequest::Info).await.unwrap();
        assert!(!answer.ok);
        assert_eq!(answer.error.as_deref(), Some("unknown command"));
    }

    #[tokio::test]
    async fn nothing_listening_is_not_listening_and_an_answer_that_is_not_json_is_not() {
        let dir = short_dir();
        assert!(matches!(
            ask_run(&dir.path().join("gone.sock"), &RunRequest::Info).await,
            Err(AskError::NotListening(_))
        ));
        let (path, _) = listen(dir.path(), |_| Some("not json".into())).await;
        assert!(matches!(
            ask_run(&path, &RunRequest::Info).await,
            Err(AskError::Unreadable(_))
        ));
    }
}

#[tokio::test]
async fn through_the_host_a_run_that_cannot_start_is_unavailable_and_one_not_started_here_is_not_found(
) {
    use support::{environment, Host};
    use synapse_desktop_host::protocol::ErrorCode;
    let dir = tempdir().unwrap();
    let mut host = Host::new(
        environment(
            dir.path(),
            &[("XDG_CONFIG_HOME", &dir.path().join("xdg").to_string_lossy())],
        ),
        &dir.path().join("config.json"),
    )
    .await;
    // A folder that is not there is the caller's mistake.
    let missing = dir.path().join("missing").to_string_lossy().to_string();
    let refused = host
        .ask(
            "run.start",
            json!({ "pipeline": "Develop", "input": {}, "folder": missing }),
        )
        .await
        .unwrap_err();
    assert_eq!(
        refused,
        (
            ErrorCode::BadRequest,
            format!("the folder {missing} does not exist")
        )
    );
    // Nor is a relative folder, which would resolve against the app's own folder.
    let relative = host
        .ask(
            "run.start",
            json!({ "pipeline": "Develop", "input": {}, "folder": "project" }),
        )
        .await
        .unwrap_err();
    assert_eq!(
        relative,
        (
            ErrorCode::BadRequest,
            "the folder project is not an absolute path".to_string()
        )
    );
    // There is no synapse-pipeline here to start, in a folder that is there.
    let start = host
        .ask(
            "run.start",
            json!({ "pipeline": "Develop", "input": { "task": "x" }, "folder": dir.path() }),
        )
        .await
        .unwrap_err();
    assert_eq!(start.0, ErrorCode::Unavailable);
    let stop = host
        .ask("run.stop", json!({ "executionId": "exec-0a1b2c3d" }))
        .await
        .unwrap_err();
    assert_eq!(
        stop,
        (
            ErrorCode::NotFound,
            "this run was not started by this app".to_string()
        )
    );
    // Nothing listens for the run, in the work folder there is by default.
    let ask = host
        .ask(
            "run.ask",
            json!({ "executionId": "exec-0a1b2c3d", "request": { "command": "info" } }),
        )
        .await
        .unwrap_err();
    assert_eq!(
        ask,
        (ErrorCode::NotFound, "the run is not listening".to_string())
    );
    let bad = host
        .ask(
            "run.ask",
            json!({ "executionId": "../x", "request": { "command": "info" } }),
        )
        .await
        .unwrap_err();
    assert_eq!(bad.0, ErrorCode::BadRequest);
}
