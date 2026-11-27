//! The request a page can make of the host: its name, the parameters it takes and the result it
//! has. They are written by hand to match `shared/messages.ts`; the shared example files, which both
//! hosts read, are what keeps the two the same. A request with nothing to say answers `null`, which
//! is `()` here.

use crate::config::{is_definition_name, is_execution_id, is_model_name, is_namespace};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// The rules of a request's parameters beyond their types: lengths, and the forms of names. A request
/// that breaks them is refused before its handler sees it, as the Node host refuses it.
pub trait Validate {
    fn check(&self) -> Result<(), String> {
        Ok(())
    }
}

/// `field` is between `min` and `max` characters.
fn within(field: &str, text: &str, min: usize, max: usize) -> Result<(), String> {
    let length = text.chars().count();
    if length < min || length > max {
        return Err(format!("{field} is {min} to {max} characters"));
    }
    Ok(())
}

fn at_most(field: &str, text: &str, max: usize) -> Result<(), String> {
    within(field, text, 0, max)
}

fn named(field: &str, ok: bool, text: &str) -> Result<(), String> {
    if ok {
        Ok(())
    } else {
        Err(format!("{text:?} is not a valid {field}"))
    }
}

const DRAFT: usize = 200_000;

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Harness {
    Claude,
    Codex,
    Opencode,
}

/// A request with no parameters.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Nothing {}

// ---------------------------------------------------------------------------------------------
// Files, and the programs of Synapse
// ---------------------------------------------------------------------------------------------

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct PathParams {
    pub path: String,
}

/// The folder of a vault, as typed.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct VaultPathParams {
    pub path: String,
}

/// What a snapshot is of, other than the working tree as it is.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq)]
#[serde(rename_all = "lowercase")]
pub enum SnapshotOf {
    /// The tree of the last commit, the empty tree when there is none.
    Head,
}

/// The folder whose working tree is snapshotted.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct ChangesSnapshotParams {
    pub folder: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub of: Option<SnapshotOf>,
}

/// A snapshot: the id of a tree object, null when the folder is not in a git repository, and where
/// HEAD was when it was taken (see `FolderChanges::head`).
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct SnapshotAnswer {
    pub tree: Option<String>,
    pub head: Option<String>,
}

/// The changes in a folder's working tree since a snapshot, or in one file of it.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct ChangesDiffParams {
    pub folder: String,
    pub before: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    /// With it, the changes are those between two snapshots, and none is taken of the working tree.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<String>,
}

/// A snapshot to pin under `refs/synapse/<ref>`, so that `git gc` keeps it.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct ChangesPinParams {
    pub folder: String,
    /// `runs/<execution-id>/start` or `runs/<execution-id>/end`.
    #[serde(rename = "ref")]
    pub reference: String,
    pub tree: String,
}

/// The ref a snapshot was pinned as, to delete.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct ChangesUnpinParams {
    pub folder: String,
    #[serde(rename = "ref")]
    pub reference: String,
}

/// The commits of the branch a folder is on, `limit` at a time, after `before` when it is given.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct ChangesLogParams {
    pub folder: String,
    pub limit: u32,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub before: Option<String>,
}

/// What a commit changed, or one file of it.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct ChangesCommitParams {
    pub folder: String,
    pub commit: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
}

/// A commit of the branch a session is on, as the Git tab lists it.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Commit {
    /// The full hash.
    pub hash: String,
    pub subject: String,
    pub author: String,
    /// When it was committed, ISO 8601.
    pub time: String,
    /// The lines it added and removed, against its first parent; binary files have none to count.
    pub added: u64,
    pub removed: u64,
}

/// A page of the commits of HEAD, newest first along the first parent, and whether there are more.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct CommitLog {
    pub repository: bool,
    pub commits: Vec<Commit>,
    pub more: bool,
}

