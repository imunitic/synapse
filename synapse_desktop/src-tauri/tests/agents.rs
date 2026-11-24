//! Having an agent write for the person: a definition, a note, a change to a note. The same cases as
//! the Node host's `generate.test.ts`, `note-agent.test.ts`, `note-edit.test.ts` and `note-call.test.ts`.

mod support;

use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::fs;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use support::environment;
use synapse_desktop_host::agents::{
    agent_command, created_path, edit_note, edit_prompt, failure_of, find_pipeline_skill,
    folder_sentence, generate_text, note_command, note_path_problem, note_prompt, note_tools,
    opencode_permission, paths_of, prompt_for, reason_of, reference_from, restore_note,
    session_prompt, stream_result, system_for, text_of, touched_elsewhere, vault_dir_of,
    AgentChoice, AgentRun, AgentRunner, GenerateRequest, NoteSession, NoteSessionRun, Seen,
};
use synapse_desktop_host::cli::{CliRun, CliRunner};
use synapse_desktop_host::dispatch::{serve, Handlers, ServeOptions};
use synapse_desktop_host::families::{agent_families, first_families, next_families, Context};
use synapse_desktop_host::inject::SessionPlan;
use synapse_desktop_host::link::{link_pair, ClientLink};
use synapse_desktop_host::messages::{
    AppConfig, CliResult, DefinitionDraftKind, DefinitionKind, DefinitionName, Harness, NoteKind,
    Project,
};
use synapse_desktop_host::models::ModelStore;
use synapse_desktop_host::note_runs::NoteRuns;
use synapse_desktop_host::protocol::{
    Capabilities, ClientMessage, ErrorCode, HostKind, HostMessage,
};
use synapse_desktop_host::status::{LoginPath, VersionOf};
use tempfile::{tempdir, TempDir};

// ---------------------------------------------------------------------------------------------
// What the agent is given
// ---------------------------------------------------------------------------------------------

const SKILL: &str = "---\nname: synapse-pipeline\n---\n# synapse-pipeline\n## Crafting a pipeline\nsteps about files\n## Definitions\nA definition file has the extension .synapse.\n## Results and routing\nOutcomes route.\n## Trying a pipeline without agents\nscripted";

fn reviewer() -> Vec<DefinitionName> {
    vec![DefinitionName {
        name: "Reviewer".into(),
        kind: DefinitionDraftKind::Agent,
    }]
}

fn skills() -> Vec<String> {
    vec!["review-code".into()]
}

fn request<'a>(
    kind: DefinitionKind,
    definitions: &'a [DefinitionName],
    skills: &'a [String],
    current: Option<&'a str>,
) -> GenerateRequest<'a> {
    GenerateRequest {
        kind,
        prompt: "  Build, then review.  ",
        current,
        definitions,
        skills,
    }
}

#[test]
fn the_agent_is_given_the_reference_part_of_the_skill_and_not_the_steps_about_files() {
    let (d, s) = (reviewer(), skills());
    let system = system_for(&request(DefinitionKind::Pipeline, &d, &s, None), SKILL).unwrap();
    assert!(system.contains("A definition file has the extension .synapse."));
    assert!(system.contains("Outcomes route."));
    assert!(!system.contains("steps about files") && !system.contains("scripted"));
}

#[test]
fn what_exists_is_named_so_that_it_is_reused_and_its_names_are_not_taken() {
    let (d, s) = (reviewer(), skills());
    let prompt = prompt_for(&request(DefinitionKind::Pipeline, &d, &s, None));
    assert!(prompt.contains("Build, then review."));
    assert!(prompt.contains("- agent Reviewer"));
    let skill = prompt_for(&request(DefinitionKind::Skill, &d, &s, None));
    assert!(skill.contains("review-code") && !skill.contains("Reviewer"));
}

#[test]
fn a_revision_is_given_the_current_text_and_asked_for_as_a_change_not_a_new_definition() {
    let (d, s) = (reviewer(), skills());
    let asked = request(DefinitionKind::Pipeline, &d, &s, Some("Pipeline P {}\n"));
    assert!(prompt_for(&asked).contains("Change this pipeline"));
    assert!(prompt_for(&asked).contains("The current text:\n\nPipeline P {}"));
    assert!(prompt_for(&request(DefinitionKind::Pipeline, &d, &s, None))
        .contains("Write a new pipeline"));
    assert!(system_for(&asked, SKILL).unwrap().contains("same name"));
    assert!(
        !system_for(&request(DefinitionKind::Pipeline, &d, &s, None), SKILL)
            .unwrap()
            .contains("same name")
    );
}

#[test]
fn a_skill_needs_no_skill_file_and_a_layout_that_is_not_known_is_refused() {
    let (d, s) = (reviewer(), skills());
    assert!(
        system_for(&request(DefinitionKind::Skill, &d, &s, None), "")
            .unwrap()
            .contains("SKILL.md")
    );
    assert!(reference_from("# nothing here")
        .unwrap_err()
        .message
        .contains("layout"));
}

#[test]
fn the_headings_are_in_the_skill_that_ships_with_the_program() {
    let real = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../packages/synapse-pipeline/skills/synapse-pipeline/SKILL.md");
    let text = fs::read_to_string(real).unwrap();
    assert!(reference_from(&text)
        .unwrap()
        .contains("## Results and routing"));
}

fn run(harness: Harness, model: Option<&str>) -> AgentRun {
    AgentRun {
        env: BTreeMap::new(),
        harness,
        model: model.map(String::from),
        system: "RULES".into(),
        prompt: "ASK".into(),
        stop: None,
    }
}

#[test]
fn claude_gets_the_instructions_as_a_system_prompt_and_no_tools() {
    let made = agent_command(&run(Harness::Claude, None));
    assert_eq!(made.program, "claude");
    let at = made.args.iter().position(|a| a == "--tools").unwrap();
    assert_eq!(made.args[at + 1], "");
    let at = made
        .args
        .iter()
        .position(|a| a == "--append-system-prompt")
        .unwrap();
    assert_eq!(made.args[at + 1], "RULES");
    assert_eq!(made.stdin, "ASK");
}

#[test]
fn codex_gets_the_instructions_before_the_prompt_in_a_read_only_sandbox() {
    let made = agent_command(&run(Harness::Codex, None));
    assert_eq!(
        made.args,
        [
            "exec",
            "--ephemeral",
            "--skip-git-repo-check",
            "-s",
            "read-only"
        ]
    );
    assert_eq!(made.stdin, "RULES\n\nASK");
}

#[test]
fn opencode_is_denied_every_tool_that_changes_or_reaches_out() {
    let made = agent_command(&run(Harness::Opencode, None));
    assert_eq!(made.args.last().unwrap(), "RULES\n\nASK");
    let given: Value = serde_json::from_str(&made.env["OPENCODE_CONFIG_CONTENT"]).unwrap();
    assert_eq!(
        given,
        json!({ "permission": { "edit": "deny", "bash": "deny", "webfetch": "deny", "external_directory": "deny" } })
    );
}

#[test]
fn the_model_of_a_headless_session_is_given_by_the_flag_of_each_harness_and_else_left_to_it() {
    let model = Some("some/model");
    let claude = agent_command(&run(Harness::Claude, model)).args;
    assert_eq!(&claude[claude.len() - 2..], ["--model", "some/model"]);
    assert!(agent_command(&run(Harness::Codex, model))
        .args
        .windows(2)
        .any(|w| w == ["-m", "some/model"]));
    let opencode = agent_command(&run(Harness::Opencode, model)).args;
    assert_eq!(
        &opencode[..5],
        ["run", "--standalone", "--auto", "-m", "some/model"]
    );
    assert!(opencode.last().unwrap().contains("ASK"));
    for harness in [Harness::Claude, Harness::Codex, Harness::Opencode] {
        let args = agent_command(&run(harness, None)).args;
        assert!(!args.contains(&"--model".to_string()) && !args.contains(&"-m".to_string()));
    }
}

#[test]
fn a_code_fence_is_taken_off_a_reply_that_has_one() {
    assert_eq!(
        text_of("```synapse\nAgent A [Prompt => \"x\"];\n```\n"),
        "Agent A [Prompt => \"x\"];\n"
    );
    assert_eq!(
        text_of("Agent A [Prompt => \"x\"];"),
        "Agent A [Prompt => \"x\"];\n"
    );
}

