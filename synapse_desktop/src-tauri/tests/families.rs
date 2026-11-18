//! The first families of requests, asked through a connection as the page asks them: files, settings,
//! the programs of Synapse, the projects and conventions, and what the host says of the machine. The
//! same cases as the Node host's `calls.test.ts` and `config-store.test.ts`.

mod support;

use serde_json::{json, Value};
use std::fs;
use std::path::Path;
use support::{environment, Host};
use synapse_desktop_host::protocol::ErrorCode;
use tempfile::{tempdir, TempDir};

struct World {
    dir: TempDir,
}

impl World {
    fn new() -> World {
        World {
            dir: tempdir().unwrap(),
        }
    }

    fn path(&self, rest: &str) -> String {
        // Component by component: the host builds its paths that way, and on Windows a path with
        // both separators is another string.
        let mut path = self.dir.path().to_path_buf();
        for part in rest.split('/') {
            path.push(part);
        }
        path.to_string_lossy().to_string()
    }

    /// A host in this world: the home is the folder, the configuration directory is under it.
    async fn host(&self, vars: &[(&str, &str)]) -> Host {
        let mut all: Vec<(&str, String)> = vec![("XDG_CONFIG_HOME", self.path("xdg"))];
        all.extend(vars.iter().map(|(k, v)| (*k, v.to_string())));
        let refs: Vec<(&str, &str)> = all.iter().map(|(k, v)| (*k, v.as_str())).collect();
        Host::new(
            environment(self.dir.path(), &refs),
            &self.dir.path().join("config.json"),
        )
        .await
    }
}

fn code(error: (ErrorCode, String)) -> ErrorCode {
    error.0
}

#[tokio::test]
async fn config_get_answers_the_default_configuration_and_the_paths() {
    let world = World::new();
    let mut host = world.host(&[]).await;
    let answer = host.ask("config.get", json!({})).await.unwrap();
    assert_eq!(
        answer["config"],
        json!({
            // Nothing names a work directory, so it is the default in the home.
            "workDir": world.path(".cache/synapse/work"),
            "definitionPaths": [],
            "defaultHarness": null,
            "defaultModels": {},
            "env": {},
            "recentVaults": [],
            "terminalFolder": null,
            "graphRepos": {},
        })
    );
}

#[tokio::test]
async fn config_set_keeps_what_it_stores_and_what_another_setting_changes_leaves_alone() {
    let world = World::new();
    let mut host = world.host(&[]).await;
    host.ask(
        "config.set",
        json!({ "patch": { "env": { "SYNAPSE_X": "1" } } }),
    )
    .await
    .unwrap();
    host.ask(
        "config.set",
        json!({ "patch": { "workDir": "/w", "defaultHarness": "Codex" } }),
    )
    .await
    .unwrap();
    let config = host.ask("config.get", json!({})).await.unwrap()["config"].clone();
    assert_eq!(
        config,
        json!({
            "workDir": "/w",
            "definitionPaths": [],
            "defaultHarness": "Codex",
            "defaultModels": {},
            "env": { "SYNAPSE_X": "1" },
            "recentVaults": [],
            "terminalFolder": null,
            "graphRepos": {},
        })
    );
    // A setting set to null is set, and one left out is left.
    host.ask("config.set", json!({ "patch": { "defaultHarness": null } }))
        .await
        .unwrap();
    let config = host.ask("config.get", json!({})).await.unwrap()["config"].clone();
    assert_eq!(config["defaultHarness"], Value::Null);
    assert_eq!(config["workDir"], "/w");
}

#[tokio::test]
async fn the_file_is_written_whole_and_a_file_written_before_a_setting_existed_is_read() {
    let world = World::new();
    fs::write(
        world.path("config.json"),
        json!({ "workDir": "/w", "definitionPaths": [], "defaultHarness": "Codex" }).to_string(),
    )
    .unwrap();
    let mut host = world.host(&[]).await;
    let config = host.ask("config.get", json!({})).await.unwrap()["config"].clone();
    assert_eq!(config["workDir"], "/w");
    assert_eq!(config["env"], json!({}));
    assert_eq!(config["recentVaults"], json!([]));
    assert_eq!(config["terminalFolder"], Value::Null);

    host.ask("config.set", json!({ "patch": { "recentVaults": ["/v"] } }))
        .await
        .unwrap();
    let text = fs::read_to_string(world.path("config.json")).unwrap();
    assert!(text.ends_with("}\n"));
    assert!(text.starts_with("{\n  \"workDir\": \"/w\""), "{text}");
    assert!(!Path::new(&world.path("config.json.tmp")).exists());
}