/// A file that is new, by its path and its number of lines, none for a binary file.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct AddedFile {
    pub path: String,
    pub lines: Option<u64>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct FolderChanges {
    pub repository: bool,
    pub patch: String,
    pub added: Vec<AddedFile>,
    /// Where HEAD is now: the branch checked out, the commit when HEAD is detached, or null when the
    /// folder is not in a git repository. A client keeps a snapshot for each, so that a branch switch
    /// starts a new comparison and switching back restores the old one.
    pub head: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Text {
    pub text: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DirEntry {
    pub name: String,
    pub is_dir: bool,
    pub mtime_ms: f64,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Entries {
    pub entries: Vec<DirEntry>,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum CliBinary {
    SynapsePipeline,
    Synapse,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct CliParams {
    pub binary: CliBinary,
    pub args: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stdin: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct CliResult {
    pub code: i32,
    pub stdout: String,
    pub stderr: String,
}

// ---------------------------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------------------------

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AppConfig {
    pub work_dir: Option<String>,
    pub definition_paths: Vec<String>,
    pub default_harness: Option<Harness>,
    pub default_models: BTreeMap<Harness, String>,
    pub env: BTreeMap<String, String>,
    pub recent_vaults: Vec<String>,
    pub terminal_folder: Option<String>,
    pub graph_repos: BTreeMap<String, String>,
}

/// The settings to change; what is absent stays as it is.
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AppConfigPatch {
    #[serde(
        default,
        deserialize_with = "some",
        skip_serializing_if = "Option::is_none"
    )]
    pub work_dir: Option<Option<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub definition_paths: Option<Vec<String>>,
    #[serde(
        default,
        deserialize_with = "some",
        skip_serializing_if = "Option::is_none"
    )]
    pub default_harness: Option<Option<Harness>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub default_models: Option<BTreeMap<Harness, String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub env: Option<BTreeMap<String, String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recent_vaults: Option<Vec<String>>,
    #[serde(
        default,
        deserialize_with = "some",
        skip_serializing_if = "Option::is_none"
    )]
    pub terminal_folder: Option<Option<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub graph_repos: Option<BTreeMap<String, String>>,
}

