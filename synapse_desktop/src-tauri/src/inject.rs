//! Starting a harness with the bundled Synapse loaded for that session only: its skills, commands and
//! hooks come from directories of the app's own, which the harness is pointed at, and nothing is
//! written into the harness's own configuration. A harness that has Synapse installed is used as it
//! is.

use crate::environment::{join_paths, Environment};
use crate::messages::Harness;
use crate::status::{find_content_root, find_executable};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

/// How to start something for one session: what to run, and what it is given besides the user's own
/// environment.
#[derive(Clone, Debug, PartialEq)]
pub struct SessionPlan {
    pub command: String,
    pub args: Vec<String>,
    pub env: BTreeMap<String, String>,
    /// The bundled Synapse is loaded for this session.
    pub loaded: bool,
    /// What is said to the person about it.
    pub note: String,
}

#[derive(Clone, Debug)]
pub struct InjectDeps {
    pub environment: Environment,
    /// Where the app keeps what it makes for a harness; one folder for each.
    pub data_dir: PathBuf,
    /// The folders the app is bundled with, where its skills and harness files are when nothing on the
    /// PATH says.
    pub bundled_roots: Vec<PathBuf>,
}

/// Where the app keeps what it makes for the harnesses it injects Synapse into.
pub fn injected_dir(environment: &Environment) -> PathBuf {
    let base = environment
        .var("XDG_DATA_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| environment.home.join(".local").join("share"));
    base.join("synapse-desktop").join("injected")
}

const HOOK_NAME: &str = "synapse-hook";

fn command_of(harness: Harness) -> &'static str {
    match harness {
        Harness::Claude => "claude",
        Harness::Codex => "codex",
        Harness::Opencode => "opencode",
    }
}

fn label_of(harness: Harness) -> &'static str {
    match harness {
        Harness::Claude => "Claude Code",
        Harness::Codex => "Codex",
        Harness::Opencode => "OpenCode",
    }
}

fn name_of(harness: Harness) -> &'static str {
    match harness {
        Harness::Claude => "claude",
        Harness::Codex => "codex",
        Harness::Opencode => "opencode",
    }
}

fn path_variable(environment: &Environment) -> &str {
    environment
        .env
        .get("PATH")
        .map(String::as_str)
        .unwrap_or("")
}

/// Whether the harness has Synapse installed: the hook in the file that `synapse-setup configure`
/// writes it to, or the OpenCode plugin it installs.
pub fn is_installed(harness: Harness, home: &Path) -> bool {
    let mentions_hook = |file: PathBuf| {
        fs::read_to_string(file)
            .unwrap_or_default()
            .contains(HOOK_NAME)
    };
    match harness {
        Harness::Claude => mentions_hook(home.join(".claude/settings.json")),
        Harness::Codex => mentions_hook(home.join(".codex/hooks.json")),
        Harness::Opencode => home.join(".config/opencode/plugin/synapse.js").is_file(),
    }
}

/// What a shell would split or read in a path: a space, a quote, an escape or any of the characters it
/// gives a meaning to. A `~` is only read at the start of a word and a path is absolute, so a short
/// Windows name such as `RUNNER~1` is not quoted.
fn needs_quoting(path: &str) -> bool {
    path.chars()
        .any(|c| c.is_whitespace() || "'\"\\$`&;|<>()*?[]{}!#^%".contains(c))
}

/// A path as the first word of a shell command: as it is when nothing in it needs quoting, else in
/// double quotes with `\`, `"`, `$` and the backtick escaped.
pub fn shell_word(path: &str) -> String {
    if !needs_quoting(path) {
        return path.to_string();
    }
    let mut quoted = String::from("\"");
    for c in path.chars() {
        if matches!(c, '\\' | '"' | '$' | '`') {
            quoted.push('\\');
        }
        quoted.push(c);
    }
    quoted.push('"');
    quoted
}

/// `/` between the parts on Windows: the command runs through a shell that may read `\` as an escape.
fn slashed(path: &str) -> String {
    if cfg!(windows) {
        path.replace('\\', "/")
    } else {
        path.to_string()
    }
}

