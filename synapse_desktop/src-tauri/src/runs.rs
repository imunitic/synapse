//! Runs of a pipeline: starting one, stopping it, and asking it about itself over its socket. The host
//! draws the run's id and gives it to `synapse-pipeline run --id`, so the run is known by its id from
//! the start: its record folder, named by the id, is made as the run begins.

use crate::cli::cli_environment;
use crate::messages::{AppConfig, RunAnswer, RunRequest};
use serde_json::Value;
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const POLL: Duration = Duration::from_millis(50);
const FIND_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_STDERR_BYTES: usize = 8192;

/// The run was not started here, so it is not this app's to stop.
#[derive(Debug, PartialEq)]
pub struct NotStartedHere;

/// The run did not start, with why.
#[derive(Debug, PartialEq)]
pub struct RunNotStarted(pub String);

fn draw_id() -> String {
    let mut bytes = [0u8; 4];
    getrandom::fill(&mut bytes).expect("the system gives random bytes");
    format!(
        "exec-{}",
        bytes.iter().map(|b| format!("{b:02x}")).collect::<String>()
    )
}

/// Ends the process and everything it started. The `synapse-pipeline` that is on PATH after an npm
/// install is a shim that runs the real binary as its child and passes no signal on, so killing the
/// shim alone leaves the run going.
fn kill_tree(pid: u32) {
    #[cfg(windows)]
    {
        let _ = std::process::Command::new("taskkill")
            .args(["/pid", &pid.to_string(), "/T", "/F"])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn();
    }
    #[cfg(unix)]
    {
        let pid = pid as i32;
        // SAFETY: `kill` takes no pointers; a process group that is gone is an error, not a fault.
        unsafe {
            if libc::kill(-pid, libc::SIGTERM) != 0 {
                libc::kill(pid, libc::SIGTERM);
            }
        }
    }
}

/// Starts runs of `binary` and stops the ones it started.
#[derive(Clone)]
pub struct RunStarter {
    binary: String,
    base_env: BTreeMap<String, String>,
    children: Arc<Mutex<HashMap<String, u32>>>,
}