/// A member that may be set to `null`, told apart from one that is absent.
fn some<'de, D, T>(deserializer: D) -> Result<Option<Option<T>>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    Option::<T>::deserialize(deserializer).map(Some)
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct AppPaths {
    pub definition_dirs: Vec<String>,
    pub records_dir: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct ConfigAnswer {
    pub config: AppConfig,
    pub paths: AppPaths,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct ConfigSet {
    pub patch: AppConfigPatch,
}

// ---------------------------------------------------------------------------------------------
// The projects and the conventions
// ---------------------------------------------------------------------------------------------

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Project {
    pub name: String,
    pub prefix: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct ProjectList {
    pub projects: Vec<Project>,
    pub file: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub enum ConventionGroup {
    Vault,
    #[serde(rename = "Code graph")]
    CodeGraph,
    Prompts,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct ConventionEntry {
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Convention {
    pub id: String,
    pub group: ConventionGroup,
    pub title: String,
    pub about: String,
    pub file: String,
    pub exists: bool,
    pub editable: bool,
    pub entries: Vec<ConventionEntry>,
    pub problem: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct ConventionList {
    pub conventions: Vec<Convention>,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum RegistryKind {
    Projects,
    Conventions,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct RegistryListParams {
    pub kind: RegistryKind,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum RegistryAddParams {
    Projects { name: String, prefix: String },
    Conventions { id: String, entry: String },
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct RegistryRemoveParams {
    pub kind: RegistryKind,
    pub id: String,
    pub entry: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum RegistryAnswer {
    Projects { list: ProjectList },
    Conventions { list: ConventionList },
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct ConventionsAnswer {
    pub kind: RegistryKind,
    pub list: ConventionList,
}

// ---------------------------------------------------------------------------------------------
// What the harnesses know
// ---------------------------------------------------------------------------------------------

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct ModelsParams {
    pub harness: Harness,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refresh: Option<bool>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct ModelOption {
    pub id: String,
    pub provider: Option<String>,
    pub available: bool,
    pub detail: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ModelCatalog {
    pub models: Vec<ModelOption>,
    pub note: Option<String>,
    pub read_at: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum HistoryKind {
    Sessions,
    Workspaces,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct HistoryParams {
    pub what: HistoryKind,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PastSession {
    pub id: String,
    pub path: String,
    pub title: Option<String>,
    pub last_used: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Workspace {
    pub path: String,
    pub last_used: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "PascalCase")]
pub struct ByHarness<T> {
    pub claude: Vec<T>,
    pub codex: Vec<T>,
    pub opencode: Vec<T>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "what", rename_all = "lowercase")]
pub enum HistoryAnswer {
    Sessions { sessions: ByHarness<PastSession> },
    Workspaces { workspaces: ByHarness<Workspace> },
}

// ---------------------------------------------------------------------------------------------
// An agent writes something
// ---------------------------------------------------------------------------------------------

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum DefinitionDraftKind {
    Pipeline,
    System,
    Agent,
    Prompt,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum DefinitionKind {
    Pipeline,
    System,
    Agent,
    Prompt,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum NoteKind {
    Note,
    Task,
    Design,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct DefinitionName {
    pub name: String,
    pub kind: DefinitionDraftKind,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum AgentRunParams {
    Definition {
        what: DefinitionKind,
        prompt: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        harness: Option<Harness>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        model: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        current: Option<String>,
        definitions: Vec<DefinitionName>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        run: Option<String>,
    },
    Note {
        what: NoteKind,
        prompt: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        harness: Option<Harness>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        model: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        project: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        run: Option<String>,
    },
    NoteEdit {
        path: String,
        prompt: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        harness: Option<Harness>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        model: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        run: Option<String>,
    },
    RunInput {
        pipeline: String,
        prompt: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        harness: Option<Harness>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        model: Option<String>,
        /// The JSON in the editor now, which the description may add to.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        current: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        run: Option<String>,
    },
}

/// Ends the agent run the client started with this id.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct StopRunParams {
    pub run: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct NoteEdit {
    pub before: String,
    pub after: String,
    pub touched: Vec<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum AgentRunAnswer {
    Definition { text: String },
    Note { path: String },
    NoteEdit { edit: NoteEdit },
    RunInput { text: String },
}

/// What a task note's status may be.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq)]
pub enum NoteStatus {
    #[serde(rename = "TODO")]
    Todo,
    #[serde(rename = "IN-PROGRESS")]
    InProgress,
    #[serde(rename = "REVIEW")]
    Review,
    #[serde(rename = "DONE")]
    Done,
    #[serde(rename = "CANCELED")]
    Canceled,
}

impl NoteStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            NoteStatus::Todo => "TODO",
            NoteStatus::InProgress => "IN-PROGRESS",
            NoteStatus::Review => "REVIEW",
            NoteStatus::Done => "DONE",
            NoteStatus::Canceled => "CANCELED",
        }
    }
}

/// A task note and the status a person sets it to.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct NoteStatusParams {
    pub path: String,
    pub status: NoteStatus,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct NoteRestoreParams {
    pub path: String,
    pub before: String,
    pub after: String,
}

// ---------------------------------------------------------------------------------------------
// Definitions
// ---------------------------------------------------------------------------------------------

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct DraftDefinition {
    pub kind: DefinitionDraftKind,
    pub name: String,
    pub text: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct PreviewParams {
    pub draft: DraftDefinition,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum NewDefinition {
    Definition { name: String, text: String },
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "mode", rename_all = "lowercase")]
pub enum DefinitionWriteParams {
    Create {
        #[serde(flatten)]
        item: NewDefinition,
    },
    /// Refused when the file is not what the caller read.
    Replace {
        path: String,
        previous: String,
        text: String,
    },
    /// A definition file is removed.
    Delete { path: String },
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct WrittenPath {
    pub path: String,
}

// ---------------------------------------------------------------------------------------------
// Runs of a pipeline
// ---------------------------------------------------------------------------------------------

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct RunStartParams {
    pub pipeline: String,
    #[serde(default)]
    pub input: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub folder: Option<String>,
    /// The run's name; the engine checks it.
    #[serde(default, rename = "runName", skip_serializing_if = "Option::is_none")]
    pub run_name: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ExecutionId {
    pub execution_id: String,
}

/// What a running pipeline is asked over its socket.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "command", rename_all = "lowercase")]
pub enum RunRequest {
    Info,
    State,
    Pipeline,
    Events {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        after: Option<u64>,
    },
    Query {
        expression: Value,
    },
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct RunAskParams {
    pub execution_id: String,
    pub request: RunRequest,
}

/// What the run answered: `ok` with a result, or not with why.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct RunAnswer {
    pub ok: bool,
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    pub result: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

fn present<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<Option<Value>, D::Error> {
    Value::deserialize(deserializer).map(Some)
}

// ---------------------------------------------------------------------------------------------
// The folder of a vault
// ---------------------------------------------------------------------------------------------

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct VaultInfo {
    pub path: String,
    pub exists: bool,
    pub has_index: bool,
    pub is_git: bool,
    pub notes: u64,
    pub capped: bool,
}

// ---------------------------------------------------------------------------------------------
// Code graphs
// ---------------------------------------------------------------------------------------------

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "action", rename_all = "lowercase")]
pub enum GraphRepoParams {
    Check { path: String },
    Find { namespace: String },
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct GraphRepoCheck {
    pub key: Option<String>,
    pub error: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct GraphRepoMatches {
    pub paths: Vec<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "action", rename_all = "lowercase")]
pub enum GraphRepoAnswer {
    Check { check: GraphRepoCheck },
    Find { matches: GraphRepoMatches },
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct NamespaceParams {
    pub namespace: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct GraphFinding {
    pub node: String,
    pub reason: String,
}

/// What one of the health checks found, or why it could not run.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(untagged)]
pub enum GraphCheck {
    Found {
        ok: bool,
        findings: Vec<GraphFinding>,
    },
    Failed {
        ok: bool,
        error: String,
    },
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct GraphHealth {
    pub stale: GraphCheck,
    pub drift: GraphCheck,
    pub grounding: GraphCheck,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum GraphAction {
    Plan,
    Apply,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum GraphWhat {
    Drop,
    Clean,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct GraphManageParams {
    pub action: GraphAction,
    pub what: GraphWhat,
    pub namespace: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct GraphPlan {
    pub lines: Vec<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(tag = "action", rename_all = "lowercase")]
pub enum GraphManageAnswer {
    Plan { plan: GraphPlan },
    Apply { output: String },
}

// ---------------------------------------------------------------------------------------------
// The host itself
// ---------------------------------------------------------------------------------------------

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum FindingStatus {
    Ok,
    Warn,
    Fail,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct DoctorFinding {
    pub key: String,
    pub name: String,
    pub status: FindingStatus,
    pub detail: String,
    pub value: String,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Counts {
    pub ok: u64,
    pub warn: u64,
    pub fail: u64,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Diagnosis {
    pub findings: Vec<DoctorFinding>,
    pub counts: Counts,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct BundledSynapse {
    pub version: Option<String>,
    pub hook: Option<String>,
    pub content_root: Option<String>,
    pub pipeline_root: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum IntegrationState {
    Absent,
    Current,
    Different,
    Broken,
    Installed,
    Newer,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Integration {
    pub harness: Harness,
    pub state: IntegrationState,
    pub hook: Option<String>,
    pub version: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Integrations {
    pub bundled: BundledSynapse,
    pub harnesses: Vec<Integration>,
}

// ---------------------------------------------------------------------------------------------
// Terminal sessions
// ---------------------------------------------------------------------------------------------

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
pub enum TerminalKind {
    Shell,
    Pipeline,
    Claude,
    Codex,
    Opencode,
}

#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum TerminalTask {
    Init,
    RebuildDiff,
    RebuildFull,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct TerminalStartParams {
    pub session: String,
    pub title: String,
    pub kind: TerminalKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<TerminalTask>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pipeline: Option<String>,
    #[serde(
        default,
        deserialize_with = "present",
        skip_serializing_if = "Option::is_none"
    )]
    pub input: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume: Option<String>,
    /// The name of a pipeline run; the engine checks it.
    #[serde(default, rename = "runName", skip_serializing_if = "Option::is_none")]
    pub run_name: Option<String>,
    pub cols: u16,
    pub rows: u16,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct TerminalAttachParams {
    pub session: String,
    pub cols: u16,
    pub rows: u16,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct TerminalInfo {
    pub session: String,
    pub title: String,
    pub kind: TerminalKind,
    pub cwd: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<TerminalTask>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pipeline: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub execution_id: Option<String>,
    pub loaded: bool,
    pub note: String,
    pub exited: Option<i32>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct TerminalList {
    pub sessions: Vec<TerminalInfo>,
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct TerminalCloseParams {
    pub session: String,
}

// ---------------------------------------------------------------------------------------------
// The rules of the parameters
// ---------------------------------------------------------------------------------------------

macro_rules! no_rules {
    ($($type:ty),* $(,)?) => { $(impl Validate for $type {})* };
}

no_rules!(
    Value,
    Nothing,
    PathParams,
    CliParams,
    ConfigSet,
    RegistryListParams,
    ModelsParams,
    HistoryParams
);

impl Validate for RegistryAddParams {
    fn check(&self) -> Result<(), String> {
        match self {
            RegistryAddParams::Projects { name, prefix } => {
                within("a project name", name, 1, 64)?;
                within("a prefix", prefix, 1, 32)
            }
            RegistryAddParams::Conventions { id, entry } => {
                within("an id", id, 1, 64)?;
                within("an entry", entry, 1, 1000)
            }
        }
    }
}

impl Validate for RegistryRemoveParams {
    fn check(&self) -> Result<(), String> {
        within("an id", &self.id, 1, 64)?;
        within("an entry", &self.entry, 1, 1000)
    }
}

fn agent_choice(model: &Option<String>) -> Result<(), String> {
    match model {
        Some(model) => named("model", is_model_name(model), model),
        None => Ok(()),
    }
}

fn run_choice(run: &Option<String>) -> Result<(), String> {
    match run {
        Some(run) => named("run id", is_execution_id(run), run),
        None => Ok(()),
    }
}

impl Validate for AgentRunParams {
    fn check(&self) -> Result<(), String> {
        match self {
            AgentRunParams::Definition {
                prompt,
                model,
                current,
                definitions,
                run,
                ..
            } => {
                within("the prompt", prompt, 1, 20_000)?;
                agent_choice(model)?;
                run_choice(run)?;
                if let Some(current) = current {
                    at_most("the text", current, DRAFT)?;
                }
                if definitions.len() > 1000 {
                    return Err("at most 1000 definitions".into());
                }
                for definition in definitions {
                    named(
                        "definition name",
                        is_definition_name(&definition.name),
                        &definition.name,
                    )?;
                }
                Ok(())
            }
            AgentRunParams::Note {
                prompt,
                model,
                project,
                run,
                ..
            } => {
                within("the prompt", prompt, 1, 20_000)?;
                agent_choice(model)?;
                run_choice(run)?;
                match project {
                    Some(project) => within("the project", project, 1, 64),
                    None => Ok(()),
                }
            }
            AgentRunParams::NoteEdit {
                path,
                prompt,
                model,
                run,
                ..
            } => {
                within("the path", path, 1, 1024)?;
                within("the prompt", prompt, 1, 20_000)?;
                run_choice(run)?;
                agent_choice(model)
            }
            AgentRunParams::RunInput {
                pipeline,
                prompt,
                model,
                current,
                run,
                ..
            } => {
                named("definition name", is_definition_name(pipeline), pipeline)?;
                within("the prompt", prompt, 1, 20_000)?;
                if let Some(current) = current {
                    at_most("the text", current, DRAFT)?;
                }
                agent_choice(model)?;
                run_choice(run)
            }
        }
    }
}

impl Validate for NoteStatusParams {
    fn check(&self) -> Result<(), String> {
        within("the path", &self.path, 1, 1024)
    }
}

impl Validate for NoteRestoreParams {
    fn check(&self) -> Result<(), String> {
        within("the path", &self.path, 1, 1024)?;
        at_most("the text", &self.before, DRAFT)?;
        at_most("the text", &self.after, DRAFT)
    }
}

impl Validate for PreviewParams {
    fn check(&self) -> Result<(), String> {
        named(
            "definition name",
            is_definition_name(&self.draft.name),
            &self.draft.name,
        )?;
        at_most("the text", &self.draft.text, DRAFT)
    }
}

impl Validate for DefinitionWriteParams {
    fn check(&self) -> Result<(), String> {
        match self {
            DefinitionWriteParams::Create {
                item: NewDefinition::Definition { name, text },
            } => {
                named("definition name", is_definition_name(name), name)?;
                at_most("the text", text, DRAFT)
            }
            DefinitionWriteParams::Replace { previous, text, .. } => {
                at_most("the text", previous, DRAFT)?;
                at_most("the text", text, DRAFT)
            }
            DefinitionWriteParams::Delete { .. } => Ok(()),
        }
    }
}

impl Validate for RunStartParams {
    fn check(&self) -> Result<(), String> {
        let ok = self
            .pipeline
            .chars()
            .next()
            .is_some_and(|c| c.is_ascii_alphabetic())
            && self
                .pipeline
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '_');
        named("pipeline name", ok, &self.pipeline)?;
        run_name_ok(self.run_name.as_deref())
    }
}

/// A run's name is 1 to 480 bytes with no NUL; the engine checks the rest.
fn run_name_ok(name: Option<&str>) -> Result<(), String> {
    match name {
        Some(name) if name.is_empty() || name.len() > 480 || name.contains('\0') => {
            Err("the run name is 1 to 480 bytes with no NUL".into())
        }
        _ => Ok(()),
    }
}

impl Validate for StopRunParams {
    fn check(&self) -> Result<(), String> {
        named("run id", is_execution_id(&self.run), &self.run)
    }
}

impl Validate for ExecutionIdParams {
    fn check(&self) -> Result<(), String> {
        named(
            "run id",
            is_execution_id(&self.execution_id),
            &self.execution_id,
        )
    }
}

impl Validate for RunAskParams {
    fn check(&self) -> Result<(), String> {
        named(
            "run id",
            is_execution_id(&self.execution_id),
            &self.execution_id,
        )
    }
}

impl Validate for GraphRepoParams {
    fn check(&self) -> Result<(), String> {
        match self {
            GraphRepoParams::Check { path } => within("the path", path, 1, 4096),
            GraphRepoParams::Find { namespace } => {
                named("graph", is_namespace(namespace), namespace)
            }
        }
    }
}

impl Validate for NamespaceParams {
    fn check(&self) -> Result<(), String> {
        named("graph", is_namespace(&self.namespace), &self.namespace)
    }
}

impl Validate for GraphManageParams {
    fn check(&self) -> Result<(), String> {
        named("graph", is_namespace(&self.namespace), &self.namespace)
    }
}

/// A commit named by a page: 7 to 64 hexadecimal digits, so that git never reads it as an option.
pub fn is_commit_id(id: &str) -> bool {
    (7..=64).contains(&id.len())
        && id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

impl Validate for ChangesLogParams {
    fn check(&self) -> Result<(), String> {
        within("the folder", &self.folder, 1, 4096)?;
        if !(1..=200).contains(&self.limit) {
            return Err(format!("{} is not a limit from 1 to 200", self.limit));
        }
        match &self.before {
            Some(before) => named("commit", is_commit_id(before), before),
            None => Ok(()),
        }
    }
}

impl Validate for ChangesCommitParams {
    fn check(&self) -> Result<(), String> {
        within("the folder", &self.folder, 1, 4096)?;
        named("commit", is_commit_id(&self.commit), &self.commit)?;
        match &self.path {
            Some(path) => within("the path", path, 1, 4096),
            None => Ok(()),
        }
    }
}

/// A git tree id: 40 hexadecimal digits, or 64 for a repository that uses SHA-256.
fn is_tree_id(id: &str) -> bool {
    (id.len() == 40 || id.len() == 64)
        && id
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

impl Validate for ChangesSnapshotParams {
    fn check(&self) -> Result<(), String> {
        within("the folder", &self.folder, 1, 4096)
    }
}

impl Validate for ChangesDiffParams {
    fn check(&self) -> Result<(), String> {
        within("the folder", &self.folder, 1, 4096)?;
        named("snapshot", is_tree_id(&self.before), &self.before)?;
        if let Some(after) = &self.after {
            named("snapshot", is_tree_id(after), after)?;
        }
        match &self.path {
            Some(path) => within("the path", path, 1, 4096),
            None => Ok(()),
        }
    }
}

/// Where a run's snapshot is pinned, under `refs/synapse/`: `runs/<execution-id>/start` or
/// `runs/<execution-id>/end`, the id 1 to 64 letters, digits, `_` and `-`.
pub fn is_pin_ref(reference: &str) -> bool {
    let Some(rest) = reference.strip_prefix("runs/") else {
        return false;
    };
    let Some((id, end)) = rest.split_once('/') else {
        return false;
    };
    session_ok(id) && (end == "start" || end == "end")
}

impl Validate for ChangesPinParams {
    fn check(&self) -> Result<(), String> {
        within("the folder", &self.folder, 1, 4096)?;
        named("snapshot ref", is_pin_ref(&self.reference), &self.reference)?;
        named("snapshot", is_tree_id(&self.tree), &self.tree)
    }
}

impl Validate for ChangesUnpinParams {
    fn check(&self) -> Result<(), String> {
        within("the folder", &self.folder, 1, 4096)?;
        named("snapshot ref", is_pin_ref(&self.reference), &self.reference)
    }
}

impl Validate for VaultPathParams {
    fn check(&self) -> Result<(), String> {
        within("the path", &self.path, 1, 4096)
    }
}

fn session_ok(id: &str) -> bool {
    (1..=64).contains(&id.len())
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
}

impl Validate for TerminalStartParams {
    fn check(&self) -> Result<(), String> {
        named("session name", session_ok(&self.session), &self.session)?;
        within("the title", &self.title, 1, 100)?;
        if let Some(cwd) = &self.cwd {
            within("the folder", cwd, 1, 4096)?;
        }
        if let Some(pipeline) = &self.pipeline {
            let ok = pipeline.len() <= 128
                && pipeline
                    .chars()
                    .next()
                    .is_some_and(|c| c.is_ascii_alphabetic())
                && pipeline
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '_');
            named("pipeline name", ok, pipeline)?;
        }
        if let Some(resume) = &self.resume {
            let ok = resume.len() <= 128
                && resume
                    .chars()
                    .next()
                    .is_some_and(|c| c.is_ascii_alphanumeric())
                && resume
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-');
            named("session to resume", ok, resume)?;
        }
        run_name_ok(self.run_name.as_deref())?;
        size_ok(self.cols, self.rows)
    }
}

fn size_ok(cols: u16, rows: u16) -> Result<(), String> {
    if (1..=1000).contains(&cols) && (1..=1000).contains(&rows) {
        Ok(())
    } else {
        Err("the size is 1 to 1000 columns and rows".into())
    }
}

impl Validate for TerminalAttachParams {
    fn check(&self) -> Result<(), String> {
        named("session name", session_ok(&self.session), &self.session)?;
        size_ok(self.cols, self.rows)
    }
}

impl Validate for TerminalCloseParams {
    fn check(&self) -> Result<(), String> {
        named("session name", session_ok(&self.session), &self.session)
    }
}

// ---------------------------------------------------------------------------------------------
// The table
// ---------------------------------------------------------------------------------------------

/// The table of requests, with what each takes and answers. It makes the list of names, and what the
/// tests do with each: read its example as its types and write it back.
macro_rules! messages {
    ($($name:literal => $params:ty, $result:ty;)*) => {
        /// Every request the host answers.
        pub const NAMES: &[&str] = &[$($name),*];

        fn round<T: serde::de::DeserializeOwned + Serialize>(value: &Value) -> Result<Value, String> {
            let typed: T = serde_json::from_value(value.clone()).map_err(|e| e.to_string())?;
            serde_json::to_value(typed).map_err(|e| e.to_string())
        }

        /// The example parameters of `name`, read as its type and written again.
        pub fn roundtrip_params(name: &str, value: &Value) -> Result<Value, String> {
            match name {
                $($name => round::<$params>(value),)*
                _ => Err(format!("there is no message {name}")),
            }
        }

        /// Whether the parameters are the type the message takes and keep to its rules.
        pub fn check_params(name: &str, value: &Value) -> Result<(), String> {
            match name {
                $($name => {
                    let typed: $params =
                        serde_json::from_value(value.clone()).map_err(|e| e.to_string())?;
                    Validate::check(&typed)
                })*
                _ => Err(format!("there is no message {name}")),
            }
        }

        /// The same for the result.
        pub fn roundtrip_result(name: &str, value: &Value) -> Result<Value, String> {
            match name {
                $($name => round::<$result>(value),)*
                _ => Err(format!("there is no message {name}")),
            }
        }

        /// Makes `handlers` answer `name` with `result`, once the parameters are read as the type the
        /// message takes. For the tests, which answer each message with its example.
        pub fn answer_with(handlers: &mut crate::dispatch::Handlers, name: &'static str, result: Value) {
            match name {
                $($name => handlers.on::<$params, $result, _, _>(name, move |_params| {
                    let result = result.clone();
                    async move {
                        serde_json::from_value::<$result>(result)
                            .map_err(|e| crate::dispatch::HostError::internal(e.to_string()))
                    }
                }),)*
                _ => panic!("there is no message {name}"),
            }
        }
    };
}

messages! {
    "fs.read" => PathParams, Text;
    "fs.list" => PathParams, Entries;
    "cli" => CliParams, CliResult;
    "config.get" => Nothing, ConfigAnswer;
    "config.set" => ConfigSet, ConfigAnswer;
    "registry.list" => RegistryListParams, RegistryAnswer;
    "registry.add" => RegistryAddParams, RegistryAnswer;
    "registry.remove" => RegistryRemoveParams, ConventionsAnswer;
    "models.get" => ModelsParams, ModelCatalog;
    "history.get" => HistoryParams, HistoryAnswer;
    "agent.run" => AgentRunParams, AgentRunAnswer;
    "agent.stop" => StopRunParams, ();
    "note.status" => NoteStatusParams, ();
    "note.restore" => NoteRestoreParams, ();
    "definition.preview" => PreviewParams, CliResult;
    "definition.write" => DefinitionWriteParams, WrittenPath;
    "run.start" => RunStartParams, ExecutionId;
    "run.stop" => ExecutionIdParams, ();
    "run.ask" => RunAskParams, RunAnswer;
    "changes.snapshot" => ChangesSnapshotParams, SnapshotAnswer;
    "changes.diff" => ChangesDiffParams, FolderChanges;
    "changes.pin" => ChangesPinParams, ();
    "changes.unpin" => ChangesUnpinParams, ();
    "changes.log" => ChangesLogParams, CommitLog;
    "changes.commit" => ChangesCommitParams, FolderChanges;
    "vault.inspect" => VaultPathParams, VaultInfo;
    "vault.seed" => VaultPathParams, VaultInfo;
    "graph.repo" => GraphRepoParams, GraphRepoAnswer;
    "graph.health" => NamespaceParams, GraphHealth;
    "graph.manage" => GraphManageParams, GraphManageAnswer;
    "terminal.start" => TerminalStartParams, TerminalInfo;
    "terminal.attach" => TerminalAttachParams, TerminalInfo;
    "terminal.list" => Nothing, TerminalList;
    "terminal.close" => TerminalCloseParams, ();
    "diagnose" => Nothing, Diagnosis;
    "integrations" => Nothing, Integrations;
}

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ExecutionIdParams {
    pub execution_id: String,
}