#[tokio::test]
async fn a_variable_with_a_name_no_shell_takes_too_many_variables_and_nine_vaults_are_refused() {
    let world = World::new();
    let mut host = world.host(&[]).await;
    for name in ["BAD NAME", "1X", "A=B", ""] {
        let error = host
            .ask("config.set", json!({ "patch": { "env": { name: "1" } } }))
            .await;
        assert_eq!(code(error.unwrap_err()), ErrorCode::BadRequest, "{name:?}");
    }
    let many: serde_json::Map<String, Value> =
        (0..65).map(|i| (format!("V{i}"), json!("x"))).collect();
    let error = host
        .ask("config.set", json!({ "patch": { "env": many } }))
        .await;
    assert_eq!(code(error.unwrap_err()), ErrorCode::BadRequest);
    let nine: Vec<String> = (0..9).map(|i| format!("/v{i}")).collect();
    let error = host
        .ask("config.set", json!({ "patch": { "recentVaults": nine } }))
        .await;
    assert_eq!(code(error.unwrap_err()), ErrorCode::BadRequest);
    // A model a command line could take for a flag.
    let error = host
        .ask(
            "config.set",
            json!({ "patch": { "defaultModels": { "Claude": "-m x" } } }),
        )
        .await;
    assert_eq!(code(error.unwrap_err()), ErrorCode::BadRequest);
    host.ask(
        "config.set",
        json!({ "patch": { "defaultModels": { "Claude": "sonnet[1m]" } } }),
    )
    .await
    .unwrap();
}

#[tokio::test]
async fn the_work_directory_is_the_variable_of_the_app_else_of_the_host_else_the_saved_one_else_the_default(
) {
    let world = World::new();
    let work_dir = |config: Value| config["config"]["workDir"].clone();

    let mut plain = world.host(&[]).await;
    assert_eq!(
        work_dir(plain.ask("config.get", json!({})).await.unwrap()),
        json!(world.path(".cache/synapse/work"))
    );

    let mut started = world.host(&[("SYNAPSE_WORK_DIR", "/started")]).await;
    assert_eq!(
        work_dir(started.ask("config.get", json!({})).await.unwrap()),
        json!("/started")
    );

    started
        .ask("config.set", json!({ "patch": { "workDir": "/saved" } }))
        .await
        .unwrap();
    // A saved one does not replace what the host was started with, and another setting leaves it.
    started
        .ask(
            "config.set",
            json!({ "patch": { "defaultHarness": "Codex" } }),
        )
        .await
        .unwrap();
    assert_eq!(
        work_dir(started.ask("config.get", json!({})).await.unwrap()),
        json!("/started")
    );
    let stored: Value =
        serde_json::from_str(&fs::read_to_string(world.path("config.json")).unwrap()).unwrap();
    assert_eq!(stored["workDir"], "/saved");

    let mut saved = world.host(&[]).await;
    assert_eq!(
        work_dir(saved.ask("config.get", json!({})).await.unwrap()),
        json!("/saved")
    );

    saved
        .ask(
            "config.set",
            json!({ "patch": { "env": { "SYNAPSE_WORK_DIR": "/app" } } }),
        )
        .await
        .unwrap();
    let mut both = world.host(&[("SYNAPSE_WORK_DIR", "/started")]).await;
    assert_eq!(
        work_dir(both.ask("config.get", json!({})).await.unwrap()),
        json!("/app")
    );

    // An empty variable is no variable.
    let mut empty = World::new().host(&[("SYNAPSE_WORK_DIR", "")]).await;
    assert!(work_dir(empty.ask("config.get", json!({})).await.unwrap())
        .as_str()
        .unwrap()
        .ends_with(&world_path_tail()));
}