/// A hooks template with the bare `synapse-hook` at the start of each command replaced by where the
/// program is.
pub fn render_hooks(template_path: &Path, hook_binary: &str) -> std::io::Result<Value> {
    let mut template: Value = serde_json::from_str(&fs::read_to_string(template_path)?)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    let prefix = format!("{HOOK_NAME} ");
    if let Some(Value::Object(hooks)) = template.get_mut("hooks") {
        for groups in hooks.values_mut() {
            for group in groups.as_array_mut().into_iter().flatten() {
                for hook in group
                    .get_mut("hooks")
                    .and_then(Value::as_array_mut)
                    .into_iter()
                    .flatten()
                {
                    let Some(command) = hook.get("command").and_then(Value::as_str) else {
                        continue;
                    };
                    if let Some(rest) = command.strip_prefix(&prefix) {
                        let replaced = format!("{} {rest}", shell_word(&slashed(hook_binary)));
                        hook["command"] = json!(replaced);
                    }
                }
            }
        }
    }
    Ok(template)
}

/// Empties a folder of the app's own, which must be inside its data directory.
fn reset_dir(data_dir: &Path, dir: &Path) -> std::io::Result<()> {
    if !dir.starts_with(data_dir) || dir == data_dir {
        return Err(std::io::Error::other(format!(
            "{} is not inside {}",
            dir.display(),
            data_dir.display()
        )));
    }
    let _ = fs::remove_dir_all(dir);
    fs::create_dir_all(dir)
}

fn skill_names(root: &Path) -> Vec<String> {
    fs::read_dir(root)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.path().is_dir())
        .map(|e| e.file_name().to_string_lossy().to_string())
        .collect()
}

/// Every skill of `from` as `<to>/<name>/SKILL.md`.
fn copy_skills(from: &Path, to: &Path) -> std::io::Result<()> {
    for name in skill_names(from) {
        fs::create_dir_all(to.join(&name))?;
        fs::copy(
            from.join(&name).join("SKILL.md"),
            to.join(&name).join("SKILL.md"),
        )?;
    }
    Ok(())
}

fn copy_commands(from: &Path, to: &Path) -> std::io::Result<()> {
    fs::create_dir_all(to)?;
    for entry in fs::read_dir(from)?.flatten() {
        if entry.file_name().to_string_lossy().ends_with(".md") {
            fs::copy(entry.path(), to.join(entry.file_name()))?;
        }
    }
    Ok(())
}

fn copy_dir(from: &Path, to: &Path) -> std::io::Result<()> {
    fs::create_dir_all(to)?;
    for entry in fs::read_dir(from)?.flatten() {
        let target = to.join(entry.file_name());
        if entry.path().is_dir() {
            copy_dir(&entry.path(), &target)?;
        } else {
            fs::copy(entry.path(), target)?;
        }
    }
    Ok(())
}

/// Every skill that is only Codex's, which OpenCode is shown too: a model is shown skills and not
/// commands, so the instructions the commands carry are skills there.
fn copy_codex_skills(root: &Path, to: &Path) -> std::io::Result<()> {
    let from = root.join("harness/codex/skills");
    for name in skill_names(&from) {
        copy_dir(&from.join(&name), &to.join(&name))?;
    }
    Ok(())
}

struct Made {
    args: Vec<String>,
    env: BTreeMap<String, String>,
}

fn strings(items: &[&str]) -> Vec<String> {
    items.iter().map(|s| s.to_string()).collect()
}

fn text(path: &Path) -> String {
    path.to_string_lossy().to_string()
}