#[test]
fn the_skill_is_read_from_the_package_the_launcher_on_path_belongs_to() {
    let dir = tempdir().unwrap();
    let pkg = dir.path().join("lib/pkg");
    fs::create_dir_all(pkg.join("bin")).unwrap();
    fs::create_dir_all(pkg.join("skills/synapse-pipeline")).unwrap();
    fs::write(pkg.join("bin/synapse-pipeline"), "").unwrap();
    fs::write(pkg.join("skills/synapse-pipeline/SKILL.md"), SKILL).unwrap();
    fs::create_dir(dir.path().join("bin")).unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(
        pkg.join("bin/synapse-pipeline"),
        dir.path().join("bin/synapse-pipeline"),
    )
    .unwrap();
    // A launcher without a skill beside it does not stop the search.
    fs::create_dir(dir.path().join("other")).unwrap();
    fs::write(dir.path().join("other/synapse-pipeline"), "").unwrap();
    let path = format!(
        "{}:{}",
        dir.path().join("other").display(),
        dir.path().join("bin").display()
    );
    #[cfg(unix)]
    assert_eq!(
        find_pipeline_skill(&environment(dir.path(), &[("PATH", &path)]), &[]).unwrap(),
        SKILL
    );
    // None says so.
    let none = find_pipeline_skill(&environment(dir.path(), &[("PATH", "")]), &[]).unwrap_err();
    assert!(none.message.contains("not found"));
    assert_eq!(none.code, ErrorCode::Conflict);
    let _ = path;
}

// ---------------------------------------------------------------------------------------------
// The prompt for a note
// ---------------------------------------------------------------------------------------------

fn p(name: &str, prefix: &str) -> Project {
    Project {
        name: name.into(),
        prefix: prefix.into(),
    }
}

#[test]
fn a_note_prompt_names_the_skill_of_the_kind_of_note_and_holds_the_description() {
    let note = note_prompt(
        NoteKind::Note,
        "  Why the cache is keyed by branch  ",
        Harness::Claude,
        &[],
        None,
    );
    assert!(note.contains("use the synapse-note skill in bare mode"));
    assert!(note.contains("Description:\nWhy the cache is keyed by branch"));
    for harness in [Harness::Claude, Harness::Codex, Harness::Opencode] {
        assert!(note_prompt(NoteKind::Task, "x", harness, &[], None)
            .contains("synapse-note skill with --task"));
        assert!(note_prompt(NoteKind::Design, "x", harness, &[], None)
            .contains("use the synapse-design-note skill"));
        assert!(note_prompt(NoteKind::Note, "x", harness, &[], None)
            .contains("use the synapse-note skill in bare mode"));
    }
}

#[test]
fn it_says_nobody_can_answer_which_commands_work_how_to_write_and_what_to_end_with() {
    let text = note_prompt(NoteKind::Note, "x", Harness::Claude, &[], None);
    for phrase in [
        "Nobody can answer questions",
        "Only these commands work in this session: synapse, ls, cat",
        "one command in each Bash call",
        "to note.md in the current folder",
        "`synapse vault-write <path> < note.md`",
        "`synapse vault-search < query.json`",
        "never as a here-document and never through cat, echo or <<<",
        "add the folder to Index.md",
        "path in the vault",
        "FAILED:",
    ] {
        assert!(text.contains(phrase), "{phrase}");
    }
}

#[test]
fn a_session_may_never_add_a_project_whichever_harness_writes_the_note() {
    for harness in [Harness::Claude, Harness::Codex, Harness::Opencode] {
        let text = note_prompt(NoteKind::Task, "x", harness, &[p("a", "b")], None);
        assert!(text.contains("Never add a project"));
        assert!(text.contains("so that the person can add one on the page"));
    }
}

#[test]
fn the_projects_there_are_are_listed_for_a_task_or_design_note_to_match_the_description_to() {
    let projects = [p("synapse", "sb"), p("eon", "ecs")];
    let task = note_prompt(NoteKind::Task, "x", Harness::Claude, &projects, None);
    assert!(task.contains("as name=prefix: synapse=sb, eon=ecs"));
    assert!(task.contains("is in tasks/NAME/ and has the project PREFIX"));
    assert!(task.contains("matching loosely"));
    assert!(
        note_prompt(NoteKind::Design, "x", Harness::Codex, &projects, None)
            .contains("designs/NAME/")
    );
    assert!(
        note_prompt(NoteKind::Task, "x", Harness::Claude, &[], None).contains("There are none.")
    );
}

#[test]
fn the_project_that_was_chosen_is_named_with_its_folder_and_prefix_and_no_other_is_asked_for() {
    let chosen = p("synapse", "sb");
    let text = note_prompt(
        NoteKind::Design,
        "x",
        Harness::Claude,
        &[chosen.clone(), p("eon", "ecs")],
        Some(&chosen),
    );
    assert!(text.contains("The project of this note is synapse, with the prefix sb"));
    assert!(text.contains("in designs/synapse/ and its project is sb"));
    assert!(!text.contains("eon=ecs") && !text.contains("Never add a project"));
    assert!(!note_prompt(
        NoteKind::Note,
        "x",
        Harness::Claude,
        &[p("synapse", "sb")],
        None
    )
    .contains("project"));
}

#[test]
fn the_commands_that_work_are_named_to_the_harnesses_held_to_them_and_not_to_codex() {
    assert!(
        note_prompt(NoteKind::Note, "x", Harness::Opencode, &[], None)
            .contains("Only these commands work")
    );
    let codex = note_prompt(NoteKind::Note, "x", Harness::Codex, &[], None);
    assert!(!codex.contains("Only these commands work"));
    assert!(codex.contains("on standard input as a here-document"));
    // Claude Code writes a new note to a file, since a command with the whole note is refused.
    let claude = note_prompt(NoteKind::Note, "x", Harness::Claude, &[], None);
    assert!(!claude.contains("Give a note's text to `synapse vault-write <path>`"));
    for other in [
        &codex,
        &note_prompt(NoteKind::Note, "x", Harness::Opencode, &[], None),
    ] {
        assert!(other.contains("Give a note's text to `synapse vault-write <path>`"));
        assert!(!other.contains("note.md"));
    }
    assert!(edit_prompt("a.md", "x", Harness::Claude).contains("Only these commands work"));
    assert!(!edit_prompt("a.md", "x", Harness::Codex).contains("Only these commands work"));
}

#[test]
fn the_prompt_to_change_a_note_keeps_what_was_not_asked_about_and_says_what_to_end_with() {
    let text = edit_prompt("tasks/p/Work.md", "tick the first item", Harness::Claude);
    for phrase in [
        "keeping every frontmatter field, section, link and line you were not asked to change",
        "Never change `schema`, `note_id`, `task_id`, `created` or `project`",
        "synapse-task skill",
        "end your reply with the line EDITED",
        "FAILED:",
    ] {
        assert!(text.contains(phrase), "{phrase}");
    }
}

#[test]
fn claude_code_is_told_to_change_a_copy_of_the_note_in_its_folder_and_the_others_to_give_it_on_standard_input(
) {
    let text = edit_prompt("tasks/p/Work.md", "x", Harness::Claude);
    for phrase in [
        "`synapse vault-read <path> > note.md`",
        "with the Edit tool",
        "`synapse vault-write <path> < note.md`",
    ] {
        assert!(text.contains(phrase), "{phrase}");
    }
    assert!(!text.contains("Give a note's text to `synapse vault-write <path>`"));
    for harness in [Harness::Opencode, Harness::Codex] {
        assert!(edit_prompt("a.md", "x", harness).contains("on standard input as a here-document"));
    }
}

// ---------------------------------------------------------------------------------------------
// The headless session for a note
// ---------------------------------------------------------------------------------------------

fn plan(command: &str, args: &[&str], env: &[(&str, &str)]) -> SessionPlan {
    SessionPlan {
        command: command.into(),
        args: args.iter().map(|a| a.to_string()).collect(),
        env: env
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect(),
        loaded: true,
        note: String::new(),
    }
}

fn claude_plan() -> SessionPlan {
    plan(
        "claude",
        &["--add-dir", "/overlay", "--settings", "/settings.json"],
        &[],
    )
}

fn arg_after(args: &[String], flag: &str) -> String {
    let at = args.iter().position(|a| a == flag).unwrap();
    args[at + 1].clone()
}

#[test]
fn claude_reads_the_prompt_from_standard_input_refuses_what_is_not_allowed_and_loads_synapse() {
    let command = note_command(
        Harness::Claude,
        &claude_plan(),
        "the prompt",
        &["/vault".into()],
        None,
        false,
    );
    assert_eq!(command.stdin, "the prompt");
    for flag in [
        "-p",
        "--permission-mode",
        "dontAsk",
        "--no-session-persistence",
    ] {
        assert!(command.args.contains(&flag.to_string()), "{flag}");
    }
    assert_eq!(
        &command.args[command.args.len() - 4..],
        ["--add-dir", "/overlay", "--settings", "/settings.json"]
    );
    // The tools are one argument, so that no flag can be taken into them.
    assert_eq!(arg_after(&command.args, "--allowedTools"), note_tools());
}

#[test]
fn it_may_also_read_the_synapse_package_folder_when_it_is_loaded_for_the_session() {
    let loaded = plan("claude", &[], &[("SYNAPSE_CONTENT_ROOT", "/pkg/synapse")]);
    let command = note_command(Harness::Claude, &loaded, "p", &[], None, false);
    assert_eq!(
        arg_after(&command.args, "--allowedTools"),
        format!("{},Read(/pkg/synapse/**)", note_tools())
    );
}