#[tokio::test]
async fn a_tilde_in_a_setting_that_holds_a_folder_is_expanded_and_the_folder_is_what_is_kept() {
    let world = World::new();
    let mut host = world.host(&[]).await;
    host.ask(
        "config.set",
        json!({ "patch": {
            "workDir": "~/work",
            "definitionPaths": ["~/defs"],
            "terminalFolder": "~",
            "graphRepos": { "a@main": "~/code" },
        } }),
    )
    .await
    .unwrap();
    let config = host.ask("config.get", json!({})).await.unwrap()["config"].clone();
    assert_eq!(config["workDir"], json!(world.path("work")));
    assert_eq!(config["definitionPaths"], json!([world.path("defs")]));
    assert_eq!(
        config["terminalFolder"],
        json!(world.dir.path().to_string_lossy())
    );
    assert_eq!(
        config["graphRepos"],
        json!({ "a@main": world.path("code") })
    );
}

#[tokio::test]
async fn only_the_directories_that_exist_are_listed_as_paths() {
    let world = World::new();
    let definitions = world.path("xdg/synapse-pipeline");
    let skills = world.path("xdg/synapse-pipeline/skills");
    fs::create_dir_all(&skills).unwrap();
    let mut host = world.host(&[]).await;
    host.ask(
        "config.set",
        json!({ "patch": { "workDir": world.path("work"), "definitionPaths": [world.path("missing")] } }),
    )
    .await
    .unwrap();
    let paths = host.ask("config.get", json!({})).await.unwrap()["paths"].clone();
    assert_eq!(
        paths,
        json!({
            "definitionDirs": [definitions],
            "skillsDir": skills,
            "recordsDir": null,
        })
    );
    fs::create_dir_all(world.path("work/pipelines")).unwrap();
    let paths = host.ask("config.get", json!({})).await.unwrap()["paths"].clone();
    assert_eq!(paths["recordsDir"], json!(world.path("work/pipelines")));
}

#[tokio::test]
async fn a_definition_file_is_read_and_any_other_file_and_a_folder_listing_outside_the_roots_are_refused(
) {
    let world = World::new();
    let definitions = world.path("xdg/synapse-pipeline");
    fs::create_dir_all(&definitions).unwrap();
    fs::write(format!("{definitions}/P.synapse"), "Pipeline P {}").unwrap();
    fs::write(world.path("private.txt"), "secret").unwrap();
    let mut host = world.host(&[]).await;

    let read = host
        .ask(
            "fs.read",
            json!({ "path": format!("{definitions}/P.synapse") }),
        )
        .await;
    assert_eq!(read.unwrap(), json!({ "text": "Pipeline P {}" }));
    let outside = host
        .ask("fs.read", json!({ "path": world.path("private.txt") }))
        .await;
    assert_eq!(code(outside.unwrap_err()), ErrorCode::Forbidden);
    let listing = host
        .ask(
            "fs.list",
            json!({ "path": world.dir.path().to_string_lossy() }),
        )
        .await;
    assert_eq!(code(listing.unwrap_err()), ErrorCode::Forbidden);
    let bad = host.ask("fs.read", json!({ "path": 5 })).await;
    assert_eq!(code(bad.unwrap_err()), ErrorCode::BadRequest);
}