fn claude_session(
    dir: &Path,
    root: &Path,
    hook_binary: Option<&Path>,
    data_dir: &Path,
) -> std::io::Result<Made> {
    let overlay = dir.join("overlay");
    reset_dir(data_dir, &overlay)?;
    copy_skills(&root.join("skills"), &overlay.join(".claude/skills"))?;
    copy_commands(&root.join("commands"), &overlay.join(".claude/commands"))?;
    let mut settings = json!({ "env": { "SYNAPSE_CONTENT_ROOT": text(root) } });
    if let Some(hook) = hook_binary {
        settings["hooks"] =
            render_hooks(&root.join("harness/claude/hooks.json"), &text(hook))?["hooks"].clone();
    }
    let settings_file = dir.join("settings.json");
    fs::write(
        &settings_file,
        serde_json::to_string_pretty(&settings).unwrap_or_default() + "\n",
    )?;
    Ok(Made {
        args: strings(&[
            "--add-dir",
            &text(&overlay),
            "--settings",
            &text(&settings_file),
        ]),
        env: BTreeMap::from([("SYNAPSE_CONTENT_ROOT".into(), text(root))]),
    })
}

/// The trust a person gave this home's hooks, which the new config keeps.
fn trust_blocks(config: &str, hooks_file: &Path) -> String {
    let wanted = format!("[hooks.state.\"{}:", hooks_file.display());
    let mut kept = String::new();
    let mut inside = false;
    for line in config.split_inclusive('\n') {
        if line.starts_with("[hooks.state.\"") {
            inside = line.starts_with(&wanted);
        } else if line.starts_with('[') {
            inside = false;
        }
        if inside {
            kept.push_str(line);
        }
    }
    kept
}

#[cfg(unix)]
fn link_file(from: &Path, to: &Path) -> std::io::Result<()> {
    std::os::unix::fs::symlink(from, to)
}

#[cfg(windows)]
fn link_file(from: &Path, to: &Path) -> std::io::Result<()> {
    fs::copy(from, to).map(|_| ())
}

fn codex_session(
    dir: &Path,
    root: &Path,
    hook_binary: Option<&Path>,
    deps: &InjectDeps,
) -> std::io::Result<Made> {
    fs::create_dir_all(dir)?;
    let real = deps.environment.home.join(".codex");
    // The login of the user's own Codex.
    let auth = dir.join("auth.json");
    let _ = fs::remove_file(&auth);
    if real.join("auth.json").is_file() {
        link_file(&real.join("auth.json"), &auth)?;
    }

    // The user's settings, with the trust given to this home's hooks as it was.
    let hooks_file = dir.join("hooks.json");
    let before = fs::read_to_string(dir.join("config.toml")).unwrap_or_default();
    let users = fs::read_to_string(real.join("config.toml")).unwrap_or_default();
    let kept = trust_blocks(&before, &hooks_file);
    let separator = if users.ends_with('\n') || users.is_empty() {
        ""
    } else {
        "\n"
    };
    let tail = if kept.is_empty() {
        String::new()
    } else {
        format!("\n{kept}")
    };
    fs::write(dir.join("config.toml"), format!("{users}{separator}{tail}"))?;

    let skills = dir.join("skills");
    reset_dir(&deps.data_dir, &skills)?;
    copy_skills(&root.join("skills"), &skills)?;
    copy_codex_skills(root, &skills)?;
    if let Some(hook) = hook_binary {
        let hooks = render_hooks(&root.join("harness/codex/hooks.json"), &text(hook))?;
        fs::write(
            &hooks_file,
            serde_json::to_string_pretty(&hooks).unwrap_or_default() + "\n",
        )?;
    } else {
        let _ = fs::remove_file(&hooks_file);
    }
    Ok(Made {
        args: vec![],
        env: BTreeMap::from([
            ("CODEX_HOME".into(), text(dir)),
            ("SYNAPSE_CONTENT_ROOT".into(), text(root)),
        ]),
    })
}

