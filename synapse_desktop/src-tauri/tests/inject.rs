//! Starting a harness with the bundled Synapse loaded for that session only, and the login shell that
//! does the same for the harnesses typed in it. The same cases as the Node host's `inject.test.ts`.

// Some cases need a Unix shell or socket; what only they use is unused on Windows.
#![cfg_attr(windows, allow(unused_imports, dead_code))]

mod support;

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use support::environment;
use synapse_desktop_host::inject::{
    is_installed, plan_session, plan_shell, render_hooks, shell_word, shim_script, InjectDeps,
    SessionPlan, Tracking,
};
use synapse_desktop_host::messages::Harness;
use synapse_desktop_host::status::{find_content_root, find_executable};
use tempfile::{tempdir, TempDir};

fn put(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

const HOOKS: &str = r#"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"synapse-hook session-start"}]},{"hooks":[{"type":"command","command":"echo not-ours"}]}]}}"#;

/// A package like the `synapse` one: skills, commands and a file for each harness.
fn make_package(root: &Path) {
    put(
        &root.join("skills/query/SKILL.md"),
        "---\nname: query\n---\n",
    );
    put(
        &root.join("skills/vault/SKILL.md"),
        "---\nname: vault\n---\n",
    );
    put(&root.join("commands/note.md"), "note command\n");
    put(&root.join("commands/notes.txt"), "not a command\n");
    put(&root.join("harness/claude/hooks.json"), HOOKS);
    put(&root.join("harness/codex/hooks.json"), HOOKS);
    put(
        &root.join("harness/codex/skills/codex-only/SKILL.md"),
        "codex skill\n",
    );
    put(
        &root.join("harness/opencode/plugin/synapse.js"),
        "const bin = \"__SYNAPSE_HOOK_BIN__\"\n",
    );
}

struct World {
    /// Holds the temporary folder until the test ends.
    _dir: TempDir,
    base: PathBuf,
    pkg: PathBuf,
    hook: PathBuf,
    home: PathBuf,
    data: PathBuf,
}

impl World {
    fn new() -> World {
        let dir = tempdir().unwrap();
        // The host names a folder by its real path, which is not the temporary folder's own where
        // that is a link (macOS).
        let base = dunce::canonicalize(dir.path()).unwrap();
        let pkg = base.join("pkg");
        make_package(&pkg);
        let hook = base.join("bin/synapse-hook");
        put(&hook, "#!/bin/sh\n");
        let home = base.join("home");
        fs::create_dir_all(&home).unwrap();
        let data = base.join("data");
        World {
            _dir: dir,
            base,
            pkg,
            hook,
            home,
            data,
        }
    }

    fn deps(&self, path: &str, extra: &[(&str, &str)]) -> InjectDeps {
        let mut vars = vec![
            (
                "SYNAPSE_CONTENT_ROOT".to_string(),
                self.pkg.to_string_lossy().to_string(),
            ),
            ("PATH".to_string(), path.to_string()),
        ];
        vars.extend(extra.iter().map(|(k, v)| (k.to_string(), v.to_string())));
        let refs: Vec<(&str, &str)> = vars.iter().map(|(k, v)| (k.as_str(), v.as_str())).collect();
        InjectDeps {
            environment: environment(&self.home, &refs),
            data_dir: self.data.clone(),
            bundled_roots: vec![],
        }
    }

    fn bin(&self) -> String {
        self.base.join("bin").to_string_lossy().to_string()
    }
}

fn names(dir: &Path) -> Vec<String> {
    let mut found: Vec<String> = fs::read_dir(dir)
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().to_string())
        .collect();
    found.sort();
    found
}

/// A path as the host writes it into a command: with forward slashes on every platform.
fn forward(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
}

fn s(path: &Path) -> String {
    path.to_string_lossy().to_string()
}

// ---------------------------------------------------------------------------------------------
// Finding the content and the hook
// ---------------------------------------------------------------------------------------------

