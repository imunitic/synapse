//! The models of the harnesses: what each prints, how a list is read from a harness, and how the lists
//! are kept between runs. The same cases as the Node host's `models.test.ts` and `model-store.test.ts`.

mod support;

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::sync::atomic::{AtomicI64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use support::environment;
use synapse_desktop_host::config::is_model_name;
use synapse_desktop_host::messages::{Harness, ModelCatalog, ModelOption};
use synapse_desktop_host::models::{
    claude_catalog, codex_catalog, connected_providers, model_cache_file, opencode_catalog,
    parse_claude_models, parse_opencode_models, read_models, ModelStore, ProgramOutput,
    ProgramRunner,
};
use synapse_desktop_host::status::LoginPath;
use synapse_desktop_host::time::iso_millis;
use tempfile::tempdir;

const MODELS: &str = "opencode/glm-5.3-flash-free\nopenrouter/z-ai/glm-5.3-flash\nopenrouter/~z-ai/glm-flash-latest\nanthropic/claude-sonnet";
const AUTH: &str = "\u{1b}[1mOpenRouter\u{1b}[0m  API key  stored\n";

fn pair(id: &str, provider: &str) -> (String, String) {
    (id.to_string(), provider.to_string())
}

#[test]
fn the_models_opencode_lists_are_a_line_each_without_colours_blank_lines_or_repeats() {
    assert_eq!(
        parse_opencode_models(
            "\u{1b}[2mopencode/a\u{1b}[0m\n\nopenrouter/x/y\nopencode/a\nnot a model\nnoprovider\n/lead\ntrail/\n"
        ),
        vec![pair("opencode/a", "opencode"), pair("openrouter/x/y", "openrouter")]
    );
    assert_eq!(
        parse_opencode_models("openrouter/~z-ai/glm-flash-latest\n")[0].0,
        "openrouter/~z-ai/glm-flash-latest"
    );
}

#[test]
fn the_providers_opencode_is_connected_to_are_the_names_at_the_start_of_its_lines() {
    assert_eq!(
        connected_providers(AUTH),
        BTreeSet::from(["openrouter".to_string()])
    );
    assert_eq!(
        connected_providers("OpenCode Zen  OAuth  stored\nGitHub Copilot  OAuth  stored\n"),
        BTreeSet::from(["opencodezen".to_string(), "githubcopilot".to_string()])
    );
    assert!(connected_providers("").is_empty());
}

#[test]
fn the_catalog_of_opencode_has_what_can_be_used_first_and_says_what_needs_a_login() {
    let catalog = opencode_catalog(MODELS, AUTH);
    let listed: Vec<(&str, bool)> = catalog
        .models
        .iter()
        .map(|m| (m.id.as_str(), m.available))
        .collect();
    assert_eq!(
        listed,
        vec![
            ("opencode/glm-5.3-flash-free", true),
            ("openrouter/z-ai/glm-5.3-flash", true),
            ("openrouter/~z-ai/glm-flash-latest", true),
            ("anthropic/claude-sonnet", false),
        ]
    );
    assert_eq!(
        catalog.note.as_deref(),
        Some(
            "3 of the 4 models are of providers that are connected; the others need a login first."
        )
    );
    assert_eq!(opencode_catalog("opencode/a\n", "").note, None);
    let empty = opencode_catalog("", AUTH);
    assert!(empty.models.is_empty());
    assert_eq!(empty.note.as_deref(), Some("OpenCode listed no models."));
}

type Calls = Arc<Mutex<Vec<(String, Vec<String>, BTreeMap<String, String>)>>>;

/// A runner that answers `answer` for each call, and keeps what it was asked.
fn runner(
    answer: impl Fn(&str, &[String]) -> ProgramOutput + Send + Sync + 'static,
) -> (ProgramRunner, Calls) {
    let calls: Calls = Arc::new(Mutex::new(vec![]));
    let kept = calls.clone();
    let answer = Arc::new(answer);
    let runner = ProgramRunner::new(move |program, args, env| {
        kept.lock()
            .unwrap()
            .push((program.clone(), args.clone(), env));
        let out = answer(&program, &args);
        async move { out }
    });
    (runner, calls)
}

fn ok(stdout: &str) -> ProgramOutput {
    ProgramOutput {
        code: 0,
        stdout: stdout.into(),
    }
}

fn login(path: Option<&'static str>) -> LoginPath {
    LoginPath::new(move || async move { path.map(String::from) })
}

fn env(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

#[tokio::test]
async fn opencode_is_asked_for_its_models_and_its_providers_by_the_path_of_the_login_shell() {
    let (run, calls) = runner(|_, args| {
        if args[0] == "models" {
            ok(MODELS)
        } else {
            ok(AUTH)
        }
    });
    let catalog = read_models(
        Harness::Opencode,
        &run,
        &env(&[("PATH", "/own")]),
        &login(Some("/login")),
    )
    .await;
    assert_eq!(catalog.models.len(), 4);
    let calls = calls.lock().unwrap();
    let mut asked: Vec<String> = calls
        .iter()
        .map(|(p, a, _)| format!("{p} {}", a.join(" ")))
        .collect();
    asked.sort();
    assert_eq!(asked, vec!["opencode auth list", "opencode models"]);
    let separator = if cfg!(windows) { ";" } else { ":" };
    assert!(calls
        .iter()
        .all(|(_, _, e)| e["PATH"] == format!("/own{separator}/login")));
}

#[tokio::test]
async fn opencode_has_none_and_says_so_when_it_cannot_list_them_and_all_when_providers_cannot_be_had(
) {
    let (failing, _) = runner(|_, _| ProgramOutput {
        code: 127,
        stdout: String::new(),
    });
    let catalog = read_models(Harness::Opencode, &failing, &env(&[]), &login(None)).await;
    assert!(catalog.models.is_empty() && catalog.read_at.is_none());
    assert_eq!(
        catalog.note.as_deref(),
        Some("OpenCode could not list its models. Type a name instead.")
    );

    let (no_auth, _) = runner(|_, args| {
        if args[0] == "models" {
            ok(MODELS)
        } else {
            ProgramOutput {
                code: 1,
                stdout: String::new(),
            }
        }
    });
    let catalog = read_models(Harness::Opencode, &no_auth, &env(&[]), &login(None)).await;
    let usable: Vec<&str> = catalog
        .models
        .iter()
        .filter(|m| m.available)
        .filter_map(|m| m.provider.as_deref())
        .collect();
    assert_eq!(usable, vec!["opencode"]);
}

#[test]
fn the_name_of_a_model_holds_what_names_are_made_of_and_cannot_be_taken_for_a_flag() {
    for name in [
        "sonnet",
        "gpt-5.6-terra",
        "opencode/glm-5.3-flash-free",
        "openrouter/z-ai/glm-5.3-flash",
        "openrouter/~z-ai/glm-flash-latest",
        "anthropic/claude-3.5:beta",
        "sonnet[1m]",
    ] {
        assert!(is_model_name(name), "{name}");
    }
    let long = "x".repeat(201);
    for name in [
        "--dangerously-skip-permissions",
        "-m",
        " sonnet",
        "a b",
        "a;b",
        "[1m]",
        "a\"b",
        "$(x)",
        "",
        &long,
    ] {
        assert!(!is_model_name(name), "{name}");
    }
}

const CLAUDE_ANSWER: &str = "Current model: `Sonnet 5.5`\nUsage: /model <name>. Available: sonnet, opus, haiku, fable, best, sonnet[1m], opus[1m], fable[1m], opusplan, default, or a full model ID.\n";

fn codex_answer() -> String {
    serde_json::json!({ "models": [
        { "slug": "gpt-b", "display_name": "GPT B", "description": "Second.", "visibility": "list", "priority": 2 },
        { "slug": "gpt-a", "display_name": "GPT A", "description": "First.", "visibility": "list", "priority": 1 },
        { "slug": "gpt-old", "display_name": "GPT Old", "description": "Old.", "visibility": "hide", "priority": 3 },
        { "slug": "bad name", "display_name": "Bad", "visibility": "list", "priority": 4 },
        { "slug": "gpt-c", "visibility": "list", "priority": 5 },
    ] })
    .to_string()
}

#[test]
fn the_aliases_of_claude_code_are_the_names_its_model_command_says_it_takes() {
    let (current, names) = parse_claude_models(CLAUDE_ANSWER);
    assert_eq!(current.as_deref(), Some("Sonnet 5.5"));
    assert_eq!(
        names,
        [
            "sonnet",
            "opus",
            "haiku",
            "fable",
            "best",
            "sonnet[1m]",
            "opus[1m]",
            "fable[1m]",
            "opusplan",
            "default"
        ]
    );
    assert_eq!(
        parse_claude_models("Unknown command: /model"),
        (None, vec![])
    );
    assert_eq!(parse_claude_models(""), (None, vec![]));
    let catalog = claude_catalog(CLAUDE_ANSWER);
    assert!(catalog
        .models
        .iter()
        .all(|m| m.available && m.provider.is_none()));
    assert!(catalog.models.iter().any(|m| m.id == "sonnet[1m]"));
    assert_eq!(
        catalog.note.as_deref(),
        Some("It is on Sonnet 5.5 now. Any full model ID can be typed as well.")
    );
}

#[test]
fn the_models_codex_lists_are_those_it_shows_in_its_own_order_with_what_it_says_of_each() {
    let catalog = codex_catalog(&codex_answer());
    let ids: Vec<&str> = catalog.models.iter().map(|m| m.id.as_str()).collect();
    assert_eq!(ids, vec!["gpt-a", "gpt-b", "gpt-c"]);
    assert_eq!(catalog.models[0].detail.as_deref(), Some("GPT A: First."));
    assert_eq!(catalog.models[2].detail, None);
    assert_eq!(
        catalog.note.as_deref(),
        Some("Any model name can be typed as well.")
    );
    for text in ["not json", r#"{"other": 1}"#, r#"{"models": []}"#] {
        assert!(codex_catalog(text).models.is_empty(), "{text}");
    }
}

#[tokio::test]
async fn claude_is_asked_its_model_command_with_no_session_kept_and_codex_for_its_catalogue() {
    let codex = codex_answer();
    let (run, calls) = runner(move |program, _| {
        ok(if program == "claude" {
            CLAUDE_ANSWER
        } else {
            &codex
        })
    });
    let claude = read_models(Harness::Claude, &run, &env(&[]), &login(None)).await;
    let codex = read_models(Harness::Codex, &run, &env(&[]), &login(None)).await;
    let asked: Vec<String> = calls
        .lock()
        .unwrap()
        .iter()
        .map(|(p, a, _)| format!("{p} {}", a.join(" ")))
        .collect();
    assert_eq!(
        asked,
        vec![
            "claude -p /model --no-session-persistence",
            "codex debug models"
        ]
    );
    assert_eq!((claude.models.len(), codex.models.len()), (10, 3));
}

#[tokio::test]
async fn it_says_what_to_do_when_a_list_cannot_be_had() {
    let (failing, _) = runner(|_, _| ProgramOutput {
        code: 127,
        stdout: String::new(),
    });
    let claude = read_models(Harness::Claude, &failing, &env(&[]), &login(None)).await;
    assert!(claude.models.is_empty());
    assert_eq!(
        claude.note.as_deref(),
        Some("Claude Code could not list its models. Type a name instead.")
    );
    let codex = read_models(Harness::Codex, &failing, &env(&[]), &login(None)).await;
    assert!(codex
        .note
        .unwrap()
        .contains("Codex could not list its models."));
}

// ---------------------------------------------------------------------------------------------
// The models kept between runs
// ---------------------------------------------------------------------------------------------

fn catalog(ids: &[&str]) -> ModelCatalog {
    ModelCatalog {
        models: ids
            .iter()
            .map(|id| ModelOption {
                id: id.to_string(),
                provider: None,
                available: true,
                detail: None,
            })
            .collect(),
        note: None,
        read_at: None,
    }
}

fn none() -> ModelCatalog {
    ModelCatalog {
        models: vec![],
        note: Some("could not list".into()),
        read_at: None,
    }
}

type Answers = Arc<Mutex<BTreeMap<Harness, ModelCatalog>>>;
type Asked = Arc<Mutex<Vec<Harness>>>;

/// A store whose reader answers from `answers` and counts how often it is asked.
fn store(
    file: std::path::PathBuf,
    answers: &[(Harness, ModelCatalog)],
    clock: Arc<AtomicI64>,
) -> (ModelStore, Answers, Asked) {
    let answers: Answers = Arc::new(Mutex::new(answers.iter().cloned().collect()));
    let asked: Asked = Arc::new(Mutex::new(vec![]));
    let (a, k) = (answers.clone(), asked.clone());
    let store = ModelStore::new(
        file,
        Arc::new(move || clock.load(Ordering::SeqCst)),
        move |harness| {
            k.lock().unwrap().push(harness);
            let answer = a
                .lock()
                .unwrap()
                .get(&harness)
                .cloned()
                .unwrap_or_else(none);
            async move { answer }
        },
    );
    (store, answers, asked)
}

fn clock(at: i64) -> Arc<AtomicI64> {
    Arc::new(AtomicI64::new(at))
}

fn ids(catalog: &ModelCatalog) -> Vec<&str> {
    catalog.models.iter().map(|m| m.id.as_str()).collect()
}

#[tokio::test]
async fn a_list_is_read_when_nothing_is_kept_and_kept_for_what_is_asked_next() {
    let dir = tempdir().unwrap();
    let time = clock(1_000);
    let (store, _, asked) = store(
        dir.path().join("cache/models.json"),
        &[(Harness::Claude, catalog(&["sonnet", "opus"]))],
        time.clone(),
    );
    let first = store.list(Harness::Claude).await;
    assert_eq!(ids(&first), vec!["sonnet", "opus"]);
    assert_eq!(first.read_at, Some(iso_millis(1_000)));
    time.store(5_000, Ordering::SeqCst);
    let second = store.list(Harness::Claude).await;
    // Not read again, and the time is of the read.
    assert_eq!(second.read_at, Some(iso_millis(1_000)));
    assert_eq!(*asked.lock().unwrap(), vec![Harness::Claude]);
}

#[tokio::test]
async fn the_lists_are_in_a_file_which_a_new_store_answers_from_at_once_with_no_read() {
    let dir = tempdir().unwrap();
    let file = dir.path().join("cache/models.json");
    let (first, _, _) = store(
        file.clone(),
        &[(Harness::Codex, catalog(&["gpt-a"]))],
        clock(0),
    );
    first.list(Harness::Codex).await;
    let kept: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&file).unwrap()).unwrap();
    assert_eq!(kept["version"], 1);

    let (second, _, asked) = store(file, &[(Harness::Codex, catalog(&["gpt-other"]))], clock(0));
    assert_eq!(ids(&second.list(Harness::Codex).await), vec!["gpt-a"]);
    assert!(asked.lock().unwrap().is_empty());
}