#[test]
fn the_tools_are_the_skills_the_synapse_program_and_reading_the_lists_and_no_shell() {
    let tools = note_tools();
    let tools: Vec<&str> = tools.split(',').collect();
    assert!(tools.contains(&"Skill") && tools.contains(&"Bash(synapse *)"));
    assert!(tools.contains(&"Read(~/.config/synapse/**)"));
    assert!(!tools.iter().any(|t| *t == "Bash" || *t == "Write"));
}

#[test]
fn a_session_may_add_to_the_tag_vocabulary_and_to_no_other_list_and_edit_the_files_of_its_own_folder(
) {
    let tools = note_tools();
    let edits: Vec<&str> = tools
        .split(',')
        .filter(|t| t.starts_with("Edit("))
        .collect();
    assert_eq!(
        edits,
        [
            "Edit(~/.config/synapse/synapse-tag-vocabulary.conf)",
            "Edit(~/.claude/synapse-tag-vocabulary.conf)",
            // Relative to the session's folder, which is empty and its own.
            "Edit(./**)"
        ]
    );
    assert!(!edits.iter().any(|e| e.contains("projects")));
    // The only pattern that reaches files is the one inside the session's own folder.
    assert_eq!(
        edits.iter().filter(|e| e.contains("**")).count(),
        1,
        "{edits:?}"
    );
    let permission = opencode_permission();
    let allowed: Vec<&str> = permission["edit"]
        .as_object()
        .unwrap()
        .iter()
        .filter(|(_, v)| *v == "allow")
        .map(|(k, _)| k.as_str())
        .collect::<Vec<_>>()
        .into_iter()
        .collect();
    assert_eq!(
        allowed,
        [
            "~/.config/synapse/synapse-tag-vocabulary.conf",
            "~/.claude/synapse-tag-vocabulary.conf"
        ]
    );
}

#[test]
fn codex_gets_the_prompt_on_standard_input_its_sandbox_and_the_folders_it_may_write_in() {
    let command = note_command(
        Harness::Codex,
        &plan("codex", &[], &[]),
        "the prompt",
        &["/vault".into(), "/cfg".into()],
        None,
        false,
    );
    assert_eq!(command.stdin, "the prompt");
    assert_eq!(
        &command.args[..3],
        ["exec", "--ephemeral", "--skip-git-repo-check"]
    );
    assert!(command
        .args
        .windows(2)
        .any(|w| w == ["-s", "workspace-write"]));
    // The sandbox never asks: a request would have nobody to answer it.
    assert!(command
        .args
        .contains(&"approval_policy=\"never\"".to_string()));
    let added: Vec<&String> = command
        .args
        .windows(2)
        .filter(|w| w[0] == "--add-dir")
        .map(|w| &w[1])
        .collect();
    assert_eq!(added, ["/vault", "/cfg"]);
    assert_eq!(command.args.last().unwrap(), "-");
    assert!(!command.args.contains(&"danger-full-access".to_string()));
}

#[test]
fn opencode_gets_the_prompt_as_its_message_and_is_held_to_the_commands_that_are_allowed() {
    let command = note_command(
        Harness::Opencode,
        &plan("opencode", &[], &[]),
        "the prompt",
        &["/vault".into()],
        None,
        false,
    );
    assert_eq!(command.stdin, "");
    assert_eq!(
        command.args,
        ["run", "--standalone", "--auto", "the prompt"]
    );
    let given: Value = serde_json::from_str(&command.env["OPENCODE_CONFIG_CONTENT"]).unwrap();
    let permission = &given["permission"];
    assert_eq!(permission["bash"]["*"], "deny");
    assert_eq!(permission["bash"]["synapse *"], "allow");
    assert_eq!(permission["bash"]["cat *"], "allow");
    assert_eq!(permission["edit"]["*"], "deny");
    assert_eq!(permission["webfetch"], "deny");
}

#[test]
fn the_model_of_a_note_session_is_given_by_the_flag_of_each_harness_before_what_ends_the_arguments()
{
    let claude = note_command(
        Harness::Claude,
        &claude_plan(),
        "p",
        &["/v".into()],
        Some("sonnet"),
        false,
    )
    .args;
    assert_eq!(&claude[claude.len() - 2..], ["--model", "sonnet"]);
    let codex = note_command(
        Harness::Codex,
        &plan("codex", &[], &[]),
        "p",
        &["/v".into()],
        Some("gpt-x"),
        false,
    )
    .args;
    assert_eq!(&codex[codex.len() - 3..], ["-m", "gpt-x", "-"]);
    let opencode = note_command(
        Harness::Opencode,
        &plan("opencode", &[], &[]),
        "the prompt",
        &["/v".into()],
        Some("prov/model"),
        false,
    )
    .args;
    assert_eq!(
        &opencode[opencode.len() - 3..],
        ["-m", "prov/model", "the prompt"]
    );
    for harness in [Harness::Claude, Harness::Codex, Harness::Opencode] {
        let args = note_command(harness, &claude_plan(), "p", &["/v".into()], None, false).args;
        assert!(!args.contains(&"--model".to_string()) && !args.contains(&"-m".to_string()));
    }
}

// ---------------------------------------------------------------------------------------------
// What the session left
// ---------------------------------------------------------------------------------------------

#[test]
fn the_vault_is_the_value_of_synapse_vault_dir_and_nothing_when_there_is_none_or_it_is_not_json() {
    let listing = json!({ "settings": [{ "key": "OTHER", "value": "x" }, { "key": "SYNAPSE_VAULT_DIR", "value": "/the/vault" }] });
    assert_eq!(
        vault_dir_of(&listing.to_string()).as_deref(),
        Some("/the/vault")
    );
    assert_eq!(
        vault_dir_of(
            &json!({ "settings": [{ "key": "SYNAPSE_VAULT_DIR", "value": "" }] }).to_string()
        ),
        None
    );
    assert_eq!(vault_dir_of(&json!({ "settings": [] }).to_string()), None);
    assert_eq!(vault_dir_of("not json"), None);
}

fn set(items: &[&str]) -> BTreeSet<String> {
    items.iter().map(|s| s.to_string()).collect()
}

fn list(items: &[&str]) -> Vec<String> {
    items.iter().map(|s| s.to_string()).collect()
}

#[test]
fn the_note_the_agent_named_is_the_one_made_when_it_is_a_new_one_else_the_first_new_note() {
    let before = set(&["Index.md", "research/Old.md"]);
    let after = list(&[
        "Index.md",
        "research/Old.md",
        "research/Cache keys.md",
        "inbox/Other.md",
    ]);
    assert_eq!(
        created_path("done\nresearch/Cache keys.md\n", &before, &after).as_deref(),
        Some("research/Cache keys.md")
    );
    assert_eq!(
        created_path("done\n`research/Cache keys.md`", &before, &after).as_deref(),
        Some("research/Cache keys.md")
    );
    let after = list(&["Index.md", "research/Old.md", "inbox/Other.md"]);
    assert_eq!(
        created_path("all done", &before, &after).as_deref(),
        Some("inbox/Other.md")
    );
    assert_eq!(
        created_path("research/Old.md", &before, &after).as_deref(),
        Some("inbox/Other.md")
    );
}

#[test]
fn it_is_never_a_graph_node_and_nothing_when_nothing_is_new() {
    let before = set(&["Index.md", "research/Old.md"]);
    assert_eq!(
        created_path(
            "x",
            &before,
            &list(&["Index.md", "research/Old.md", "synapse/a@main/Node.md"])
        ),
        None
    );
    assert_eq!(
        created_path("x", &before, &list(&["Index.md", "research/Old.md"])),
        None
    );
}

#[test]
fn the_reason_is_what_the_agent_gave_whatever_the_harness_printed_besides() {
    assert_eq!(
        failure_of("thinking\nFAILED: no project prefix could be found\n").as_deref(),
        Some("no project prefix could be found")
    );
    assert_eq!(failure_of("research/Cache keys.md"), None);
    // Codex prints its banner, the prompt and its hooks on standard error, and the reply on standard output.
    let banner =
        "\u{1b}[1mworkdir:\u{1b}[0m /w\nuser\nChange one note...\nhello\ntokens used\n8,015\n";
    assert_eq!(reason_of("hello\n", banner), "hello");
    assert_eq!(
        reason_of("thinking\nFAILED: no such note\n", banner),
        "no such note"
    );
    // Nothing said: the end of standard error, without colours.
    assert_eq!(
        reason_of("", "\u{1b}[31mError:\u{1b}[0m the model refused\n"),
        "Error: the model refused"
    );
    assert_eq!(reason_of("  \n", ""), "");
    let long = format!("{}THE END", "x".repeat(1000));
    let reason = reason_of(&long, "");
    assert_eq!(reason.chars().count(), 300);
    assert!(reason.ends_with("THE END"));
    assert_eq!(
        paths_of("Index.md\n\nresearch/A.md\n"),
        ["Index.md", "research/A.md"]
    );
}

