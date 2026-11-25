#![allow(dead_code)]
//! What the tests share: the example files of the messages, which the Node host's tests read too.

use serde_json::Value;
use std::fs;
use std::path::PathBuf;

pub struct Example {
    pub name: String,
    pub params: Value,
    pub result: Value,
}

fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../shared/examples")
}

pub fn examples() -> Vec<Example> {
    let mut found = Vec::new();
    for entry in fs::read_dir(dir()).expect("the example files are there") {
        let path = entry.unwrap().path();
        let file = path.file_name().unwrap().to_string_lossy().to_string();
        if file.starts_with('_') || !file.ends_with(".json") {
            continue;
        }
        let value: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        found.push(Example {
            name: value["name"].as_str().unwrap().to_string(),
            params: value["params"].clone(),
            result: value["result"].clone(),
        });
    }
    found.sort_by(|a, b| a.name.cmp(&b.name));
    found
}

pub fn envelope() -> Value {
    serde_json::from_str(&fs::read_to_string(dir().join("_envelope.json")).unwrap()).unwrap()
}

/// The example of an event on the `usage` topic, which the Node host's tests read too.
pub fn usage_event() -> Value {
    serde_json::from_str(&fs::read_to_string(dir().join("_usage-event.json")).unwrap()).unwrap()
}

/// Whether two values are the same JSON, as numbers are the same when they are the same value
/// whether they were written as integers or not.
pub fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(p, q)| same(p, q))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| same(v, w)))
        }
        _ => a == b,
    }
}

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::{Arc, Mutex};
use synapse_desktop_host::cli::{CliRun, CliRunner};
use synapse_desktop_host::dispatch::{serve, Handlers, ServeOptions};
use synapse_desktop_host::environment::Environment;
use synapse_desktop_host::families::{first_families, last_families, next_families, Context};
use synapse_desktop_host::link::{link_pair, ClientLink};
use synapse_desktop_host::messages::{CliResult, Harness, ModelCatalog};
use synapse_desktop_host::models::ModelStore;
use synapse_desktop_host::protocol::{
    Capabilities, ClientMessage, ErrorCode, HostKind, HostMessage,
};
use synapse_desktop_host::status::{LoginPath, VersionOf};

pub fn environment(home: &Path, vars: &[(&str, &str)]) -> Environment {
    Environment {
        env: vars
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect::<BTreeMap<_, _>>(),
        home: home.to_path_buf(),
    }
}

/// A host with the first families, over fake programs: what they are asked is kept, and what they say
/// is `result`.
pub struct Host {
    client: ClientLink,
    next: u32,
    pub calls: Arc<Mutex<Vec<CliRun>>>,
    pub result: Arc<Mutex<CliResult>>,
    /// The pairs `synapse projects` holds, which the fake program keeps.
    pub pairs: Arc<Mutex<Vec<(String, String)>>>,
    /// What each harness lists as its models, which the store reads.
    pub models: Arc<Mutex<BTreeMap<Harness, ModelCatalog>>>,
}

/// What `synapse projects` answers over the pairs it holds: the listing, and the refusals of an add
/// that matter to the host, which are the program's own rules.
fn projects_program(pairs: &mut Vec<(String, String)>, file: &str, args: &[String]) -> CliResult {
    let refuse = |why: String| CliResult {
        code: 1,
        stdout: String::new(),
        stderr: format!("synapse-projects: {why}\n"),
    };
    if args.get(1).map(String::as_str) == Some("add") {
        let (name, prefix) = (args[2].clone(), args[3].clone());
        if let Some((_, taken)) = pairs.iter().find(|(n, _)| *n == name) {
            return refuse(format!(
                "{name} is already a project, with the prefix {taken}."
            ));
        }
        if let Some((owner, _)) = pairs.iter().find(|(_, p)| *p == prefix) {
            return refuse(format!(
                "The prefix {prefix} is already the prefix of {owner}."
            ));
        }
        if !name
            .chars()
            .next()
            .is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
            || name.contains(' ')
        {
            return refuse("A project name is lower case letters.".into());
        }
        pairs.push((name, prefix));
        return CliResult {
            code: 0,
            stdout: format!("{file}\n"),
            stderr: String::new(),
        };
    }
    let projects: Vec<Value> = pairs
        .iter()
        .map(|(n, p)| serde_json::json!({ "name": n, "prefix": p }))
        .collect();
    CliResult {
        code: 0,
        stdout: serde_json::json!({ "format": "synapse-projects/v1", "file": file, "projects": projects })
            .to_string(),
        stderr: String::new(),
    }
}