#[test]
fn the_content_is_the_folder_synapse_content_root_names_and_the_package_of_the_launcher_on_path() {
    let w = World::new();
    let named = environment(&w.home, &[("SYNAPSE_CONTENT_ROOT", &s(&w.pkg))]);
    assert_eq!(
        find_content_root(&named, &[]),
        Some(dunce::canonicalize(&w.pkg).unwrap())
    );
    // A launcher in `<package>/bin`, as npm makes it.
    put(&w.pkg.join("bin/synapse"), "#!/bin/sh\n");
    let by_path = environment(&w.home, &[("PATH", &s(&w.pkg.join("bin")))]);
    assert_eq!(
        find_content_root(&by_path, &[]),
        Some(dunce::canonicalize(&w.pkg).unwrap())
    );
    // The folders the app is bundled with, when nothing else says.
    let none = environment(&w.home, &[]);
    assert_eq!(find_content_root(&none, &[]), None);
    assert!(find_content_root(&none, std::slice::from_ref(&w.pkg)).is_some());
}

#[test]
fn a_program_is_found_on_path_and_nothing_when_it_is_not_there() {
    let w = World::new();
    assert_eq!(
        find_executable("synapse-hook", &w.bin()),
        Some(w.hook.clone())
    );
    assert_eq!(
        find_executable("synapse-hook", &s(&w.base.join("nowhere"))),
        None
    );
}

#[test]
fn where_the_hook_is_goes_in_front_of_the_commands_that_name_it() {
    let w = World::new();
    let rendered = render_hooks(&w.pkg.join("harness/claude/hooks.json"), &s(&w.hook)).unwrap();
    let text = rendered.to_string();
    assert!(text.contains(&format!("{} session-start", forward(&w.hook))));
    assert!(text.contains("echo not-ours"));
}

#[test]
fn a_hook_path_with_a_blank_is_quoted_as_one_word_and_other_paths_are_left_as_they_are() {
    let w = World::new();
    let spaced = w.pkg.join("Synapse Desktop.app/synapse-hook");
    let rendered = render_hooks(&w.pkg.join("harness/claude/hooks.json"), &s(&spaced)).unwrap();
    let escaped =
        serde_json::to_string(&format!("\"{}\" session-start", forward(&spaced))).unwrap();
    assert!(rendered
        .to_string()
        .contains(&escaped[1..escaped.len() - 1]));
    assert_eq!(
        shell_word("/usr/local/bin/synapse-hook"),
        "/usr/local/bin/synapse-hook"
    );
    // A short Windows name has a `~` in it, which a shell reads only at the start.
    assert_eq!(
        shell_word("C:/Users/RUNNER~1/AppData/synapse-hook.exe"),
        "C:/Users/RUNNER~1/AppData/synapse-hook.exe"
    );
    assert_eq!(
        shell_word("C:/Program Files/Synapse/synapse-hook.exe"),
        "\"C:/Program Files/Synapse/synapse-hook.exe\""
    );
    assert_eq!(shell_word("/a/it\"s $HOME/h"), "\"/a/it\\\"s \\$HOME/h\"");
}

#[test]
fn synapse_is_known_by_its_hook_in_the_file_that_configure_writes_and_by_the_plugin() {
    let w = World::new();
    for harness in [Harness::Claude, Harness::Codex, Harness::Opencode] {
        assert!(!is_installed(harness, &w.home));
    }
    put(
        &w.home.join(".claude/settings.json"),
        r#"{"hooks":{"x":"/bin/synapse-hook start"}}"#,
    );
    put(&w.home.join(".codex/hooks.json"), r#"{"hooks":{}}"#);
    put(&w.home.join(".config/opencode/plugin/synapse.js"), "");
    assert!(is_installed(Harness::Claude, &w.home));
    assert!(!is_installed(Harness::Codex, &w.home));
    assert!(is_installed(Harness::Opencode, &w.home));
}

#[test]
fn a_harness_that_has_synapse_installed_is_started_as_it_is_and_nothing_is_made() {
    let w = World::new();
    put(
        &w.home.join(".claude/settings.json"),
        r#"{"hooks":{"x":"synapse-hook start"}}"#,
    );
    let plan = plan_session(Harness::Claude, &w.deps(&w.bin(), &[])).unwrap();
    assert_eq!((plan.command.as_str(), plan.loaded), ("claude", false));
    assert!(plan.args.is_empty() && plan.env.is_empty());
    assert!(plan.note.contains("installed in Claude Code"));
    assert!(!w.data.exists());
}

#[test]
fn the_content_not_being_found_is_said_and_the_harness_is_started_as_it_is() {
    let w = World::new();
    let mut deps = w.deps(&w.bin(), &[]);
    deps.environment.env.remove("SYNAPSE_CONTENT_ROOT");
    let plan = plan_session(Harness::Codex, &deps).unwrap();
    assert!(!plan.loaded);
    assert!(plan
        .note
        .contains("The Synapse content was not found, so this is Codex as it is."));
}

// ---------------------------------------------------------------------------------------------
// Claude Code, Codex, OpenCode
// ---------------------------------------------------------------------------------------------

#[test]
fn claude_gets_skills_and_commands_as_an_added_folder_and_hooks_as_a_settings_file() {
    let w = World::new();
    let plan = plan_session(Harness::Claude, &w.deps(&w.bin(), &[])).unwrap();
    let overlay = w.data.join("claude").join("overlay");
    let settings = w.data.join("claude").join("settings.json");
    assert_eq!(plan.command, "claude");
    assert_eq!(
        plan.args,
        ["--add-dir", &s(&overlay), "--settings", &s(&settings)]
    );
    assert!(plan.loaded);
    assert_eq!(
        plan.env,
        BTreeMap::from([("SYNAPSE_CONTENT_ROOT".to_string(), s(&w.pkg))])
    );
    assert_eq!(names(&overlay.join(".claude/skills")), ["query", "vault"]);
    assert_eq!(names(&overlay.join(".claude/commands")), ["note.md"]);
    let written: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&settings).unwrap()).unwrap();
    assert_eq!(written["env"]["SYNAPSE_CONTENT_ROOT"], s(&w.pkg));
    assert!(written["hooks"]
        .to_string()
        .contains(&format!("{} session-start", forward(&w.hook))));
}