// ---------------------------------------------------------------------------------------------
// A note that may be changed
// ---------------------------------------------------------------------------------------------

#[test]
fn a_note_that_may_be_changed_is_named_by_its_path_is_a_md_file_and_is_no_graph_node() {
    for ok in ["research/A note.md", "Index.md", "synapse-notes/A.md"] {
        assert_eq!(note_path_problem(ok), None, "{ok}");
    }
    let says = |path: &str, text: &str| note_path_problem(path).unwrap_or("").contains(text);
    assert!(says("", "no such note"));
    assert!(says("/etc/passwd.md", "path in the vault"));
    assert!(says("C:/x.md", "path in the vault"));
    assert!(says("a/../../b.md", "path in the vault"));
    assert!(says("research/data.json", ".md file"));
    assert!(says("synapse/widget@main/Rendering.md", "code graph"));
}

#[test]
fn the_other_notes_that_moved_are_those_whose_date_changed_new_and_gone_and_never_the_note_itself()
{
    let seen = |stamps: &[(&str, &str)], paths: &[&str]| Seen {
        stamps: stamps
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect(),
        paths: set(paths),
    };
    let before = seen(
        &[("a.md", "1"), ("b.md", "1"), ("c.md", "1")],
        &["a.md", "b.md", "c.md", "old.md"],
    );
    let after = seen(
        &[("a.md", "2"), ("b.md", "1"), ("d.md", "9")],
        &["a.md", "b.md", "d.md", "new.md"],
    );
    assert_eq!(
        touched_elsewhere(&before, &after, "a.md"),
        ["c.md", "d.md", "new.md", "old.md"]
    );
    let before = seen(&[("a.md", "1"), ("b.md", "1")], &["a.md", "b.md"]);
    let after = seen(&[("a.md", "2"), ("b.md", "1")], &["a.md", "b.md"]);
    assert!(touched_elsewhere(&before, &after, "a.md").is_empty());
}

// ---------------------------------------------------------------------------------------------
// Through the host
// ---------------------------------------------------------------------------------------------

/// A vault of notes in memory, answering the programs the agent flows ask of it.
#[derive(Default)]
struct Vault {
    files: BTreeMap<String, String>,
    listings: VecDeque<String>,
    pairs: Vec<(String, String)>,
    vault: Option<String>,
    writes: Vec<String>,
    /// The fields set, as `path key value`.
    sets: Vec<String>,
    projects_down: bool,
}

/// What the fake agent does to the vault when it is run.
type Effect = Arc<Mutex<Option<Box<dyn Fn(&mut Vault) + Send>>>>;

struct Rig {
    dir: TempDir,
    client: ClientLink,
    next: u32,
    vault: Arc<Mutex<Vault>>,
    agent_runs: Arc<Mutex<Vec<AgentRun>>>,
    agent_answer: Arc<Mutex<CliResult>>,
    sessions: Arc<Mutex<Vec<NoteSessionRun>>>,
    session_answer: Arc<Mutex<CliResult>>,
    /// Run when the note session is, to change the vault as the agent would.
    session_effect: Effect,
    /// While set, a fake agent that was given a stop waits for it, and ends with code 143.
    hold: Arc<AtomicBool>,
    /// The lines a fake note session prints through `on_line`, when it was given one.
    session_lines: Arc<Mutex<Vec<String>>>,
    /// The registry of the host's runs.
    runs: NoteRuns,
}

fn ok(stdout: &str) -> CliResult {
    CliResult {
        code: 0,
        stdout: stdout.into(),
        stderr: String::new(),
    }
}

fn stopped_result() -> CliResult {
    CliResult {
        code: 143,
        stdout: String::new(),
        stderr: String::new(),
    }
}

fn note(updated: &str, body: &str) -> String {
    format!("---\nupdated: {updated}\n---\n{body}\n")
}

impl Rig {
    async fn new(vault: Vault) -> Rig {
        Rig::with_path(vault, "").await
    }

    /// A rig whose host has this PATH, where the launcher of the pipeline program is looked for.
    async fn with_path(vault: Vault, path: &str) -> Rig {
        let dir = tempdir().unwrap();
        let vault = Arc::new(Mutex::new(vault));
        let cli_vault = vault.clone();
        let file = dir
            .path()
            .join("synapse/synapse-projects.conf")
            .to_string_lossy()
            .to_string();
        let cli = CliRunner::new(move |run: CliRun| {
            let mut v = cli_vault.lock().unwrap();
            let result = match run.args[0].as_str() {
                "config" => {
                    let settings: Vec<Value> = v.vault.iter().map(|d| json!({ "key": "SYNAPSE_VAULT_DIR", "value": d })).collect();
                    ok(&json!({ "settings": settings }).to_string())
                }
                "projects" if v.projects_down => CliResult { code: 1, stdout: String::new(), stderr: "synapse: unknown subcommand 'projects'\n".into() },
                "projects" => ok(&json!({ "format": "synapse-projects/v1", "file": file, "projects": v.pairs.iter().map(|(n, p)| json!({ "name": n, "prefix": p })).collect::<Vec<_>>() }).to_string()),
                "vault-list" => {
                    let next = v.listings.pop_front();
                    match next {
                        Some(listing) => ok(&listing),
                        None => ok(&(v.files.keys().cloned().collect::<Vec<_>>().join("\n") + "\n")),
                    }
                }
                "vault-read" => match v.files.get(&run.args[1]) {
                    Some(text) => ok(text),
                    None => CliResult { code: 1, stdout: String::new(), stderr: "no such note".into() },
                },
                "vault-search" => {
                    let rows: Vec<String> = v
                        .files
                        .iter()
                        .filter_map(|(path, text)| {
                            text.lines().find_map(|l| l.strip_prefix("updated: ")).map(|stamp| format!("{path}\t{stamp}"))
                        })
                        .collect();
                    ok(&(rows.join("\n") + "\n"))
                }
                "frontmatter" if run.args.len() == 5 && run.args[1] == "set" => {
                    let (path, key, value) = (&run.args[2], &run.args[3], &run.args[4]);
                    match v.files.get(path).cloned() {
                        Some(text) => {
                            v.sets.push(format!("{path} {key} {value}"));
                            let changed: Vec<String> = text
                                .lines()
                                .map(|l| {
                                    if l.starts_with(&format!("{key}: ")) {
                                        format!("{key}: {value}")
                                    } else {
                                        l.to_string()
                                    }
                                })
                                .collect();
                            v.files.insert(path.clone(), changed.join("\n") + "\n");
                            ok("")
                        }
                        None => CliResult {
                            code: 1,
                            stdout: String::new(),
                            stderr: "no such note".into(),
                        },
                    }
                }
                "now" => ok("2026-11-16T20:00:00+01:00\n"),
                "vault-write" => {
                    v.writes.push(run.args[1].clone());
                    let text = run.stdin.clone().unwrap_or_default();
                    v.files.insert(run.args[1].clone(), text);
                    ok("")
                }
                _ => CliResult { code: 1, stdout: String::new(), stderr: format!("not expected: {:?}", run.args) },
            };
            async move { Ok(result) }
        });
        let agent_runs = Arc::new(Mutex::new(Vec::<AgentRun>::new()));
        let agent_answer = Arc::new(Mutex::new(ok("Agent A [Prompt => \"x\"];")));
        let (kept, answer) = (agent_runs.clone(), agent_answer.clone());
        let hold = Arc::new(AtomicBool::new(false));
        let agent_hold = hold.clone();
        let agent = AgentRunner::new(move |mut run| {
            let stop = run.stop.take();
            kept.lock().unwrap().push(run);
            let answer = answer.lock().unwrap().clone();
            let held = agent_hold.load(Ordering::SeqCst);
            async move {
                match stop {
                    Some(stop) if held => {
                        let _ = stop.await;
                        Ok(stopped_result())
                    }
                    _ => Ok(answer),
                }
            }
        });
        let sessions = Arc::new(Mutex::new(Vec::<NoteSessionRun>::new()));
        let session_answer = Arc::new(Mutex::new(ok("EDITED")));
        let session_effect: Effect = Arc::new(Mutex::new(None));
        let (kept, answer, effect, session_vault) = (
            sessions.clone(),
            session_answer.clone(),
            session_effect.clone(),
            vault.clone(),
        );
        let session_lines = Arc::new(Mutex::new(Vec::<String>::new()));
        let (session_hold, printed) = (hold.clone(), session_lines.clone());
        let note_session = NoteSession::new(move |mut run| {
            let stop = run.stop.take();
            if let Some(on_line) = &run.on_line {
                for line in printed.lock().unwrap().iter() {
                    on_line(line.clone());
                }
            }
            kept.lock().unwrap().push(run);
            if let Some(effect) = effect.lock().unwrap().as_ref() {
                effect(&mut session_vault.lock().unwrap());
            }
            let answer = answer.lock().unwrap().clone();
            let held = session_hold.load(Ordering::SeqCst);
            async move {
                match stop {
                    Some(stop) if held => {
                        let _ = stop.await;
                        Ok(stopped_result())
                    }
                    _ => Ok(answer),
                }
            }
        });
        let runs = NoteRuns::new();
        let env = environment(
            dir.path(),
            &[
                ("XDG_CONFIG_HOME", &dir.path().to_string_lossy()),
                ("MARK", "x"),
                ("PATH", path),
            ],
        );
        let context = Context {
            config_file: dir.path().join("config.json"),
            cli,
            login_path: LoginPath::new(|| async { None }),
            version_of: VersionOf::new(|_| async { None }),
            models: ModelStore::new(dir.path().join("models.json"), Arc::new(|| 0), |_| async {
                synapse_desktop_host::messages::ModelCatalog {
                    models: vec![],
                    note: None,
                    read_at: None,
                }
            }),
            agent,
            note_session,
            note_runs: runs.clone(),
            runs: synapse_desktop_host::runs::RunStarter::new(
                "synapse-pipeline",
                Default::default(),
            ),
            bundled_roots: vec![],
            environment: env,
        };
        let context = Arc::new(context);
        let mut handlers = Handlers::new();
        first_families(&mut handlers, context.clone());
        next_families(&mut handlers, context.clone());
        agent_families(&mut handlers, context);
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
        client.incoming.recv().await.unwrap();
        Rig {
            dir,
            client,
            next: 0,
            vault,
            agent_runs,
            agent_answer,
            sessions,
            session_answer,
            session_effect,
            hold,
            session_lines,
            runs,
        }
    }