impl Host {
    pub async fn new(environment: Environment, config_file: &Path) -> Host {
        let calls = Arc::new(Mutex::new(Vec::<CliRun>::new()));
        let result = Arc::new(Mutex::new(CliResult {
            code: 0,
            stdout: "ok".into(),
            stderr: String::new(),
        }));
        let pairs = Arc::new(Mutex::new(Vec::<(String, String)>::new()));
        let file = environment
            .config_base()
            .join("synapse")
            .join("synapse-projects.conf")
            .to_string_lossy()
            .to_string();
        let models = Arc::new(Mutex::new(BTreeMap::<Harness, ModelCatalog>::new()));
        let (kept, said, held, listed) =
            (calls.clone(), result.clone(), pairs.clone(), models.clone());
        let context = Context {
            config_file: config_file.to_path_buf(),
            cli: CliRunner::new(move |run| {
                kept.lock().unwrap().push(run.clone());
                let said = if run.args.first().map(String::as_str) == Some("projects") {
                    projects_program(&mut held.lock().unwrap(), &file, &run.args)
                } else {
                    said.lock().unwrap().clone()
                };
                async move { Ok(said) }
            }),
            login_path: LoginPath::new(|| async { None }),
            version_of: VersionOf::new(|_| async { None }),
            models: ModelStore::new(
                config_file.with_file_name("models.json"),
                Arc::new(|| 0),
                move |harness| {
                    let answer = listed.lock().unwrap().get(&harness).cloned();
                    async move {
                        answer.unwrap_or(ModelCatalog {
                            models: vec![],
                            note: None,
                            read_at: None,
                        })
                    }
                },
            ),
            agent: synapse_desktop_host::agents::AgentRunner::new(|_| async {
                Err("not used".to_string())
            }),
            note_session: synapse_desktop_host::agents::NoteSession::new(|_| async {
                Err("not used".to_string())
            }),
            runs: synapse_desktop_host::runs::RunStarter::new(
                "synapse-pipeline",
                Default::default(),
            ),
            note_runs: synapse_desktop_host::note_runs::NoteRuns::new(),
            bundled_roots: vec![],
            usage: synapse_desktop_host::usage::Usage::none(),
            environment,
        };
        let mut handlers = Handlers::new();
        let context = Arc::new(context);
        first_families(&mut handlers, context.clone());
        next_families(&mut handlers, context.clone());
        last_families(&mut handlers, context.clone());
        last_families(&mut handlers, context);
        let (mut client, host) = link_pair();
        serve(
            host,
            ServeOptions::new(
                handlers,
                Capabilities {
                    host: HostKind::Fake,
                    shell: true,
                    install_actions: true,
                },
            ),
        );
        client.incoming.recv().await.expect("hello");
        Host {
            client,
            next: 0,
            calls,
            result,
            pairs,
            models,
        }
    }

    /// Asks one request; the result, or the code and message it was refused with.
    pub async fn ask(&mut self, name: &str, params: Value) -> Result<Value, (ErrorCode, String)> {
        self.next += 1;
        let id = format!("r{}", self.next);
        self.client
            .outgoing
            .send(ClientMessage::Request {
                id,
                name: name.into(),
                params,
            })
            .unwrap();
        match self.client.incoming.recv().await.expect("a reply") {
            HostMessage::Reply {
                result: Some(result),
                ..
            } => Ok(result),
            HostMessage::Reply {
                error: Some(error), ..
            } => Err((error.code, error.message)),
            other => panic!("not a reply: {other:?}"),
        }
    }
}

/// Makes a script a test runs. It is written by another process, not this one: on Linux a file that
/// is open for writing cannot be run, and a file this process writes is held open for a moment by
/// the child of any test on another thread that is starting a program just then. The script is then
/// refused as busy, now and again. A file this process never opened has no such copy.
#[cfg(unix)]
pub fn executable(path: &std::path::Path, text: &str) {
    use std::io::Write;
    use std::process::{Command, Stdio};
    if let Some(folder) = path.parent() {
        fs::create_dir_all(folder).unwrap();
    }
    let mut writer = Command::new("/bin/sh")
        .args(["-c", r#"cat > "$1" && chmod 755 "$1""#, "sh"])
        .arg(path)
        .stdin(Stdio::piped())
        .spawn()
        .unwrap();
    writer
        .stdin
        .take()
        .unwrap()
        .write_all(text.as_bytes())
        .unwrap();
    assert!(writer.wait().unwrap().success(), "the script is written");
}