#[test]
fn a_skill_that_has_gone_leaves_nothing_behind_and_no_hook_program_loads_no_hooks_and_says_so() {
    let w = World::new();
    plan_session(Harness::Claude, &w.deps(&w.bin(), &[])).unwrap();
    fs::remove_dir_all(w.pkg.join("skills/vault")).unwrap();
    plan_session(Harness::Claude, &w.deps(&w.bin(), &[])).unwrap();
    assert_eq!(
        names(&w.data.join("claude/overlay/.claude/skills")),
        ["query"]
    );

    let plan = plan_session(Harness::Claude, &w.deps("", &[])).unwrap();
    assert!(plan.loaded);
    assert!(plan.note.contains("hooks are not loaded"));
    let written: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(w.data.join("claude/settings.json")).unwrap())
            .unwrap();
    assert!(written.get("hooks").is_none());
}

fn trusted(home: &Path) -> String {
    format!(
        "[hooks.state.\"{}:session_start:0:0\"]\ntrusted_hash = \"sha256:abc\"\n",
        home.join("hooks.json").display()
    )
}

#[cfg(unix)]
#[test]
fn codex_gets_a_home_of_its_own_with_the_login_linked_the_settings_copied_and_skills_and_hooks_added(
) {
    let w = World::new();
    put(&w.home.join(".codex/auth.json"), r#"{"token":"x"}"#);
    put(&w.home.join(".codex/config.toml"), "model = \"m\"\n");
    let plan = plan_session(Harness::Codex, &w.deps(&w.bin(), &[])).unwrap();
    let home = w.data.join("codex");
    assert!(plan.args.is_empty());
    assert_eq!(
        plan.env,
        BTreeMap::from([
            ("CODEX_HOME".to_string(), s(&home)),
            ("SYNAPSE_CONTENT_ROOT".to_string(), s(&w.pkg)),
        ])
    );
    assert_eq!(
        fs::read_link(home.join("auth.json")).unwrap(),
        w.home.join(".codex/auth.json")
    );
    assert_eq!(
        fs::read_to_string(home.join("config.toml")).unwrap(),
        "model = \"m\"\n"
    );
    assert_eq!(
        names(&home.join("skills")),
        ["codex-only", "query", "vault"]
    );
    assert!(fs::read_to_string(home.join("hooks.json"))
        .unwrap()
        .contains(&format!("{} session-start", forward(&w.hook))));
    // The user's own home is not touched.
    assert_eq!(names(&w.home.join(".codex")), ["auth.json", "config.toml"]);
    assert!(plan.note.contains("trust the hooks"));
}

#[test]
fn codex_keeps_the_trust_given_to_its_hooks_when_it_is_started_again_and_the_settings_follow_the_user(
) {
    let w = World::new();
    put(&w.home.join(".codex/config.toml"), "model = \"m\"\n");
    plan_session(Harness::Codex, &w.deps(&w.bin(), &[])).unwrap();
    let home = w.data.join("codex");
    let config = fs::read_to_string(home.join("config.toml")).unwrap();
    fs::write(
        home.join("config.toml"),
        format!("{config}\n{}", trusted(&home)),
    )
    .unwrap();
    put(&w.home.join(".codex/config.toml"), "model = \"changed\"\n");

    plan_session(Harness::Codex, &w.deps(&w.bin(), &[])).unwrap();
    let again = fs::read_to_string(home.join("config.toml")).unwrap();
    assert!(again.contains("model = \"changed\""));
    assert_eq!(again.matches(&trusted(&home)).count(), 1);
    plan_session(Harness::Codex, &w.deps(&w.bin(), &[])).unwrap();
    assert_eq!(
        fs::read_to_string(home.join("config.toml"))
            .unwrap()
            .matches(&trusted(&home))
            .count(),
        1
    );
}

#[test]
fn codex_works_for_a_user_with_no_codex_yet() {
    let w = World::new();
    let plan = plan_session(Harness::Codex, &w.deps(&w.bin(), &[])).unwrap();
    assert!(plan.loaded);
    assert!(!w.data.join("codex/auth.json").exists());
}

#[test]
fn opencode_gets_a_configuration_folder_with_skills_commands_and_the_plugin_that_has_the_hook_in_it(
) {
    let w = World::new();
    let plan = plan_session(Harness::Opencode, &w.deps(&w.bin(), &[])).unwrap();
    let config = w.data.join("opencode");
    assert_eq!(
        plan.env,
        BTreeMap::from([
            ("OPENCODE_CONFIG_DIR".to_string(), s(&config)),
            ("SYNAPSE_CONTENT_ROOT".to_string(), s(&w.pkg)),
        ])
    );
    // The skill forms of the commands are skills as well, as for Codex.
    assert_eq!(
        names(&config.join("skill")),
        ["codex-only", "query", "vault"]
    );
    assert_eq!(
        fs::read_to_string(config.join("skill/codex-only/SKILL.md")).unwrap(),
        "codex skill\n"
    );
    assert_eq!(names(&config.join("command")), ["note.md"]);
    // The plugin is JavaScript, which takes forward slashes on every platform.
    let literal = serde_json::to_string(&s(&w.hook).replace('\\', "/")).unwrap();
    assert_eq!(
        fs::read_to_string(config.join("plugin/synapse.js")).unwrap(),
        format!("const bin = {literal}\n")
    );
}

#[test]
fn opencode_has_no_plugin_without_the_hook_program() {
    let w = World::new();
    plan_session(Harness::Opencode, &w.deps(&w.bin(), &[])).unwrap();
    plan_session(Harness::Opencode, &w.deps("", &[])).unwrap();
    assert!(names(&w.data.join("opencode/plugin")).is_empty());
}

// ---------------------------------------------------------------------------------------------
// The wrapper commands, run by a real shell
// ---------------------------------------------------------------------------------------------

#[cfg(unix)]
mod wrappers {
    use super::*;
    use std::process::Command;
    use support::executable;

    fn real_program(folder: &Path, name: &str) {
        executable(
            &folder.join(name),
            &format!("#!/bin/sh\necho \"REAL {name} args=$* env=$SYNAPSE_X\"\n"),
        );
    }

    fn plan(args: &[&str], env: &[(&str, &str)]) -> SessionPlan {
        SessionPlan {
            command: "x".into(),
            args: args.iter().map(|a| a.to_string()).collect(),
            env: env
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
            loaded: true,
            note: String::new(),
        }
    }

    /// The system folders are on every shell's PATH, after the others.
    fn run(script: &Path, path: &str, args: &[&str]) -> std::process::Output {
        Command::new("/bin/sh")
            .arg(script)
            .args(args)
            .env_clear()
            .env("PATH", format!("{path}:/usr/bin:/bin"))
            .output()
            .unwrap()
    }

    fn out(o: &std::process::Output) -> String {
        String::from_utf8_lossy(&o.stdout).to_string()
    }

    #[test]
    fn what_it_is_given_is_quoted_so_that_a_value_with_a_quote_or_a_blank_survives() {
        let text = shim_script(
            "claude",
            &plan(&["--add-dir", "/a b/it's"], &[("SYNAPSE_X", "v'1")]),
            None,
        );
        assert!(text.contains("export SYNAPSE_X='v'\\''1'"));
        assert!(text.contains("'--add-dir' '/a b/it'\\''s' \"$@\""));
    }

    #[test]
    fn it_starts_the_next_program_of_the_name_on_path_with_the_plan_first_and_the_typed_arguments_after(
    ) {
        let w = World::new();
        let (shims, real) = (w.base.join("shims"), w.base.join("real"));
        real_program(&real, "claude");
        real_program(&shims, "claude");
        // The shim stands where the real one would be found first.
        executable(
            &shims.join("claude"),
            &shim_script(
                "claude",
                &plan(&["--injected"], &[("SYNAPSE_X", "one")]),
                None,
            ),
        );
        let o = run(
            &shims.join("claude"),
            &format!("{}:{}", shims.display(), real.display()),
            &["typed", "args"],
        );
        assert!(o.status.success());
        assert_eq!(out(&o), "REAL claude args=--injected typed args env=one\n");
    }

    #[test]
    fn it_says_so_and_does_not_start_itself_again_when_there_is_no_other_program_of_the_name() {
        let w = World::new();
        let shims = w.base.join("shims");
        executable(
            &shims.join("codex"),
            &shim_script("codex", &plan(&[], &[]), None),
        );
        let o = run(&shims.join("codex"), &s(&shims), &[]);
        assert_eq!(o.status.code(), Some(127));
        assert!(String::from_utf8_lossy(&o.stderr).contains("codex: command not found"));
    }

    #[test]
    fn they_are_made_for_the_harnesses_without_synapse_and_put_first_on_the_path_of_a_login_shell()
    {
        let w = World::new();
        put(
            &w.home.join(".claude/settings.json"),
            r#"{"hooks":{"x":"synapse-hook start"}}"#,
        );
        let plan = plan_shell(&w.deps(&w.bin(), &[("SHELL", "/bin/bash")])).unwrap();
        let shims = w.data.join("shims");
        assert_eq!(plan.plan.command, "/bin/bash");
        assert_eq!(plan.plan.args, ["-l"]);
        assert!(plan.plan.loaded);
        // The ones that load Synapse; Claude is wrapped as well, to be followed.
        assert_eq!(plan.wrapped, ["codex", "opencode"]);
        assert_eq!(names(&shims), ["claude", "codex", "opencode"]);
        assert!(!fs::read_to_string(shims.join("claude"))
            .unwrap()
            .contains("--add-dir"));
        assert_eq!(
            plan.plan.env["PATH"],
            format!("{}:{}", shims.display(), w.bin())
        );
        assert!(!plan.plan.env.contains_key("ZDOTDIR"));
        assert!(plan.plan.note.contains("codex, opencode"));
    }

    #[test]
    fn nothing_is_loaded_when_every_harness_has_synapse_installed_but_every_conversation_is_still_followed(
    ) {
        let w = World::new();
        put(&w.home.join(".claude/settings.json"), "synapse-hook");
        put(&w.home.join(".codex/hooks.json"), "synapse-hook");
        put(&w.home.join(".config/opencode/plugin/synapse.js"), "");
        let plan = plan_shell(&w.deps(&w.bin(), &[])).unwrap();
        assert!(!plan.plan.loaded && plan.wrapped.is_empty());
        assert_eq!(
            names(&w.data.join("shims")),
            ["claude", "codex", "opencode"]
        );
        assert!(!plan.plan.note.contains("load Synapse"));
        assert!(plan.plan.note.contains("claude, codex or opencode"));
    }

    fn zsh_available() -> bool {
        Command::new("zsh")
            .arg("--version")
            .output()
            .is_ok_and(|o| o.status.success())
    }

    #[test]
    fn the_commands_keep_first_place_in_zsh_whatever_the_user_files_do_to_path() {
        if !zsh_available() {
            return;
        }
        let w = World::new();
        // A user's .zshrc that puts a program of its own ahead of everything.
        let mine = w.base.join("mine");
        real_program(&mine, "claude");
        put(
            &w.home.join(".zshrc"),
            &format!("export PATH=\"{}:$PATH\"\n", mine.display()),
        );
        let real = w.base.join("real");
        real_program(&real, "claude");
        let path = format!("{}:{}:/usr/bin:/bin", w.bin(), real.display());
        let plan = plan_shell(&w.deps(&path, &[("SHELL", "/bin/zsh")])).unwrap();
        assert_eq!(plan.plan.env["ZDOTDIR"], s(&w.data.join("zdotdir")));
        let mut command = Command::new("zsh");
        command
            .args(["-l", "-i", "-c", "command -v claude; claude one"])
            .env_clear()
            .env("HOME", &w.home);
        for (k, v) in &plan.plan.env {
            command.env(k, v);
        }
        let o = command.output().unwrap();
        let text = out(&o);
        assert_eq!(
            text.lines().next().unwrap(),
            s(&w.data.join("shims").join("claude"))
        );
        assert!(text.contains("REAL claude args=--add-dir"), "{text}");
        assert!(text.contains(" one env="));
    }

    // Following a conversation ---------------------------------------------------------------

    struct Follow {
        w: World,
        sessions: PathBuf,
        shims: PathBuf,
        real: PathBuf,
    }

    fn follow() -> Follow {
        let w = World::new();
        let (sessions, shims, real) = (
            w.base.join("sessions"),
            w.base.join("shims"),
            w.base.join("real"),
        );
        fs::create_dir_all(&shims).unwrap();
        for name in ["claude", "codex", "opencode"] {
            executable(
                &real.join(name),
                &format!("#!/bin/sh\necho \"REAL {name} $*\"\n"),
            );
        }
        Follow {
            w,
            sessions,
            shims,
            real,
        }
    }

    impl Follow {
        fn install(&self, name: &str, tracking: Tracking, plan: SessionPlan) {
            executable(
                &self.shims.join(name),
                &shim_script(name, &plan, Some(tracking)),
            );
        }

        fn start(
            &self,
            name: &str,
            args: &[&str],
            cwd: &Path,
            tracked: bool,
        ) -> std::process::Output {
            let mut command = Command::new("/bin/sh");
            command
                .arg(self.shims.join(name))
                .args(args)
                .current_dir(cwd)
                .env_clear()
                .env(
                    "PATH",
                    format!(
                        "{}:{}:/usr/bin:/bin",
                        self.shims.display(),
                        self.real.display()
                    ),
                )
                .env("HOME", &self.w.home);
            if tracked {
                command.env("SYNAPSE_SESSIONS_DIR", &self.sessions);
            }
            command.output().unwrap()
        }

        fn registrations(&self) -> Vec<serde_json::Value> {
            let Ok(read) = fs::read_dir(&self.sessions) else {
                return vec![];
            };
            read.flatten()
                .filter(|e| e.file_name().to_string_lossy().ends_with(".json"))
                .map(|e| serde_json::from_str(&fs::read_to_string(e.path()).unwrap()).unwrap())
                .collect()
        }
    }

    fn empty_plan() -> SessionPlan {
        plan(&[], &[])
    }

    #[test]
    fn a_new_claude_session_is_given_an_id_and_says_where_and_when_it_started() {
        let f = follow();
        f.install("claude", Tracking::Claude, empty_plan());
        let o = f.start("claude", &["fix it"], &f.w.base, true);
        let text = out(&o);
        let id = regex::Regex::new(r"--session-id ([0-9a-f-]{36})")
            .unwrap()
            .captures(&text)
            .map(|c| c[1].to_string());
        assert!(id.is_some(), "{text}");
        assert!(text.contains("REAL claude --session-id"));
        assert!(text.trim().ends_with("fix it"));
        let registrations = f.registrations();
        assert_eq!(registrations[0]["harness"], "claude");
        assert_eq!(registrations[0]["sessionId"], id.unwrap());
        assert_eq!(
            registrations[0]["cwd"],
            dunce::canonicalize(&f.w.base)
                .unwrap()
                .to_string_lossy()
                .to_string()
        );
        assert_eq!(registrations[0]["configDir"], s(&f.w.home.join(".claude")));
        let started = registrations[0]["startedAt"].as_i64().unwrap();
        let now = synapse_desktop_host::time::millis(std::time::SystemTime::now());
        assert!((started - now).abs() < 10_000);
    }

    #[test]
    fn a_folder_with_a_quote_or_a_backslash_in_its_name_is_written_as_valid_json() {
        let f = follow();
        f.install("claude", Tracking::Claude, empty_plan());
        let odd = f.w.base.join("a\"b\\c d");
        fs::create_dir(&odd).unwrap();
        f.start("claude", &[], &odd, true);
        let cwd = f.registrations()[0]["cwd"].as_str().unwrap().to_string();
        assert_eq!(cwd, dunce::canonicalize(&odd).unwrap().to_string_lossy());
    }

    #[test]
    fn a_run_that_is_not_a_new_session_is_not_followed_and_its_arguments_are_as_they_were() {
        let f = follow();
        f.install("claude", Tracking::Claude, empty_plan());
        for args in [
            vec!["--resume"],
            vec!["-c"],
            vec!["--continue"],
            vec!["-p", "hi"],
            vec!["mcp", "list"],
            vec!["doctor"],
            vec!["--version"],
            vec!["--session-id", "abc"],
            vec!["-h"],
        ] {
            let o = f.start("claude", &args, &f.w.base, true);
            assert_eq!(out(&o).trim(), format!("REAL claude {}", args.join(" ")));
        }
        assert!(f.registrations().is_empty());
    }

    #[test]
    fn nothing_is_followed_when_it_is_not_asked_to_and_the_program_still_starts() {
        let f = follow();
        f.install("claude", Tracking::Claude, empty_plan());
        let o = f.start("claude", &["x"], &f.w.base, false);
        assert_eq!(out(&o).trim(), "REAL claude x");
    }

    #[test]
    fn a_codex_session_notes_where_and_when_it_started_and_where_it_keeps_its_sessions() {
        let f = follow();
        f.install(
            "codex",
            Tracking::Codex,
            plan(&[], &[("CODEX_HOME", "/the/home")]),
        );
        f.start("codex", &["fix it"], &f.w.base, true);
        let registration = &f.registrations()[0];
        assert_eq!(registration["harness"], "codex");
        assert_eq!(registration["home"], "/the/home");
        assert!(registration["startedAt"].is_number());
    }

    #[test]
    fn a_codex_run_that_is_a_command_and_not_a_session_is_not_noted() {
        let f = follow();
        f.install("codex", Tracking::Codex, empty_plan());
        for args in [
            vec!["exec", "x"],
            vec!["login"],
            vec!["mcp", "list"],
            vec!["review"],
        ] {
            assert!(f.start("codex", &args, &f.w.base, true).status.success());
        }
        assert!(f.registrations().is_empty());
    }

    #[test]
    fn a_new_opencode_session_is_given_an_id_of_our_own_and_says_where_and_when_it_started() {
        let f = follow();
        f.install("opencode", Tracking::Opencode, empty_plan());
        let text = out(&f.start("opencode", &["--prompt", "fix it"], &f.w.base, true));
        let id = regex::Regex::new(r"--session (ses_[0-9a-f]{20})")
            .unwrap()
            .captures(&text)
            .map(|c| c[1].to_string());
        assert!(id.is_some(), "{text}");
        assert!(text.contains("REAL opencode --session"));
        assert!(text.trim().ends_with("--prompt fix it"));
        let registration = &f.registrations()[0];
        assert_eq!(registration["harness"], "opencode");
        assert_eq!(registration["sessionId"], id.unwrap());
        assert_eq!(
            registration["cwd"],
            dunce::canonicalize(&f.w.base)
                .unwrap()
                .to_string_lossy()
                .to_string()
        );
        assert!(registration["startedAt"].is_number());
    }

    #[test]
    fn an_opencode_run_that_is_a_command_a_folder_or_a_session_of_its_own_is_not_followed() {
        let f = follow();
        f.install("opencode", Tracking::Opencode, empty_plan());
        for args in [
            vec!["run", "hi"],
            vec!["session", "list"],
            vec!["upgrade"],
            vec!["some/folder"],
            vec!["--continue"],
            vec!["-c"],
            vec!["--session", "ses_abc"],
            vec!["-s", "ses_abc"],
            vec!["--session=ses_abc"],
            vec!["--version"],
            vec!["--server", "http://localhost:1"],
        ] {
            let o = f.start("opencode", &args, &f.w.base, true);
            assert_eq!(out(&o).trim(), format!("REAL opencode {}", args.join(" ")));
        }
        assert!(f.registrations().is_empty());
    }
}