    /// Sends an `agent.run`, waits until `started` says the run is going, stops it, and gives the answer
    /// of the run.
    async fn ask_stopping(
        &mut self,
        params: Value,
        started: impl Fn(&Rig) -> bool,
    ) -> Result<Value, (ErrorCode, String)> {
        self.hold.store(true, Ordering::SeqCst);
        let run = params["run"].as_str().unwrap().to_string();
        self.client
            .outgoing
            .send(ClientMessage::Request {
                id: "run".into(),
                name: "agent.run".into(),
                params,
            })
            .unwrap();
        for _ in 0..200 {
            if started(self) {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(10)).await;
        }
        assert!(started(self), "the run did not start");
        self.client
            .outgoing
            .send(ClientMessage::Request {
                id: "stop".into(),
                name: "agent.stop".into(),
                params: json!({ "run": run }),
            })
            .unwrap();
        let mut answer = None;
        let mut stopped = false;
        while answer.is_none() || !stopped {
            match self.client.incoming.recv().await.unwrap() {
                HostMessage::Reply { id, result, error } if id == "stop" => {
                    assert!(error.is_none());
                    assert_eq!(result, Some(Value::Null));
                    stopped = true;
                }
                HostMessage::Reply {
                    result: Some(result),
                    ..
                } => answer = Some(Ok(result)),
                HostMessage::Reply {
                    error: Some(error), ..
                } => answer = Some(Err((error.code, error.message))),
                other => panic!("not a reply: {other:?}"),
            }
        }
        answer.unwrap()
    }