#[tokio::test]
async fn all_three_are_read_again_when_asked_to_behind_what_was_kept() {
    let dir = tempdir().unwrap();
    let file = dir.path().join("cache/models.json");
    let old = [
        (Harness::Claude, catalog(&["old"])),
        (Harness::Codex, catalog(&["old"])),
        (Harness::Opencode, catalog(&["old"])),
    ];
    store(file.clone(), &old, clock(0)).0.refresh_all().await;

    let new = [
        (Harness::Claude, catalog(&["new-a"])),
        (Harness::Codex, catalog(&["new-b"])),
        (Harness::Opencode, catalog(&["new-c"])),
    ];
    let (store, _, asked) = self::store(file.clone(), &new, clock(0));
    // What was kept is answered before the new lists are in.
    assert_eq!(ids(&store.list(Harness::Claude).await), vec!["old"]);
    store.refresh_all().await;
    let mut seen = asked.lock().unwrap().clone();
    seen.sort();
    assert_eq!(
        seen,
        vec![Harness::Claude, Harness::Codex, Harness::Opencode]
    );
    assert_eq!(ids(&store.list(Harness::Claude).await), vec!["new-a"]);
    assert_eq!(ids(&store.list(Harness::Opencode).await), vec!["new-c"]);
    let kept: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&file).unwrap()).unwrap();
    assert_eq!(kept["harnesses"]["Codex"]["models"][0]["id"], "new-b");
    let mut names: Vec<&String> = kept["harnesses"].as_object().unwrap().keys().collect();
    names.sort();
    assert_eq!(names, vec!["Claude", "Codex", "Opencode"]);
}