fn opencode_session(
    dir: &Path,
    root: &Path,
    hook_binary: Option<&Path>,
    data_dir: &Path,
) -> std::io::Result<Made> {
    for sub in ["skill", "command", "plugin"] {
        reset_dir(data_dir, &dir.join(sub))?;
    }
    copy_skills(&root.join("skills"), &dir.join("skill"))?;
    copy_codex_skills(root, &dir.join("skill"))?;
    copy_commands(&root.join("commands"), &dir.join("command"))?;
    if let Some(hook) = hook_binary {
        let template = fs::read_to_string(root.join("harness/opencode/plugin/synapse.js"))?;
        let literal = serde_json::to_string(&slashed(&text(hook))).unwrap_or_default();
        fs::write(
            dir.join("plugin/synapse.js"),
            template.replace("\"__SYNAPSE_HOOK_BIN__\"", &literal),
        )?;
    }
    Ok(Made {
        args: vec![],
        env: BTreeMap::from([
            ("OPENCODE_CONFIG_DIR".into(), text(dir)),
            ("SYNAPSE_CONTENT_ROOT".into(), text(root)),
        ]),
    })
}

/// How to start the harness for one session.
pub fn plan_session(harness: Harness, deps: &InjectDeps) -> std::io::Result<SessionPlan> {
    let command = command_of(harness).to_string();
    let label = label_of(harness);
    if is_installed(harness, &deps.environment.home) {
        return Ok(SessionPlan {
            command,
            args: vec![],
            env: BTreeMap::new(),
            loaded: false,
            note: format!("Synapse is installed in {label} and is used as it is."),
        });
    }
    let Some(root) = find_content_root(&deps.environment, &deps.bundled_roots) else {
        return Ok(SessionPlan {
            command,
            args: vec![],
            env: BTreeMap::new(),
            loaded: false,
            note: format!("The Synapse content was not found, so this is {label} as it is."),
        });
    };
    let hook_binary = find_executable(HOOK_NAME, path_variable(&deps.environment));
    let dir = deps.data_dir.join(name_of(harness));
    fs::create_dir_all(&dir)?;
    let made = match harness {
        Harness::Claude => claude_session(&dir, &root, hook_binary.as_deref(), &deps.data_dir)?,
        Harness::Codex => codex_session(&dir, &root, hook_binary.as_deref(), deps)?,
        Harness::Opencode => opencode_session(&dir, &root, hook_binary.as_deref(), &deps.data_dir)?,
    };
    let hooks = if hook_binary.is_none() {
        format!(" Its hooks are not loaded: {HOOK_NAME} was not found.")
    } else {
        String::new()
    };
    let trust = if harness == Harness::Codex && hook_binary.is_some() {
        " Codex asks you to trust the hooks the first time."
    } else {
        ""
    };
    Ok(SessionPlan {
        command,
        args: made.args,
        env: made.env,
        loaded: true,
        note: format!(
            "Synapse is loaded for this session only and nothing is installed in {label}.{hooks}{trust}"
        ),
    })
}

// ---------------------------------------------------------------------------------------------
// The login shell, with the harnesses wrapped
// ---------------------------------------------------------------------------------------------