    async fn ask(&mut self, name: &str, params: Value) -> Result<Value, (ErrorCode, String)> {
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
        match self.client.incoming.recv().await.unwrap() {
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

fn pipeline_path(dir: &Path) -> String {
    // A launcher on PATH with the skill beside it.
    let pkg = dir.join("pkg");
    fs::create_dir_all(pkg.join("bin")).unwrap();
    fs::create_dir_all(pkg.join("skills/synapse-pipeline")).unwrap();
    fs::write(pkg.join("bin/synapse-pipeline"), "").unwrap();
    fs::write(pkg.join("skills/synapse-pipeline/SKILL.md"), SKILL).unwrap();
    pkg.join("bin").to_string_lossy().to_string()
}

fn define(extra: Value) -> Value {
    let mut base = json!({
        "kind": "definition", "what": "pipeline", "prompt": "  Build, then review.  ",
        "definitions": [{ "name": "Reviewer", "kind": "agent" }], "skills": ["review-code"],
    });
    for (k, v) in extra.as_object().unwrap() {
        base[k] = v.clone();
    }
    base
}

#[tokio::test]
async fn a_definition_is_written_by_the_harness_named_else_the_default_harness_else_claude() {
    let mut rig = Rig::new(Vault::default()).await;
    // The skill is found on the PATH the host has, which the rig set empty: it is not found here.
    let missing = rig.ask("agent.run", define(json!({}))).await.unwrap_err();
    assert_eq!(missing.0, ErrorCode::Conflict);
    assert!(rig.agent_runs.lock().unwrap().is_empty());
}

#[tokio::test]
async fn it_answers_with_the_text_the_agent_wrote_and_names_what_it_was_given() {
    let dir = tempdir().unwrap();
    let path = pipeline_path(dir.path());
    let mut rig = Rig::with_path(Vault::default(), &path).await;
    *rig.agent_answer.lock().unwrap() = ok("```\nPipeline P {}\n```");
    let answer = rig.ask("agent.run", define(json!({}))).await.unwrap();
    assert_eq!(
        answer,
        json!({ "kind": "definition", "text": "Pipeline P {}\n" })
    );
    {
        let runs = rig.agent_runs.lock().unwrap();
        assert!(runs[0].prompt.contains("Build, then review."));
        assert_eq!(runs[0].harness, Harness::Claude);
    }

    rig.ask("config.set", json!({ "patch": { "defaultHarness": "Codex", "defaultModels": { "Codex": "gpt-x" }, "env": { "OPENCODE_X": "y" } } })).await.unwrap();
    rig.ask("agent.run", define(json!({}))).await.unwrap();
    rig.ask("agent.run", define(json!({ "harness": "Opencode" })))
        .await
        .unwrap();
    rig.ask("agent.run", define(json!({ "model": "opus" })))
        .await
        .unwrap();
    let runs = rig.agent_runs.lock().unwrap();
    let seen: Vec<(Harness, Option<String>)> =
        runs.iter().map(|r| (r.harness, r.model.clone())).collect();
    assert_eq!(
        seen,
        vec![
            (Harness::Claude, None),
            (Harness::Codex, Some("gpt-x".into())),
            (Harness::Opencode, None),
            (Harness::Codex, Some("opus".into())),
        ]
    );
    // The variables set in the app are given to the agent.
    assert_eq!(
        runs[1].env,
        BTreeMap::from([("OPENCODE_X".to_string(), "y".to_string())])
    );
}

#[tokio::test]
async fn it_answers_unavailable_when_the_agent_fails_or_says_nothing() {
    let dir = tempdir().unwrap();
    let mut rig = Rig::with_path(Vault::default(), &pipeline_path(dir.path())).await;
    for result in [
        CliResult {
            code: 1,
            stdout: String::new(),
            stderr: "quota\n".into(),
        },
        ok("  \n"),
    ] {
        *rig.agent_answer.lock().unwrap() = result;
        let error = rig.ask("agent.run", define(json!({}))).await.unwrap_err();
        assert_eq!(error.0, ErrorCode::Unavailable);
    }
}

#[tokio::test]
async fn it_refuses_a_description_that_is_empty_a_name_that_is_not_one_and_a_model_that_is_a_flag()
{
    let mut rig = Rig::new(Vault::default()).await;
    for bad in [
        define(json!({ "prompt": "" })),
        define(json!({ "definitions": [{ "name": "../x", "kind": "agent" }] })),
        define(json!({ "model": "--dangerous" })),
    ] {
        let error = rig.ask("agent.run", bad).await.unwrap_err();
        assert_eq!(error.0, ErrorCode::BadRequest);
    }
}

// A note --------------------------------------------------------------------------------------

fn vault_of(files: &[(&str, String)]) -> Vault {
    Vault {
        files: files
            .iter()
            .map(|(k, v)| (k.to_string(), v.clone()))
            .collect(),
        vault: Some("/the/vault".into()),
        ..Vault::default()
    }
}

#[tokio::test]
async fn a_note_is_written_with_the_prompt_of_its_kind_and_answered_with_the_note_that_is_new() {
    let vault = Vault {
        listings: VecDeque::from([
            "Index.md\n".to_string(),
            "Index.md\nresearch/Cache keys.md\n".to_string(),
        ]),
        vault: Some("/the/vault".into()),
        ..Vault::default()
    };
    let mut rig = Rig::new(vault).await;
    *rig.session_answer.lock().unwrap() = ok("written\nresearch/Cache keys.md\n");
    let answer = rig
        .ask(
            "agent.run",
            json!({ "kind": "note", "what": "design", "prompt": "Why keys are per branch" }),
        )
        .await
        .unwrap();
    assert_eq!(
        answer,
        json!({ "kind": "note", "path": "research/Cache keys.md" })
    );
    let sessions = rig.sessions.lock().unwrap();
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0].harness, Harness::Claude);
    assert!(sessions[0].prompt.contains("synapse-design-note skill"));
    assert!(sessions[0].prompt.contains("Why keys are per branch"));
    // The session gets the environment the app runs programs in.
    assert_eq!(sessions[0].env["MARK"], "x");
}

#[tokio::test]
async fn it_lets_the_session_write_in_the_vault_and_the_folders_that_exist_and_nowhere_else() {
    let dir = tempdir().unwrap();
    let vault_dir = dir.path().join("vault");
    fs::create_dir_all(&vault_dir).unwrap();
    let vault = Vault {
        listings: VecDeque::from([
            "Index.md\n".to_string(),
            "Index.md\nresearch/A.md\n".to_string(),
        ]),
        vault: Some(vault_dir.to_string_lossy().to_string()),
        ..Vault::default()
    };
    let mut rig = Rig::new(vault).await;
    // The rig's home has a configuration folder of Synapse's only when it is made.
    fs::create_dir_all(rig.dir.path().join(".config/synapse")).unwrap();
    *rig.session_answer.lock().unwrap() = ok("research/A.md");
    rig.ask(
        "agent.run",
        json!({ "kind": "note", "what": "note", "prompt": "x" }),
    )
    .await
    .unwrap();
    // The work folder does not exist here, so it is left out.
    let writable = rig.sessions.lock().unwrap()[0].writable.clone();
    assert_eq!(
        writable,
        [
            vault_dir.to_string_lossy().to_string(),
            rig.dir
                .path()
                .join(".config/synapse")
                .to_string_lossy()
                .to_string()
        ]
    );
}

#[tokio::test]
async fn a_task_note_is_told_the_projects_there_are_or_the_one_it_was_given_and_an_unknown_one_is_refused(
) {
    let vault = Vault {
        listings: VecDeque::from([
            "Index.md\n".into(),
            "Index.md\nresearch/A.md\n".into(),
            "Index.md\n".into(),
            "Index.md\nresearch/A.md\n".into(),
        ]),
        pairs: vec![
            ("synapse".into(), "sb".into()),
            ("eon".into(), "ecs".into()),
        ],
        vault: Some("/the/vault".into()),
        ..Vault::default()
    };
    let mut rig = Rig::new(vault).await;
    *rig.session_answer.lock().unwrap() = ok("research/A.md");
    rig.ask(
        "agent.run",
        json!({ "kind": "note", "what": "task", "prompt": "x" }),
    )
    .await
    .unwrap();
    rig.ask(
        "agent.run",
        json!({ "kind": "note", "what": "task", "prompt": "x", "project": "eon" }),
    )
    .await
    .unwrap();
    {
        let sessions = rig.sessions.lock().unwrap();
        assert!(sessions[0]
            .prompt
            .contains("as name=prefix: synapse=sb, eon=ecs"));
        assert!(sessions[1]
            .prompt
            .contains("The project of this note is eon, with the prefix ecs"));
    }
    let refused = rig
        .ask(
            "agent.run",
            json!({ "kind": "note", "what": "task", "prompt": "x", "project": "nope" }),
        )
        .await
        .unwrap_err();
    assert_eq!(refused.0, ErrorCode::Conflict);
    assert!(refused.1.contains("nope is not a project"));
    assert_eq!(rig.sessions.lock().unwrap().len(), 2);
}

#[tokio::test]
async fn it_is_refused_before_anything_is_run_when_no_vault_is_set_up() {
    let mut rig = Rig::new(Vault::default()).await;
    let refused = rig
        .ask(
            "agent.run",
            json!({ "kind": "note", "what": "note", "prompt": "x" }),
        )
        .await
        .unwrap_err();
    assert_eq!(refused.0, ErrorCode::Conflict);
    assert!(refused.1.contains("no vault"));
    assert!(rig.sessions.lock().unwrap().is_empty());
}

#[tokio::test]
async fn it_says_why_no_note_was_written_with_what_the_agent_said() {
    let mut rig = Rig::new(Vault {
        listings: VecDeque::from(["Index.md\n".into(), "Index.md\n".into()]),
        ..vault_of(&[])
    })
    .await;
    *rig.session_answer.lock().unwrap() = ok("thinking\nFAILED: no project fits\n");
    let error = rig
        .ask(
            "agent.run",
            json!({ "kind": "note", "what": "task", "prompt": "x" }),
        )
        .await
        .unwrap_err();
    assert_eq!(
        error,
        (
            ErrorCode::Unavailable,
            "No note was written. no project fits".to_string()
        )
    );
}

#[tokio::test]
async fn the_model_and_the_harness_of_a_note_session_are_the_one_named_else_the_default_else_none()
{
    let listings = || {
        VecDeque::from(vec![
            "Index.md\n".to_string(),
            "Index.md\na.md\n".to_string(),
        ])
    };
    let mut rig = Rig::new(Vault {
        listings: listings(),
        ..vault_of(&[])
    })
    .await;
    *rig.session_answer.lock().unwrap() = ok("a.md");
    rig.ask(
        "agent.run",
        json!({ "kind": "note", "what": "note", "prompt": "x", "model": "opus" }),
    )
    .await
    .unwrap();
    rig.ask(
        "config.set",
        json!({ "patch": { "defaultHarness": "Codex", "defaultModels": { "Codex": "gpt-x" } } }),
    )
    .await
    .unwrap();
    rig.vault.lock().unwrap().listings = listings();
    rig.ask(
        "agent.run",
        json!({ "kind": "note", "what": "note", "prompt": "x" }),
    )
    .await
    .unwrap();
    rig.vault.lock().unwrap().listings = listings();
    rig.ask(
        "agent.run",
        json!({ "kind": "note", "what": "note", "prompt": "x", "harness": "Opencode" }),
    )
    .await
    .unwrap();
    let seen: Vec<(Harness, Option<String>)> = rig
        .sessions
        .lock()
        .unwrap()
        .iter()
        .map(|s| (s.harness, s.model.clone()))
        .collect();
    assert_eq!(
        seen,
        vec![
            (Harness::Claude, Some("opus".into())),
            (Harness::Codex, Some("gpt-x".into())),
            (Harness::Opencode, None),
        ]
    );
}

// Changing a note -------------------------------------------------------------------------------

#[tokio::test]
async fn a_note_is_changed_and_given_back_as_it_was_and_as_it_is() {
    let mut rig = Rig::new(vault_of(&[
        ("a.md", note("1", "old")),
        ("b.md", note("1", "text")),
    ]))
    .await;
    *rig.session_effect.lock().unwrap() = Some(Box::new(|v: &mut Vault| {
        v.files.insert("a.md".into(), note("2", "new"));
    }));
    let edit = rig
        .ask(
            "agent.run",
            json!({ "kind": "note-edit", "path": "a.md", "prompt": "Say new instead of old" }),
        )
        .await
        .unwrap();
    assert_eq!(
        edit,
        json!({ "kind": "note-edit", "edit": { "before": note("1", "old"), "after": note("2", "new"), "touched": [] } })
    );
    let prompt = rig.sessions.lock().unwrap()[0].prompt.clone();
    assert!(prompt.contains("The note is `a.md`") && prompt.contains("Say new instead of old"));
    assert!(prompt.contains("change no other note"));
}

#[tokio::test]
async fn the_other_notes_the_agent_moved_are_named() {
    let mut rig = Rig::new(vault_of(&[
        ("a.md", note("1", "text")),
        ("b.md", note("1", "text")),
    ]))
    .await;
    *rig.session_effect.lock().unwrap() = Some(Box::new(|v: &mut Vault| {
        v.files.insert("a.md".into(), note("2", "changed"));
        v.files.insert("b.md".into(), note("2", "also changed"));
        v.files.insert("new.md".into(), note("2", "x"));
    }));
    let edit = rig
        .ask(
            "agent.run",
            json!({ "kind": "note-edit", "path": "a.md", "prompt": "x" }),
        )
        .await
        .unwrap();
    assert_eq!(edit["edit"]["touched"], json!(["b.md", "new.md"]));
}

#[tokio::test]
async fn it_says_why_when_the_note_was_not_changed_and_does_not_start_for_a_graph_node_or_a_missing_note(
) {
    let mut rig = Rig::new(vault_of(&[("a.md", note("1", "text"))])).await;
    *rig.session_answer.lock().unwrap() = ok("FAILED: not allowed to do that");
    let refused = rig
        .ask(
            "agent.run",
            json!({ "kind": "note-edit", "path": "a.md", "prompt": "x" }),
        )
        .await
        .unwrap_err();
    assert_eq!(
        refused,
        (
            ErrorCode::Unavailable,
            "The note was not changed. not allowed to do that".to_string()
        )
    );
    let started = rig.sessions.lock().unwrap().len();

    let node = rig
        .ask(
            "agent.run",
            json!({ "kind": "note-edit", "path": "synapse/w@main/N.md", "prompt": "x" }),
        )
        .await
        .unwrap_err();
    assert_eq!(node.0, ErrorCode::BadRequest);
    let missing = rig
        .ask(
            "agent.run",
            json!({ "kind": "note-edit", "path": "nope.md", "prompt": "x" }),
        )
        .await
        .unwrap_err();
    assert_eq!(missing.0, ErrorCode::NotFound);
    assert_eq!(rig.sessions.lock().unwrap().len(), started);
}

#[tokio::test]
async fn a_note_is_put_back_when_it_is_still_as_the_change_left_it_and_not_when_it_changed_again() {
    let mut rig = Rig::new(vault_of(&[("a.md", note("2", "new"))])).await;
    rig.ask(
        "note.restore",
        json!({ "path": "a.md", "before": note("1", "old"), "after": note("2", "new") }),
    )
    .await
    .unwrap();
    assert_eq!(rig.vault.lock().unwrap().files["a.md"], note("1", "old"));
    assert_eq!(rig.vault.lock().unwrap().writes, ["a.md"]);

    let mut again = Rig::new(vault_of(&[("a.md", note("3", "by hand"))])).await;
    let refused = again
        .ask(
            "note.restore",
            json!({ "path": "a.md", "before": note("1", "old"), "after": note("2", "new") }),
        )
        .await
        .unwrap_err();
    assert_eq!(refused.0, ErrorCode::Conflict);
    assert!(refused.1.contains("changed again"));
    assert!(again.vault.lock().unwrap().writes.is_empty());

    let node = again
        .ask(
            "note.restore",
            json!({ "path": "synapse/w@main/N.md", "before": "a", "after": "b" }),
        )
        .await
        .unwrap_err();
    assert_eq!(node.0, ErrorCode::BadRequest);
}

#[test]
fn a_session_is_told_where_its_folder_is_first_so_that_the_description_stays_last() {
    let prompt = note_prompt(
        NoteKind::Note,
        "Why the cache is keyed by branch",
        Harness::Claude,
        &[],
        None,
    );
    let given = session_prompt(&prompt, Path::new("/tmp/synapse-note-abc"));
    assert!(given.starts_with(&folder_sentence(Path::new("/tmp/synapse-note-abc"))));
    assert!(given.ends_with("Description:\nWhy the cache is keyed by branch"));
}

#[tokio::test]
async fn a_note_is_put_back_with_the_program_told_where_the_schemas_are() {
    let seen = Arc::new(Mutex::new(Vec::<Option<String>>::new()));
    let kept = seen.clone();
    let cli = CliRunner::new(move |run: CliRun| {
        let result = match run.args[0].as_str() {
            "vault-read" => ok(&note("2", "new")),
            _ => {
                kept.lock()
                    .unwrap()
                    .push(run.env.get("SYNAPSE_CONTENT_ROOT").cloned());
                ok("")
            }
        };
        async move { Ok(result) }
    });
    let config = AppConfig {
        work_dir: None,
        definition_paths: vec![],
        default_harness: None,
        default_models: BTreeMap::new(),
        env: BTreeMap::new(),
        recent_vaults: vec![],
        terminal_folder: None,
        graph_repos: BTreeMap::new(),
    };
    let (before, after) = (note("1", "old"), note("2", "new"));
    restore_note(
        &cli,
        &config,
        "a.md",
        &before,
        &after,
        Some(Path::new("/pkg/synapse")),
    )
    .await
    .unwrap();
    restore_note(&cli, &config, "a.md", &before, &after, None)
        .await
        .unwrap();
    assert_eq!(
        *seen.lock().unwrap(),
        [Some("/pkg/synapse".to_string()), None]
    );
}

#[tokio::test]
async fn it_says_so_when_synapse_has_no_projects_command_for_a_task_note() {
    let mut rig = Rig::new(Vault {
        projects_down: true,
        ..vault_of(&[])
    })
    .await;
    let error = rig
        .ask(
            "agent.run",
            json!({ "kind": "note", "what": "task", "prompt": "x" }),
        )
        .await
        .unwrap_err();
    assert_eq!(error.0, ErrorCode::Unavailable);
    assert!(error.1.contains("unknown subcommand 'projects'"));
}

const TASK_NOTE: &str = "---\nschema: vault-task-note/v1\ntask_id: sb-1\nstatus: REVIEW\nupdated: 2026-01-01T00:00:00+01:00\n---\n# A task\n";

#[tokio::test]
async fn a_person_sets_the_status_of_a_task_note_and_the_time_it_was_updated_and_nothing_else() {
    let mut rig = Rig::new(vault_of(&[("tasks/p/A task.md", TASK_NOTE.to_string())])).await;
    rig.ask(
        "note.status",
        json!({ "path": "tasks/p/A task.md", "status": "DONE" }),
    )
    .await
    .unwrap();
    let vault = rig.vault.lock().unwrap();
    assert_eq!(
        vault.sets,
        [
            "tasks/p/A task.md status DONE",
            "tasks/p/A task.md updated 2026-11-16T20:00:00+01:00"
        ]
    );
    assert_eq!(
        vault.files["tasks/p/A task.md"],
        TASK_NOTE
            .replace("status: REVIEW", "status: DONE")
            .replace("2026-01-01T00:00:00+01:00", "2026-11-16T20:00:00+01:00")
    );
    assert!(vault.writes.is_empty());
}

#[tokio::test]
async fn a_status_is_refused_for_a_note_that_is_not_a_task_a_path_that_is_not_a_note_and_a_status_that_is_not_one(
) {
    let plain = "---\nschema: vault-note/v1\ntitle: \"x\"\n---\n# x\n".to_string();
    let mut rig = Rig::new(vault_of(&[
        ("plain.md", plain),
        ("synapse/w@main/Node.md", TASK_NOTE.to_string()),
    ]))
    .await;
    for path in [
        "plain.md",
        "../x.md",
        "/etc/x.md",
        "a.txt",
        "synapse/w@main/Node.md",
    ] {
        let error = rig
            .ask("note.status", json!({ "path": path, "status": "DONE" }))
            .await
            .unwrap_err();
        assert_eq!(error.0, ErrorCode::BadRequest, "{path}");
    }
    let missing = rig
        .ask(
            "note.status",
            json!({ "path": "nope.md", "status": "DONE" }),
        )
        .await
        .unwrap_err();
    assert_eq!(missing.0, ErrorCode::NotFound);
    let wrong = rig
        .ask(
            "note.status",
            json!({ "path": "plain.md", "status": "FINISHED" }),
        )
        .await
        .unwrap_err();
    assert_eq!(wrong.0, ErrorCode::BadRequest);
    assert!(rig.vault.lock().unwrap().sets.is_empty());
}

// ---------------------------------------------------------------------------------------------
// Stopping and streaming
// ---------------------------------------------------------------------------------------------

#[test]
fn claude_streams_events_in_place_of_text_and_keeps_every_other_flag() {
    let plain = note_command(
        Harness::Claude,
        &claude_plan(),
        "p",
        &["/v".into()],
        None,
        false,
    );
    let streamed = note_command(
        Harness::Claude,
        &claude_plan(),
        "p",
        &["/v".into()],
        None,
        true,
    );
    assert_eq!(arg_after(&plain.args, "--output-format"), "text");
    assert_eq!(arg_after(&streamed.args, "--output-format"), "stream-json");
    assert!(streamed.args.contains(&"--verbose".to_string()));
    assert!(!streamed.args.contains(&"text".to_string()));
    assert!(streamed
        .args
        .contains(&"--no-session-persistence".to_string()));
    let without: Vec<String> = streamed
        .args
        .iter()
        .filter(|a| *a != "--verbose")
        .map(|a| {
            if a == "stream-json" {
                "text".to_string()
            } else {
                a.clone()
            }
        })
        .collect();
    assert_eq!(without, plain.args);
    assert!(!plain.args.contains(&"--verbose".to_string()));
}

#[test]
fn codex_and_opencode_ignore_the_stream_flag() {
    for (harness, program) in [(Harness::Codex, "codex"), (Harness::Opencode, "opencode")] {
        let p = plan(program, &[], &[]);
        let a = note_command(harness, &p, "p", &["/v".into()], None, false);
        let b = note_command(harness, &p, "p", &["/v".into()], None, true);
        assert_eq!(a, b);
    }
}

#[test]
fn the_result_of_a_stream_is_the_text_of_its_last_result_event() {
    let transcript = [
        r#"{"type":"system","subtype":"init"}"#,
        r#"{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}"#,
        r#"{"type":"result","subtype":"success","result":"EDITED"}"#,
    ]
    .join("\n");
    assert_eq!(stream_result(&transcript), "EDITED");
    let none = r#"{"type":"assistant"}"#;
    assert_eq!(stream_result(none), "");
    let failed = r#"{"type":"result","result":"I tried.\nFAILED: why"}"#;
    assert_eq!(failure_of(&stream_result(failed)).as_deref(), Some("why"));
    assert_eq!(stream_result("not json\nstill not\n"), "");
    assert_eq!(stream_result(r#"{"type":"result","result":5}"#), "");
}

fn plain_config() -> AppConfig {
    AppConfig {
        work_dir: None,
        definition_paths: vec![],
        default_harness: None,
        default_models: BTreeMap::new(),
        env: BTreeMap::new(),
        recent_vaults: vec![],
        terminal_folder: None,
        graph_repos: BTreeMap::new(),
    }
}

/// A note that reads as `texts` in turn, the last one for every read after.
fn edit_cli(texts: &[&str]) -> CliRunner {
    let texts: Vec<String> = texts.iter().map(|t| t.to_string()).collect();
    let reads = Arc::new(Mutex::new(0usize));
    CliRunner::new(move |run: CliRun| {
        let result = match run.args[0].as_str() {
            "vault-read" => {
                let mut n = reads.lock().unwrap();
                let text = texts[(*n).min(texts.len() - 1)].clone();
                *n += 1;
                ok(&text)
            }
            _ => ok(""),
        };
        async move { Ok(result) }
    })
}

fn session_of(
    result: CliResult,
) -> impl Fn(
    String,
) -> std::pin::Pin<Box<dyn std::future::Future<Output = Result<CliResult, String>> + Send>> {
    move |_| {
        let result = result.clone();
        Box::pin(async move { Ok(result) })
    }
}

#[tokio::test]
async fn a_stopped_edit_that_left_the_note_alone_says_it_was_stopped() {
    let cli = edit_cli(&["old\n"]);
    let stopped = CliResult {
        code: 143,
        stdout: String::new(),
        stderr: String::new(),
    };
    let error = edit_note(
        &cli,
        &plain_config(),
        Harness::Claude,
        session_of(stopped),
        "a.md",
        "x",
        || true,
    )
    .await
    .unwrap_err();
    assert_eq!(
        error.message,
        "The run was stopped and the note was not changed."
    );
}

#[tokio::test]
async fn a_stopped_edit_that_changed_the_note_gives_the_edit() {
    let cli = edit_cli(&["old\n", "new\n"]);
    let stopped = CliResult {
        code: 143,
        stdout: String::new(),
        stderr: String::new(),
    };
    let edit = edit_note(
        &cli,
        &plain_config(),
        Harness::Claude,
        session_of(stopped),
        "a.md",
        "x",
        || true,
    )
    .await
    .unwrap();
    assert_eq!(
        (edit.before.as_str(), edit.after.as_str()),
        ("old\n", "new\n")
    );
}

#[tokio::test]
async fn an_edit_that_was_not_stopped_and_left_the_note_alone_keeps_the_old_message() {
    let cli = edit_cli(&["old\n"]);
    let error = edit_note(
        &cli,
        &plain_config(),
        Harness::Claude,
        session_of(ok("EDITED")),
        "a.md",
        "x",
        || false,
    )
    .await
    .unwrap_err();
    assert!(
        error.message.starts_with("The note was not changed."),
        "{}",
        error.message
    );
}

#[tokio::test]
async fn a_definition_run_that_was_stopped_says_the_run_was_stopped() {
    let agent = AgentRunner::new(|_| async {
        Ok(CliResult {
            code: 143,
            stdout: String::new(),
            stderr: String::new(),
        })
    });
    let request = GenerateRequest {
        kind: DefinitionKind::Skill,
        prompt: "x",
        current: None,
        definitions: &[],
        skills: &[],
    };
    let env = environment(Path::new("/nowhere"), &[]);
    let call = |stopped: bool| {
        let (agent, env, request) = (&agent, &env, &request);
        async move {
            generate_text(
                request,
                env,
                &[],
                agent,
                AgentChoice {
                    harness: Harness::Claude,
                    model: None,
                    env: BTreeMap::new(),
                },
                None,
                move || stopped,
            )
            .await
        }
    };
    let error = call(true).await.unwrap_err();
    assert_eq!(error.message, "the run was stopped");
    let other = call(false).await.unwrap_err();
    assert!(
        other.message.starts_with("the agent failed"),
        "{}",
        other.message
    );
}

// Stopping and watching a run -------------------------------------------------------------------

fn sessions_started(rig: &Rig) -> bool {
    !rig.sessions.lock().unwrap().is_empty()
}

#[tokio::test]
async fn stopping_a_run_that_changed_nothing_says_it_was_stopped_and_the_note_was_not_changed() {
    let mut rig = Rig::new(vault_of(&[("a.md", note("1", "old"))])).await;
    let error = rig
        .ask_stopping(
            json!({ "kind": "note-edit", "path": "a.md", "prompt": "x", "run": "r-1" }),
            sessions_started,
        )
        .await
        .unwrap_err();
    assert_eq!(
        error,
        (
            ErrorCode::Unavailable,
            "The run was stopped and the note was not changed.".to_string()
        )
    );
}

#[tokio::test]
async fn stopping_a_run_after_the_note_changed_answers_the_change() {
    let mut rig = Rig::new(vault_of(&[("a.md", note("1", "old"))])).await;
    *rig.session_effect.lock().unwrap() = Some(Box::new(|v: &mut Vault| {
        v.files.insert("a.md".into(), note("2", "new"));
    }));
    let edit = rig
        .ask_stopping(
            json!({ "kind": "note-edit", "path": "a.md", "prompt": "x", "run": "r-2" }),
            sessions_started,
        )
        .await
        .unwrap();
    assert_eq!(edit["edit"]["after"], json!(note("2", "new")));
}

#[tokio::test]
async fn stopping_a_new_note_and_a_definition_says_so() {
    let mut rig = Rig::new(vault_of(&[])).await;
    let error = rig
        .ask_stopping(
            json!({ "kind": "note", "what": "note", "prompt": "x", "run": "r-3" }),
            sessions_started,
        )
        .await
        .unwrap_err();
    assert_eq!(
        error,
        (
            ErrorCode::Unavailable,
            "The run was stopped. No note was written.".to_string()
        )
    );

    let dir = tempdir().unwrap();
    let mut rig = Rig::with_path(Vault::default(), &pipeline_path(dir.path())).await;
    let error = rig
        .ask_stopping(define(json!({ "run": "r-4" })), |rig| {
            !rig.agent_runs.lock().unwrap().is_empty()
        })
        .await
        .unwrap_err();
    assert_eq!(
        error,
        (ErrorCode::Unavailable, "the run was stopped".to_string())
    );
}

#[tokio::test]
async fn a_claude_edit_publishes_the_lines_it_prints_and_the_others_are_not_streamed() {
    let mut rig = Rig::new(vault_of(&[("a.md", note("1", "old"))])).await;
    *rig.session_lines.lock().unwrap() = vec!["one".into(), "two".into()];
    *rig.session_effect.lock().unwrap() = Some(Box::new(|v: &mut Vault| {
        v.files.insert("a.md".into(), note("2", "new"));
    }));
    let edit = json!({ "kind": "note-edit", "path": "a.md", "prompt": "x" });
    let mut with_run = edit.clone();
    with_run["run"] = json!("r-5");
    rig.ask("agent.run", with_run).await.unwrap();
    {
        let sessions = rig.sessions.lock().unwrap();
        assert!(sessions[0].stream && sessions[0].on_line.is_some());
    }
    type Seen = Arc<Mutex<Vec<(Value, Option<u64>)>>>;
    let seen: Seen = Arc::new(Mutex::new(vec![]));
    let sink = seen.clone();
    let _unsubscribe = rig.runs.subscribe(
        "r-5",
        None,
        Arc::new(move |data, cursor| sink.lock().unwrap().push((data, cursor))),
    );
    assert_eq!(
        *seen.lock().unwrap(),
        vec![
            (json!({ "line": "one" }), Some(0)),
            (json!({ "line": "two" }), Some(1))
        ]
    );

    // Without an id, and for Codex, nothing is streamed.
    *rig.session_effect.lock().unwrap() = Some(Box::new(|v: &mut Vault| {
        v.files.insert("a.md".into(), note("3", "newer"));
    }));
    rig.ask("agent.run", edit.clone()).await.unwrap();
    let mut codex = edit;
    codex["run"] = json!("r-6");
    codex["harness"] = json!("Codex");
    *rig.session_effect.lock().unwrap() = Some(Box::new(|v: &mut Vault| {
        v.files.insert("a.md".into(), note("4", "newest"));
    }));
    rig.ask("agent.run", codex).await.unwrap();
    let sessions = rig.sessions.lock().unwrap();
    assert!(!sessions[1].stream && sessions[1].on_line.is_none());
    assert!(!sessions[2].stream && sessions[2].on_line.is_none());
}

#[tokio::test]
async fn a_run_id_that_is_running_cannot_be_started_again_and_stopping_an_unknown_id_is_fine() {
    let mut rig = Rig::new(vault_of(&[("a.md", note("1", "old"))])).await;
    rig.ask("agent.stop", json!({ "run": "nobody" }))
        .await
        .unwrap();
    let _held = rig.runs.start("busy").unwrap();
    let error = rig
        .ask(
            "agent.run",
            json!({ "kind": "note-edit", "path": "a.md", "prompt": "x", "run": "busy" }),
        )
        .await
        .unwrap_err();
    assert_eq!(error.0, ErrorCode::Conflict);
}