#[tokio::test]
async fn a_list_stays_when_a_read_of_it_gives_nothing_and_is_not_replaced_by_that() {
    let dir = tempdir().unwrap();
    let file = dir.path().join("cache/models.json");
    let (store, answers, _) = store(
        file.clone(),
        &[(Harness::Claude, catalog(&["good"]))],
        clock(0),
    );
    store.refresh(Harness::Claude).await;
    answers.lock().unwrap().insert(Harness::Claude, none());
    let again = store.refresh(Harness::Claude).await;
    assert_eq!(ids(&again), vec!["good"]);
    assert!(again.read_at.is_some());
    let kept: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&file).unwrap()).unwrap();
    assert_eq!(kept["harnesses"]["Claude"]["models"][0]["id"], "good");
}

#[tokio::test]
async fn a_list_is_said_to_be_missing_when_there_are_none_and_a_read_gives_nothing_and_not_kept() {
    let dir = tempdir().unwrap();
    let file = dir.path().join("cache/models.json");
    let (store, _, _) = store(file.clone(), &[], clock(0));
    assert_eq!(store.list(Harness::Opencode).await, none());
    assert!(!file.exists());
    assert_eq!(store.list(Harness::Opencode).await, none());
}

#[tokio::test]
async fn an_old_list_is_read_again_behind_the_answer_and_a_new_one_is_not() {
    let dir = tempdir().unwrap();
    let time = clock(0);
    let hours = |n: i64| n * 60 * 60 * 1000;
    let count = Arc::new(AtomicUsize::new(0));
    let release = Arc::new(tokio::sync::Notify::new());
    let (c, r) = (count.clone(), release.clone());
    let store = ModelStore::new(
        dir.path().join("cache/models.json"),
        {
            let time = time.clone();
            Arc::new(move || time.load(Ordering::SeqCst))
        },
        move |_| {
            let (c, r) = (c.clone(), r.clone());
            async move {
                let n = c.fetch_add(1, Ordering::SeqCst);
                if n == 0 {
                    return catalog(&["v1"]);
                }
                // The second read is held until it is let go, so that it is seen to follow the answer.
                r.notified().await;
                catalog(&["v2"])
            }
        },
    );
    store.list(Harness::Claude).await;
    assert_eq!(count.load(Ordering::SeqCst), 1);

    // An hour on: kept, and not read again.
    time.store(hours(1), Ordering::SeqCst);
    assert_eq!(ids(&store.list(Harness::Claude).await), vec!["v1"]);
    assert_eq!(count.load(Ordering::SeqCst), 1);

    // Seven hours on: the answer is what was kept, given while the new read is still going.
    time.store(hours(7), Ordering::SeqCst);
    assert_eq!(ids(&store.list(Harness::Claude).await), vec!["v1"]);
    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    assert_eq!(count.load(Ordering::SeqCst), 2);
    release.notify_one();
    // Asking now joins the read that is going and gets what it read.
    assert_eq!(ids(&store.refresh(Harness::Claude).await), vec!["v2"]);
    assert_eq!(count.load(Ordering::SeqCst), 2);
    assert_eq!(ids(&store.list(Harness::Claude).await), vec!["v2"]);
}