#[tokio::test]
async fn a_folder_is_listed_with_what_each_entry_is_sorted_by_name() {
    let world = World::new();
    let definitions = world.path("xdg/synapse-pipeline");
    fs::create_dir_all(format!("{definitions}/skills")).unwrap();
    fs::write(format!("{definitions}/b.synapse"), "x").unwrap();
    fs::write(format!("{definitions}/A.synapse"), "x").unwrap();
    let mut host = world.host(&[]).await;
    let list = host
        .ask("fs.list", json!({ "path": definitions }))
        .await
        .unwrap();
    let entries = list["entries"].as_array().unwrap();
    let names: Vec<&str> = entries
        .iter()
        .map(|e| e["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, vec!["A.synapse", "b.synapse", "skills"]);
    assert_eq!(entries[2]["isDir"], json!(true));
    assert_eq!(entries[0]["isDir"], json!(false));
    assert!(entries[0]["mtimeMs"].as_f64().unwrap() > 1.0e12);
}

#[tokio::test]
async fn a_file_that_is_too_large_is_refused() {
    let world = World::new();
    let definitions = world.path("xdg/synapse-pipeline");
    fs::create_dir_all(&definitions).unwrap();
    fs::write(
        format!("{definitions}/big.synapse"),
        vec![b'x'; 4 * 1024 * 1024 + 1],
    )
    .unwrap();
    let mut host = world.host(&[]).await;
    let error = host
        .ask(
            "fs.read",
            json!({ "path": format!("{definitions}/big.synapse") }),
        )
        .await;
    assert_eq!(code(error.unwrap_err()), ErrorCode::TooLarge);
}

#[tokio::test]
async fn an_allowed_subcommand_runs_and_the_others_are_refused_without_running() {
    let world = World::new();
    let mut host = world.host(&[]).await;
    let ok = host
        .ask(
            "cli",
            json!({ "binary": "synapse-pipeline", "args": ["show", "P", "--format", "json"] }),
        )
        .await
        .unwrap();
    assert_eq!(ok, json!({ "code": 0, "stdout": "ok", "stderr": "" }));
    assert_eq!(host.calls.lock().unwrap().len(), 1);
    assert_eq!(
        host.calls.lock().unwrap()[0].args,
        vec!["show", "P", "--format", "json"]
    );

    let refused = host
        .ask(
            "cli",
            json!({ "binary": "synapse-pipeline", "args": ["run", "P"] }),
        )
        .await;
    assert_eq!(code(refused.unwrap_err()), ErrorCode::BadRequest);
    assert_eq!(host.calls.lock().unwrap().len(), 1);

    // What is typed to the program goes to it.
    host.ask(
        "cli",
        json!({ "binary": "synapse", "args": ["vault-search", "--fields", "a"], "stdin": "{}" }),
    )
    .await
    .unwrap();
    assert_eq!(host.calls.lock().unwrap()[1].stdin.as_deref(), Some("{}"));
}

#[tokio::test]
async fn the_projects_are_listed_added_and_refused_when_taken_as_synapse_says() {
    let world = World::new();
    let mut host = world.host(&[]).await;
    // The file is where the program says it is.
    let file = world.path("xdg/synapse/synapse-projects.conf");
    let listed = host
        .ask("registry.list", json!({ "kind": "projects" }))
        .await
        .unwrap();
    assert_eq!(
        listed,
        json!({ "kind": "projects", "list": { "projects": [], "file": file } })
    );

    let added = host
        .ask(
            "registry.add",
            json!({ "kind": "projects", "name": "thing", "prefix": "tg" }),
        )
        .await
        .unwrap();
    assert_eq!(
        added,
        json!({ "kind": "projects", "list": { "projects": [{ "name": "thing", "prefix": "tg" }], "file": file } })
    );
    let taken = host
        .ask(
            "registry.add",
            json!({ "kind": "projects", "name": "thing", "prefix": "other" }),
        )
        .await;
    let (taken_code, taken_message) = taken.unwrap_err();
    assert_eq!(taken_code, ErrorCode::Conflict);
    // What the program said, without its own name in front.
    assert_eq!(
        taken_message,
        "thing is already a project, with the prefix tg."
    );
    let bad = host
        .ask(
            "registry.add",
            json!({ "kind": "projects", "name": "No Good", "prefix": "tg2" }),
        )
        .await;
    assert_eq!(code(bad.unwrap_err()), ErrorCode::Conflict);
    // The host holds no list of its own: the program was asked each time.
    let asked: Vec<Vec<String>> = host
        .calls
        .lock()
        .unwrap()
        .iter()
        .filter(|c| c.args.first().map(String::as_str) == Some("projects"))
        .map(|c| c.args.clone())
        .collect();
    assert_eq!(asked[0], vec!["projects", "--format", "json"]);
    assert!(asked
        .iter()
        .any(|a| a == &vec!["projects", "add", "thing", "tg"]));
}

#[tokio::test]
async fn the_projects_card_of_the_conventions_is_what_synapse_holds_and_is_added_to_through_it() {
    let world = World::new();
    let mut host = world.host(&[]).await;
    host.pairs
        .lock()
        .unwrap()
        .push(("synapse".into(), "sb".into()));
    let listed = host
        .ask("registry.list", json!({ "kind": "conventions" }))
        .await
        .unwrap();
    let card = |answer: &Value| {
        answer["list"]["conventions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["id"] == "projects")
            .unwrap()
            .clone()
    };
    assert_eq!(card(&listed)["entries"], json!([{ "text": "synapse=sb" }]));

    let added = host
        .ask(
            "registry.add",
            json!({ "kind": "conventions", "id": "projects", "entry": "thing = tg" }),
        )
        .await
        .unwrap();
    assert_eq!(
        card(&added)["entries"],
        json!([{ "text": "synapse=sb" }, { "text": "thing=tg" }])
    );
    let refused = host
        .ask(
            "registry.add",
            json!({ "kind": "conventions", "id": "projects", "entry": "other=sb" }),
        )
        .await
        .unwrap_err();
    assert_eq!(
        refused,
        (
            ErrorCode::Conflict,
            "The prefix sb is already the prefix of synapse.".into()
        )
    );
    let no_pair = host
        .ask(
            "registry.add",
            json!({ "kind": "conventions", "id": "projects", "entry": "nopair" }),
        )
        .await
        .unwrap_err();
    assert_eq!(no_pair.0, ErrorCode::Conflict);
    assert!(no_pair.1.contains("name=prefix"));
}

#[tokio::test]
async fn the_conventions_are_listed_added_and_taken_out_and_only_the_conventions() {
    let world = World::new();
    let mut host = world.host(&[]).await;
    let listed = host
        .ask("registry.list", json!({ "kind": "conventions" }))
        .await
        .unwrap();
    assert_eq!(listed["kind"], "conventions");
    let all = listed["list"]["conventions"].as_array().unwrap();
    assert!(all
        .iter()
        .any(|c| c["id"] == "tags" && c["exists"] == json!(false)));

    let added = host
        .ask(
            "registry.add",
            json!({ "kind": "conventions", "id": "tags", "entry": "architecture" }),
        )
        .await
        .unwrap();
    let tags = added["list"]["conventions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == "tags")
        .unwrap()
        .clone();
    assert_eq!(tags["entries"], json!([{ "text": "architecture" }]));

    let removed = host
        .ask(
            "registry.remove",
            json!({ "kind": "conventions", "id": "tags", "entry": "architecture" }),
        )
        .await
        .unwrap();
    assert_eq!(removed["kind"], "conventions");
    let again = host
        .ask(
            "registry.remove",
            json!({ "kind": "conventions", "id": "tags", "entry": "architecture" }),
        )
        .await;
    assert_eq!(code(again.unwrap_err()), ErrorCode::NotFound);
    // Projects are not taken out here.
    let projects = host
        .ask(
            "registry.remove",
            json!({ "kind": "projects", "id": "x", "entry": "y" }),
        )
        .await;
    assert_eq!(code(projects.unwrap_err()), ErrorCode::BadRequest);
}

#[tokio::test]
async fn what_each_harness_has_installed_is_said_for_the_three() {
    let world = World::new();
    let mut host = world.host(&[("PATH", "")]).await;
    let answer = host.ask("integrations", json!({})).await.unwrap();
    let harnesses: Vec<&str> = answer["harnesses"]
        .as_array()
        .unwrap()
        .iter()
        .map(|h| h["harness"].as_str().unwrap())
        .collect();
    assert_eq!(harnesses, vec!["Claude", "Codex", "Opencode"]);
    assert_eq!(answer["bundled"]["hook"], Value::Null);
}

#[tokio::test]
async fn the_diagnosis_is_what_the_doctor_printed() {
    let world = World::new();
    let mut host = world.host(&[]).await;
    *host.result.lock().unwrap() = synapse_desktop_host::messages::CliResult {
        code: 0,
        stdout: json!({
            "format": "synapse-doctor/v1",
            "checks": [{ "key": "git", "name": "git", "status": "ok", "detail": "found", "value": "/usr/bin/git" }],
            "counts": { "ok": 1, "warn": 0, "fail": 0 },
        })
        .to_string(),
        stderr: String::new(),
    };
    let answer = host.ask("diagnose", json!({})).await.unwrap();
    assert_eq!(answer["counts"], json!({ "ok": 1, "warn": 0, "fail": 0 }));
    assert_eq!(answer["findings"][0]["key"], "git");

    // A doctor that printed nothing is a failure of what the host depends on.
    *host.result.lock().unwrap() = synapse_desktop_host::messages::CliResult {
        code: 2,
        stdout: String::new(),
        stderr: "usage".into(),
    };
    let error = host.ask("diagnose", json!({})).await.unwrap_err();
    assert_eq!(error, (ErrorCode::Unavailable, "usage".to_string()));
}

#[tokio::test]
async fn the_models_of_a_harness_are_listed_and_read_again_only_when_asked_to() {
    let world = World::new();
    let mut host = world.host(&[]).await;
    let list = |ids: &[&str]| synapse_desktop_host::messages::ModelCatalog {
        models: ids
            .iter()
            .map(|id| synapse_desktop_host::messages::ModelOption {
                id: id.to_string(),
                provider: None,
                available: true,
                detail: None,
            })
            .collect(),
        note: None,
        read_at: None,
    };
    host.models.lock().unwrap().insert(
        synapse_desktop_host::messages::Harness::Claude,
        list(&["sonnet"]),
    );
    let first = host
        .ask("models.get", json!({ "harness": "Claude" }))
        .await
        .unwrap();
    assert_eq!(first["models"][0]["id"], "sonnet");
    assert!(first["readAt"].is_string());

    // The harness has another list now, which is not read until it is asked to.
    host.models.lock().unwrap().insert(
        synapse_desktop_host::messages::Harness::Claude,
        list(&["opus"]),
    );
    let kept = host
        .ask("models.get", json!({ "harness": "Claude" }))
        .await
        .unwrap();
    assert_eq!(kept["models"][0]["id"], "sonnet");
    let again = host
        .ask(
            "models.get",
            json!({ "harness": "Claude", "refresh": true }),
        )
        .await
        .unwrap();
    assert_eq!(again["models"][0]["id"], "opus");

    let bad = host.ask("models.get", json!({ "harness": "Gemini" })).await;
    assert_eq!(code(bad.unwrap_err()), ErrorCode::BadRequest);
}

#[tokio::test]
async fn the_sessions_and_folders_the_harnesses_remember_are_listed_for_the_three() {
    let world = World::new();
    let here = world.path("here");
    fs::create_dir_all(&here).unwrap();
    fs::write(
        world.path(".claude.json"),
        json!({ "projects": { here.clone(): { "hasTrustDialogAccepted": true, "lastSessionModified": 5000 } } }).to_string(),
    )
    .unwrap();
    let sessions = world.path(".claude/projects/-here");
    fs::create_dir_all(&sessions).unwrap();
    fs::write(
        format!("{sessions}/abc.jsonl"),
        format!(
            "{}\n{}\n",
            json!({ "type": "user", "cwd": here }),
            json!({ "type": "ai-title", "aiTitle": "Work on it" })
        ),
    )
    .unwrap();
    let mut host = world.host(&[]).await;

    let folders = host
        .ask("history.get", json!({ "what": "workspaces" }))
        .await
        .unwrap();
    assert_eq!(folders["what"], "workspaces");
    assert_eq!(
        folders["workspaces"]["Claude"],
        json!([{ "path": here, "lastUsed": "1970-01-01T00:00:05.000Z" }])
    );
    assert_eq!(folders["workspaces"]["Codex"], json!([]));
    assert_eq!(folders["workspaces"]["Opencode"], json!([]));

    let past = host
        .ask("history.get", json!({ "what": "sessions" }))
        .await
        .unwrap();
    assert_eq!(past["sessions"]["Claude"][0]["id"], "abc");
    assert_eq!(past["sessions"]["Claude"][0]["title"], "Work on it");
    assert_eq!(past["sessions"]["Claude"][0]["path"], json!(here));
}

/// The end of the default work directory, as the host spells it on this platform.
fn world_path_tail() -> String {
    [".cache", "synapse", "work"].join(std::path::MAIN_SEPARATOR_STR)
}