fn quoted(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

/// Escapes backslashes and quotes for a JSON string written by a shell script.
const JSON_ESCAPE: &str = r#"sed 's/\\/\\\\/g; s/"/\\"/g'"#;

/// What a wrapper writes when it starts a session whose conversation is followed: one file in the
/// folder SYNAPSE_SESSIONS_DIR names, which the app reads. A new session is given an id of the
/// wrapper's choosing, so that the file is known before it exists; so is a resumed one that is forked,
/// which Claude allows. A session resumed by its id keeps that id, and its file is the one followed. A
/// session resumed without one (`--continue`, the picker, a name) is written down with no id, and the
/// app finds its file by where and when it was written.
fn claude_tracking() -> String {
    r#"track=""
if [ -n "$SYNAPSE_SESSIONS_DIR" ]; then
  skip=""
  case "$1" in
    mcp|plugin|plugins|config|doctor|update|install|setup-token|migrate-installer|auth|agents|api-key|help) skip=1 ;;
  esac
  case " $* " in
    *" -p "*|*" --print"*|*" --version"*|*" -v "*|*" --help"*|*" -h "*) skip=1 ;;
  esac
  resumed=""
  named=""
  given=""
  fork=""
  after=""
  for arg in "$@"; do
    case "$after" in
      resume) case "$arg" in -*) ;; *) named=$arg ;; esac ;;
      id) given=$arg ;;
    esac
    after=""
    case "$arg" in
      -r|--resume) resumed=1; after=resume ;;
      --resume=*) resumed=1; named=${arg#--resume=} ;;
      -c|--continue|--from-pr|--from-pr=*) resumed=1 ;;
      --fork-session) fork=1 ;;
      --session-id) after=id ;;
      --session-id=*) given=${arg#--session-id=} ;;
    esac
  done
  if [ -z "$skip" ]; then
    id=""
    name=""
    if [ -n "$given" ]; then
      id=$given
    elif [ -n "$resumed" ] && [ -z "$fork" ]; then
      id=$(printf %s "$named" | tr 'A-Z' 'a-z' | grep -Ex '[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}')
      name=$$
    else
      id=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null)
      id=$(printf %s "$id" | tr 'A-Z' 'a-z')
      [ -n "$id" ] && track="--session-id $id"
    fi
    if [ -n "$id" ] || [ -n "$name" ]; then
      field=""
      if [ -n "$id" ]; then
        name=$(printf %s "$id" | tr -c 'A-Za-z0-9-' '_')
        field=$(printf '"sessionId":"%s",' "$(printf %s "$id" | @JSON_ESCAPE@)")
      fi
      cwd=$(pwd | @JSON_ESCAPE@)
      cfg=$(printf %s "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" | @JSON_ESCAPE@)
      mkdir -p "$SYNAPSE_SESSIONS_DIR" 2>/dev/null
      printf '{"harness":"claude",%s"cwd":"%s","configDir":"%s","startedAt":%s000}\n' "$field" "$cwd" "$cfg" "$(date +%s)" > "$SYNAPSE_SESSIONS_DIR/.claude-$name.tmp" && mv "$SYNAPSE_SESSIONS_DIR/.claude-$name.tmp" "$SYNAPSE_SESSIONS_DIR/claude-$name.json"
    fi
  fi
fi
"#
    .replace("@JSON_ESCAPE@", JSON_ESCAPE)
}

/// Codex has no way to be given a session id, so it is found by where and when it started. A run that
/// is a command and not a session is not followed.
fn codex_tracking() -> String {
    r#"if [ -n "$SYNAPSE_SESSIONS_DIR" ]; then
  case "$1" in
    exec|e|review|login|logout|mcp|plugin|app-server|completion|update|doctor|sandbox|debug|apply|features|help|cloud) ;;
    *)
      cwd=$(pwd | @JSON_ESCAPE@)
      home=$(printf %s "${CODEX_HOME:-$HOME/.codex}" | @JSON_ESCAPE@)
      mkdir -p "$SYNAPSE_SESSIONS_DIR" 2>/dev/null
      printf '{"harness":"codex","cwd":"%s","home":"%s","startedAt":%s000}\n' "$cwd" "$home" "$(date +%s)" > "$SYNAPSE_SESSIONS_DIR/.codex-$$.tmp" && mv "$SYNAPSE_SESSIONS_DIR/.codex-$$.tmp" "$SYNAPSE_SESSIONS_DIR/codex-$$.json"
      ;;
  esac
fi
"#
    .replace("@JSON_ESCAPE@", JSON_ESCAPE)
}