#[tokio::test]
async fn a_list_asked_for_at_the_same_time_is_read_once() {
    let dir = tempdir().unwrap();
    let count = Arc::new(AtomicUsize::new(0));
    let release = Arc::new(tokio::sync::Notify::new());
    let (c, r) = (count.clone(), release.clone());
    let store = ModelStore::new(dir.path().join("models.json"), Arc::new(|| 0), move |_| {
        let (c, r) = (c.clone(), r.clone());
        async move {
            c.fetch_add(1, Ordering::SeqCst);
            r.notified().await;
            catalog(&["sonnet"])
        }
    });
    let together = {
        let (a, b, c) = (store.clone(), store.clone(), store.clone());
        tokio::spawn(async move {
            tokio::join!(
                a.list(Harness::Claude),
                b.list(Harness::Claude),
                c.refresh(Harness::Claude)
            )
        })
    };
    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
    release.notify_one();
    let (a, b, c) = together.await.unwrap();
    assert_eq!(
        [ids(&a), ids(&b), ids(&c)],
        [vec!["sonnet"], vec!["sonnet"], vec!["sonnet"]]
    );
    assert_eq!(count.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn a_file_that_is_not_the_file_of_the_store_is_read_as_nothing() {
    let dir = tempdir().unwrap();
    let file = dir.path().join("cache/models.json");
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    fs::write(&file, r#"{"version": 2, "harnesses": {"Claude": 5}}"#).unwrap();
    let (a, _, asked) = store(
        file.clone(),
        &[(Harness::Claude, catalog(&["sonnet"]))],
        clock(0),
    );
    assert_eq!(ids(&a.list(Harness::Claude).await), vec!["sonnet"]);
    assert_eq!(*asked.lock().unwrap(), vec![Harness::Claude]);
    fs::write(&file, "not json").unwrap();
    let (b, _, _) = store(file, &[(Harness::Claude, catalog(&["sonnet"]))], clock(0));
    assert_eq!(ids(&b.list(Harness::Claude).await), vec!["sonnet"]);
}

#[test]
fn the_models_are_kept_in_the_folder_of_caches_else_the_cache_folder_of_the_home_folder() {
    let with = environment(std::path::Path::new("/h"), &[("XDG_CACHE_HOME", "/c")]);
    assert_eq!(
        model_cache_file(&with),
        std::path::PathBuf::from("/c/synapse-desktop/models.json")
    );
    let without = environment(std::path::Path::new("/h"), &[]);
    assert_eq!(
        model_cache_file(&without),
        std::path::PathBuf::from("/h/.cache/synapse-desktop/models.json")
    );
}