impl RunStarter {
    /// `binary` is looked up on PATH unless it is a path.
    pub fn new(binary: &str, base_env: BTreeMap<String, String>) -> RunStarter {
        RunStarter {
            binary: binary.into(),
            base_env,
            children: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// The folder a run given `folder` works in: a missing or blank one is the home folder of the
    /// starter's environment (`HOME`, or `USERPROFILE` on Windows); one that is not absolute is
    /// refused, so that it never resolves against the app's own folder; one that is not a directory
    /// is refused.
    pub fn folder(&self, folder: Option<&str>) -> Result<PathBuf, RunNotStarted> {
        let folder = match folder.filter(|given| !given.trim().is_empty()) {
            Some(given) if !Path::new(given).is_absolute() => {
                return Err(RunNotStarted(format!(
                    "the folder {given} is not an absolute path"
                )))
            }
            Some(given) => PathBuf::from(given),
            None => self
                .base_env
                .get("HOME")
                .or_else(|| self.base_env.get("USERPROFILE"))
                .map(PathBuf::from)
                .unwrap_or_default(),
        };
        if folder.is_dir() {
            Ok(folder)
        } else {
            Err(RunNotStarted(format!(
                "the folder {} does not exist",
                folder.display()
            )))
        }
    }

    /// Starts a run that works in `folder`, as `folder` resolves it.
    pub async fn start(
        &self,
        pipeline: &str,
        input: &Value,
        config: &AppConfig,
        folder: Option<&str>,
        run_name: Option<&str>,
    ) -> Result<String, RunNotStarted> {
        let work_dir = config
            .work_dir
            .as_ref()
            .ok_or_else(|| RunNotStarted("no work directory is set".into()))?;
        let folder = self.folder(folder)?;
        let id = draw_id();
        let record = Path::new(work_dir).join("pipelines").join(&id);

        let mut command = tokio::process::Command::new(&self.binary);
        command
            .args(["run", pipeline, "--input", "-", "--id", &id])
            .args(run_name.map(|name| ["--name", name]).into_iter().flatten())
            .current_dir(&folder)
            .env_clear()
            .envs(cli_environment(&self.base_env, config))
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(false);
        // Its own process group, so that stop can end the whole tree.
        #[cfg(unix)]
        command.process_group(0);
        let mut child = command
            .spawn()
            .map_err(|_| RunNotStarted(format!("{} could not be run", self.binary)))?;
        let pid = child.id();

        let stderr = Arc::new(Mutex::new(String::new()));
        if let Some(mut out) = child.stderr.take() {
            let kept = stderr.clone();
            tokio::spawn(async move {
                let mut chunk = [0u8; 1024];
                while let Ok(n) = out.read(&mut chunk).await {
                    if n == 0 {
                        break;
                    }
                    let mut text = kept.lock().unwrap();
                    if text.len() < MAX_STDERR_BYTES {
                        text.push_str(&String::from_utf8_lossy(&chunk[..n]));
                    }
                }
            });
        }
        if let Some(mut stdin) = child.stdin.take() {
            let text = input.to_string();
            tokio::spawn(async move {
                let _ = stdin.write_all(text.as_bytes()).await;
                // Closing it says the input is all there is.
                drop(stdin);
            });
        }
        let exited = Arc::new(AtomicBool::new(false));
        let (done, children, run_id) = (exited.clone(), self.children.clone(), id.clone());
        tokio::spawn(async move {
            let _ = child.wait().await;
            done.store(true, Ordering::SeqCst);
            children.lock().unwrap().remove(&run_id);
        });

        // The run makes its record folder as it begins; a run that is refused exits without making it,
        // and says why on standard error.
        let deadline = Instant::now() + FIND_TIMEOUT;
        loop {
            if record.is_dir() {
                if let Some(pid) = pid {
                    if !exited.load(Ordering::SeqCst) {
                        self.children.lock().unwrap().insert(id.clone(), pid);
                    }
                }
                return Ok(id);
            }
            if exited.load(Ordering::SeqCst) || Instant::now() > deadline {
                if let Some(pid) = pid {
                    kill_tree(pid);
                }
                // What the program printed may still be on its way out.
                tokio::time::sleep(POLL).await;
                let why = stderr.lock().unwrap().trim().to_string();
                return Err(RunNotStarted(if why.is_empty() {
                    "the run left no record".into()
                } else {
                    why
                }));
            }
            tokio::time::sleep(POLL).await;
        }
    }

    /// Stops a run this app started, and what it started.
    pub fn stop(&self, execution_id: &str) -> Result<(), NotStartedHere> {
        let pid = self
            .children
            .lock()
            .unwrap()
            .get(execution_id)
            .copied()
            .ok_or(NotStartedHere)?;
        kill_tree(pid);
        Ok(())
    }
}

// ---------------------------------------------------------------------------------------------
// Asking a run about itself
// ---------------------------------------------------------------------------------------------

const ASK_TIMEOUT: Duration = Duration::from_secs(3);
const MAX_ANSWER_BYTES: usize = 2 * 1024 * 1024;

/// The longest path a run's socket is given, with room to spare under the limit of a Unix socket's
/// path (`sun_path`: 104 bytes on macOS, 108 on Linux).
pub const MAX_SOCKET_PATH: usize = 100;

/// The 64-bit FNV-1a hash of `bytes`, as 16 lowercase hex digits.
pub fn fnv1a_64_hex(bytes: &[u8]) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in bytes {
        hash = (hash ^ u64::from(*byte)).wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{hash:016x}")
}

/// The folder that holds the sockets whose paths would be too long: `/tmp/synapse-pipeline-<uid>`.
pub fn short_socket_folder(uid: u32) -> PathBuf {
    PathBuf::from(format!("/tmp/synapse-pipeline-{uid}"))
}

fn path_bytes(path: &Path) -> Vec<u8> {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        path.as_os_str().as_bytes().to_vec()
    }
    #[cfg(not(unix))]
    {
        path.to_string_lossy().as_bytes().to_vec()
    }
}

/// Where the run whose record folder is `record_folder` listens: `execution.sock` in that folder when
/// the path fits, else in `short_socket_folder(uid)`, named by the hash of the folder. The same rule
/// as `synapse-pipeline`'s `Synapse.Pipeline.Socket_Paths` and the Node host's `run-socket.ts`; the
/// three must give the same path, byte for byte.
pub fn socket_endpoint(record_folder: &Path, uid: u32) -> PathBuf {
    let in_record = record_folder.join("execution.sock");
    if path_bytes(&in_record).len() <= MAX_SOCKET_PATH {
        in_record
    } else {
        short_socket_folder(uid).join(format!("{}.sock", fnv1a_64_hex(&path_bytes(record_folder))))
    }
}

fn current_uid() -> u32 {
    #[cfg(unix)]
    {
        // SAFETY: getuid takes nothing and cannot fail.
        unsafe { libc::getuid() }
    }
    #[cfg(not(unix))]
    {
        0
    }
}

/// Where the run listens: by `socket_endpoint`, or a named pipe on Windows. The record folder is
/// resolved with realpath(3), which `canonicalize` calls, so that the hash is of the path as it is
/// on disk, with links resolved and each name in its own case, as `synapse-pipeline` hashes it.
pub fn socket_path(records_dir: &Path, execution_id: &str, windows: bool) -> PathBuf {
    if windows {
        return PathBuf::from(format!("\\\\.\\pipe\\synapse-pipeline-{execution_id}"));
    }
    let folder = records_dir.join(execution_id);
    let real = std::fs::canonicalize(&folder).unwrap_or(folder);
    socket_endpoint(&real, current_uid())
}

/// Whether `folder` is one only this user can use: a directory, not a symbolic link, owned by this
/// user, with no permissions for anyone else. A socket in the short folder is connected to only then:
/// the folder is in `/tmp`, where another user could have made it to answer in a run's place.
#[cfg(unix)]
pub fn is_private_folder(folder: &Path, uid: u32) -> bool {
    use std::os::unix::fs::MetadataExt;
    match std::fs::symlink_metadata(folder) {
        Ok(meta) => meta.is_dir() && meta.uid() == uid && meta.mode() & 0o077 == 0,
        Err(_) => false,
    }
}

/// Nothing answers: the run is over, or it died.
#[derive(Debug, PartialEq)]
pub struct NotListening(pub String);

/// The ways asking can fail.
#[derive(Debug, PartialEq)]
pub enum AskError {
    NotListening(NotListening),
    /// It answered, with what is not an answer.
    Unreadable(String),
}

async fn exchange<S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin>(
    mut stream: S,
    line: &str,
) -> Result<Vec<u8>, AskError> {
    stream
        .write_all(line.as_bytes())
        .await
        .map_err(|e| AskError::NotListening(NotListening(e.to_string())))?;
    let mut kept = Vec::new();
    let mut chunk = [0u8; 16 * 1024];
    loop {
        let n = stream
            .read(&mut chunk)
            .await
            .map_err(|e| AskError::NotListening(NotListening(e.to_string())))?;
        if n == 0 {
            return Ok(kept);
        }
        kept.extend_from_slice(&chunk[..n]);
        if kept.len() > MAX_ANSWER_BYTES {
            return Err(AskError::Unreadable("the answer is too large".into()));
        }
    }
}

/// One request, one answer: the request is a JSON line, the answer is JSON ended by the end of the
/// connection.
pub async fn ask_run(path: &Path, request: &RunRequest) -> Result<RunAnswer, AskError> {
    let line = format!("{}\n", serde_json::to_string(request).unwrap_or_default());
    let not_listening = |why: String| AskError::NotListening(NotListening(why));
    #[cfg(unix)]
    {
        let uid = current_uid();
        let short = short_socket_folder(uid);
        if path.parent() == Some(short.as_path()) && !is_private_folder(&short, uid) {
            return Err(not_listening(format!(
                "{} is not a folder only this user can use",
                short.display()
            )));
        }
    }
    let work = async {
        #[cfg(unix)]
        let stream = tokio::net::UnixStream::connect(path)
            .await
            .map_err(|e| not_listening(e.to_string()))?;
        #[cfg(windows)]
        let stream = tokio::net::windows::named_pipe::ClientOptions::new()
            .open(path)
            .map_err(|e| not_listening(e.to_string()))?;
        exchange(stream, &line).await
    };
    let bytes = tokio::time::timeout(ASK_TIMEOUT, work)
        .await
        .map_err(|_| not_listening("the run did not answer in time".into()))??;
    serde_json::from_slice::<RunAnswer>(&bytes)
        .map_err(|_| AskError::Unreadable("the run sent an answer that is not JSON".into()))
}