/// OpenCode creates the session it is given with `--session` when there is none of that id, so the
/// wrapper chooses the id, as it does for Claude, and the conversation is found by it. A first
/// argument that is not a flag is a command or a folder, and a run that names or continues a session
/// of its own is not followed.
fn opencode_tracking() -> String {
    r#"track=""
if [ -n "$SYNAPSE_SESSIONS_DIR" ]; then
  skip=""
  case "$1" in
    -*|"") ;;
    *) skip=1 ;;
  esac
  case " $* " in
    *" -s "*|*" --session"*|*" -c "*|*" --continue"*|*" --server"*|*" --version"*|*" -v "*|*" --help"*|*" -h "*|*" --completions"*|*" --wizard"*) skip=1 ;;
  esac
  if [ -z "$skip" ]; then
    id=ses_$(od -An -N10 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    if [ "$id" != "ses_" ]; then
      track="--session $id"
      cwd=$(pwd | @JSON_ESCAPE@)
      mkdir -p "$SYNAPSE_SESSIONS_DIR" 2>/dev/null
      printf '{"harness":"opencode","sessionId":"%s","cwd":"%s","startedAt":%s000}\n' "$id" "$cwd" "$(date +%s)" > "$SYNAPSE_SESSIONS_DIR/.opencode-$id.tmp" && mv "$SYNAPSE_SESSIONS_DIR/.opencode-$id.tmp" "$SYNAPSE_SESSIONS_DIR/opencode-$id.json"
    fi
  fi
fi
"#
    .replace("@JSON_ESCAPE@", JSON_ESCAPE)
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Tracking {
    Claude,
    Codex,
    Opencode,
}

/// A command that starts the next program of that name on PATH, after its own folder, with the
/// arguments and variables of a session plan added, and, for a harness whose conversation is followed,
/// a note of the run. PATH is the one of the shell it is started from, which is not known until then.
pub fn shim_script(name: &str, plan: &SessionPlan, tracking: Option<Tracking>) -> String {
    let exports: String = plan
        .env
        .iter()
        .map(|(key, value)| format!("    export {key}={}\n", quoted(value)))
        .collect();
    let args = plan
        .args
        .iter()
        .map(|a| quoted(a))
        .collect::<Vec<_>>()
        .join(" ");
    let before = match tracking {
        Some(Tracking::Claude) => claude_tracking(),
        Some(Tracking::Opencode) => opencode_tracking(),
        _ => String::new(),
    };
    // Codex notes where it will keep its sessions, which the variables decide.
    let after = if tracking == Some(Tracking::Codex) {
        codex_tracking()
            .split('\n')
            .map(|line| format!("    {line}"))
            .collect::<Vec<_>>()
            .join("\n")
    } else {
        String::new()
    };
    let typed = if matches!(tracking, Some(Tracking::Claude | Tracking::Opencode)) {
        "$track \"$@\""
    } else {
        "\"$@\""
    };
    let space = if args.is_empty() { "" } else { " " };
    format!(
        "#!/bin/sh\n# Starts the next {name} on PATH with the bundled Synapse loaded for this session.\n{before}self=$(cd \"$(dirname \"$0\")\" && pwd)\nold=$IFS\nIFS=:\nfor dir in $PATH; do\n  [ \"$dir\" = \"$self\" ] && continue\n  if [ -f \"$dir/{name}\" ] && [ -x \"$dir/{name}\" ]; then\n    IFS=$old\n{exports}{after}    exec \"$dir/{name}\" {args}{space}{typed}\n  fi\ndone\nIFS=$old\necho \"{name}: command not found\" >&2\nexit 127\n"
    )
}

/// Names as prose: "a", "a or b", "a, b or c".
fn or_list(names: &[String]) -> String {
    match names.split_last() {
        None => String::new(),
        Some((last, [])) => last.clone(),
        Some((last, rest)) => format!("{} or {last}", rest.join(", ")),
    }
}

/// zsh reads its files from ZDOTDIR. These read the user's own, and then put the folder of the
/// commands first on PATH again, whatever the user's files did to it.
const ZSH_FILES: [&str; 4] = [".zshenv", ".zprofile", ".zshrc", ".zlogin"];

fn zsh_file(name: &str) -> String {
    let user =
        format!("[ -f \"$SYNAPSE_USER_ZDOTDIR/{name}\" ] && . \"$SYNAPSE_USER_ZDOTDIR/{name}\"");
    if name != ".zshrc" {
        return format!("{user}\n");
    }
    format!(
        "{user}\nif [ -n \"$SYNAPSE_SHIM_DIR\" ]; then\n  path=(\"$SYNAPSE_SHIM_DIR\" ${{path:#\"$SYNAPSE_SHIM_DIR\"}})\nfi\n"
    )
}

/// How to start the user's login shell: the plan, and the programs that start with Synapse loaded.
#[derive(Clone, Debug)]
pub struct ShellPlan {
    pub plan: SessionPlan,
    pub wrapped: Vec<String>,
}

/// How to start the user's login shell. `claude`, `codex` and `opencode` typed in it load the bundled
/// Synapse for that run, unless it is installed.
pub fn plan_shell(deps: &InjectDeps) -> std::io::Result<ShellPlan> {
    let env = &deps.environment;
    let shell = env.var("SHELL").map(String::from).unwrap_or_else(|| {
        if cfg!(target_os = "macos") {
            "/bin/zsh".into()
        } else {
            "/bin/sh".into()
        }
    });
    let plain = |note: &str| ShellPlan {
        plan: SessionPlan {
            command: shell.clone(),
            args: strings(&["-l"]),
            env: BTreeMap::new(),
            loaded: false,
            note: note.into(),
        },
        wrapped: vec![],
    };
    if cfg!(windows) {
        return Ok(plain("Your shell."));
    }

    let mut wrapped: Vec<(String, SessionPlan, Option<Tracking>)> = Vec::new();
    for harness in [Harness::Claude, Harness::Codex, Harness::Opencode] {
        let plan = plan_session(harness, deps)?;
        // Every harness is wrapped to follow its conversation, whether or not Synapse is loaded into it.
        let tracking = match harness {
            Harness::Claude => Tracking::Claude,
            Harness::Codex => Tracking::Codex,
            Harness::Opencode => Tracking::Opencode,
        };
        wrapped.push((plan.command.clone(), plan, Some(tracking)));
    }
    if wrapped.is_empty() {
        return Ok(plain("Your login shell."));
    }

    let shims = deps.data_dir.join("shims");
    reset_dir(&deps.data_dir, &shims)?;
    for (name, plan, tracking) in &wrapped {
        let file = shims.join(name);
        fs::write(&file, shim_script(name, plan, *tracking))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&file, fs::Permissions::from_mode(0o755))?;
        }
    }
    let mut vars: BTreeMap<String, String> = BTreeMap::from([
        (
            "PATH".into(),
            join_paths(
                &[text(&shims), path_variable(env).to_string()]
                    .iter()
                    .filter(|p| !p.is_empty())
                    .collect::<Vec<_>>(),
            ),
        ),
        ("SYNAPSE_SHIM_DIR".into(), text(&shims)),
    ]);
    if Path::new(&shell).file_name().is_some_and(|n| n == "zsh") {
        let zdotdir = deps.data_dir.join("zdotdir");
        reset_dir(&deps.data_dir, &zdotdir)?;
        for name in ZSH_FILES {
            fs::write(zdotdir.join(name), zsh_file(name))?;
        }
        // A shell of the app started from one of its own shells has the app's ZDOTDIR, whose files
        // would read themselves; the user's own folder is the one that shell was given.
        let user = env
            .var("SYNAPSE_USER_ZDOTDIR")
            .or_else(|| env.var("ZDOTDIR"))
            .map(String::from)
            .unwrap_or_else(|| text(&env.home));
        vars.insert("SYNAPSE_USER_ZDOTDIR".into(), user);
        vars.insert("ZDOTDIR".into(), text(&zdotdir));
    }
    let names: Vec<String> = wrapped
        .iter()
        .filter(|(_, p, _)| p.loaded)
        .map(|(n, _, _)| n.clone())
        .collect();
    let followed: Vec<String> = wrapped
        .iter()
        .filter(|(_, _, t)| t.is_some())
        .map(|(n, _, _)| n.clone())
        .collect();
    let loads = if names.is_empty() {
        String::new()
    } else {
        format!(
            " {} started here load Synapse for that run only and nothing is installed.",
            names.join(", ")
        )
    };
    Ok(ShellPlan {
        plan: SessionPlan {
            command: shell,
            args: strings(&["-l"]),
            env: vars,
            loaded: !names.is_empty(),
            note: format!(
                "Your login shell.{loads} The conversation of a {} started here shows in the Activity tab of the Changes sidebar.",
                or_list(&followed)
            ),
        },
        wrapped: names,
    })
}
