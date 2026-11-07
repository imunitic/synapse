// The contract between the UI and whatever gives it access to the machine: the
// local Node server in the web phase, Tauri commands later. The UI and the
// domain layer depend on this interface only.

export type Unsubscribe = () => void

export type Harness = 'Claude' | 'Codex' | 'Opencode'

export interface DirEntry {
  name: string
  isDir: boolean
  mtimeMs: number
}

export interface AppConfig {
  // Where runs keep their records; null until set.
  workDir: string | null
  // Directories of .synapse files besides the default one.
  definitionPaths: string[]
  defaultHarness: Harness | null
  // Variables set for every process the app starts, over those it was started
  // with.
  env: Record<string, string>
  // Vaults the app has switched to, newest first.
  recentVaults: string[]
  // Where a new terminal starts; the home folder without one.
  terminalFolder: string | null
  // The folder of the repository a code graph was built from, by namespace.
  graphRepos: Record<string, string>
}

// What a folder that may be a vault holds.
export interface VaultInfo {
  // The folder is there.
  exists: boolean
  hasIndex: boolean
  isGit: boolean
  // Markdown files outside the folders that start with a dot.
  notes: number
  // The count stopped before the end of the folder.
  capped: boolean
}

// What a running pipeline answers over its socket (a named pipe on Windows):
// one request, one answer.
export type RunRequest =
  | { command: 'info' }
  | { command: 'state' }
  | { command: 'pipeline' }
  | { command: 'events'; after?: number }
  | { command: 'query'; expression: unknown }

// Where the app looks, with only the directories that exist.
export interface AppPaths {
  // Directories of .synapse files.
  definitionDirs: string[]
  skillsDir: string | null
  // The work directory's pipelines folder, where each run keeps its record.
  recordsDir: string | null
}

export type RunAnswer = { ok: true; result: unknown } | { ok: false; error: string }

// Text that is being written and is not saved: a pipeline, a system or an agent.
export interface DraftDefinition {
  kind: 'pipeline' | 'system' | 'agent'
  // The name the text declares, which is the name of its file.
  name: string
  text: string
}

// A definition file, or the SKILL.md of a skill, to be made.
export interface NewDefinition {
  kind: 'definition' | 'skill'
  name: string
  text: string
}

// A description to have an agent write a definition from. What exists is given
// so that the text reuses it and does not take a name that is used.
export interface GenerateRequest {
  kind: 'pipeline' | 'system' | 'agent' | 'skill'
  prompt: string
  // The harness that writes it; the default harness when absent.
  harness?: Harness
  // The text to change, when the prompt asks for a change to a definition that
  // exists and not for a new one.
  current?: string
  definitions: { name: string; kind: 'pipeline' | 'system' | 'agent' }[]
  skills: string[]
}

export type TerminalKind = 'Shell' | Harness

// What a session of a harness is started to do: build a code graph, rebuild what
// changed in it, or rebuild it from scratch.
export type TerminalTask = 'init' | 'rebuild-diff' | 'rebuild-full'

export interface TerminalStart {
  kind: TerminalKind
  // Where to start it; the home folder without one.
  cwd?: string
  // What a harness is started to do, given to it as its first prompt.
  task?: TerminalTask
  cols: number
  rows: number
}

export interface TerminalListener {
  onStarted(info: { loaded: boolean; note: string }): void
  onOutput(data: string): void
  // The program ended, with its exit code.
  onExit(code: number): void
  // The session could not start, or the connection failed.
  onError(message: string): void
  // The conversation of a harness started in the session: its source is made
  // known, and then lines of its session file come as they are appended.
  onTranscript(event: TerminalTranscript): void
}

export type TerminalTranscript =
  | { kind: 'source'; id: string; harness: 'Claude' | 'Codex'; cwd: string }
  | { kind: 'lines'; id: string; lines: string[] }

export interface TerminalHandle {
  write(data: string): void
  resize(cols: number, rows: number): void
  // Ends the session and the program with it.
  close(): void
}

// Whether a harness has Synapse installed, and from where.
export type IntegrationState =
  // The harness has no hook of Synapse.
  | 'absent'
  // The hook is the one of the Synapse this app runs, or of the same version.
  | 'current'
  // The hook is of another copy, or another version.
  | 'different'
  // The harness names a hook program that is not there.
  | 'broken'
  // There is a hook, and no Synapse of the app's own to compare it with.
  | 'installed'
  // The hook is of a newer version than the Synapse the app has.
  | 'newer'

export interface Integration {
  harness: Harness
  state: IntegrationState
  // The hook program the harness runs, as it names it.
  hook: string | null
  // The version of the Synapse that program belongs to.
  version: string | null
}

// The Synapse this app would install, found as the programs on PATH and the
// packages they belong to.
export interface BundledSynapse {
  version: string | null
  hook: string | null
  contentRoot: string | null
  pipelineRoot: string | null
}

export interface Integrations {
  bundled: BundledSynapse
  harnesses: Integration[]
}

// What a folder says about the code graph it is the repository of.
export interface GraphRepoCheck {
  // The `<repo>@<branch>` of the folder as it is checked out now, or null when
  // it is not a repository on a branch.
  key: string | null
  // Why there is no key.
  error: string | null
}

// A finding about a node of a graph, or about the repository as a whole.
export interface GraphFinding {
  // The node's name, or `(repo)` for the repository.
  node: string
  reason: string
}

// What one of the health checks found, or why it could not run.
export type GraphCheck = { ok: true; findings: GraphFinding[] } | { ok: false; error: string }

export interface GraphHealth {
  // Nodes whose files no longer match what they were written from.
  stale: GraphCheck
  // What changed since each node's commit.
  drift: GraphCheck
  // Nodes whose evidence no longer matches.
  grounding: GraphCheck
}

// What deleting a graph, or cleaning up the graphs of branches that are gone,
// would remove: the lines the program prints for a dry run.
export interface GraphPlan {
  lines: string[]
}

export type CliBinary = 'synapse-pipeline' | 'synapse'

export interface CliOptions {
  stdin?: string
}

export interface CliResult {
  code: number
  stdout: string
  stderr: string
}

export interface Transport {
  // Files, limited to the allowed roots: the work directory's pipelines folder
  // and the definition directories.
  readText(path: string): Promise<string>
  readDir(path: string): Promise<DirEntry[]>
  watch(path: string, onChange: () => void): Unsubscribe

  runRequest(executionId: string, request: RunRequest): Promise<RunAnswer>

  // A typed allowlist of binaries and subcommands, never a generic exec.
  cli(binary: CliBinary, args: string[], options?: CliOptions): Promise<CliResult>
  // What `synapse-pipeline` says about the draft as if it were saved among the
  // definitions: `show --format json` for a pipeline, and `check` of a pipeline
  // that stands for the others, whose warnings name the draft when it is wrong.
  previewDraft(draft: DraftDefinition): Promise<CliResult>
  // Makes the file in the default definition directory. It never replaces one.
  writeDefinition(item: NewDefinition): Promise<{ path: string }>

  // The text of a definition, or of a skill's SKILL.md, that an agent wrote from
  // the description. Nothing is saved.
  // Replaces the text of a definition file, or a skill's SKILL.md, in the
  // definition directories. It is refused when the file no longer holds what
  // `previous` says it did.
  saveDefinition(path: string, previous: string, text: string): Promise<void>
  generateDefinition(request: GenerateRequest): Promise<{ text: string }>

  // Starts the user's login shell, or a harness, in a pty. The bundled Synapse is
  // loaded for the session, or for the harnesses started from the shell, unless
  // a harness has it installed. What the program prints comes to the
  // listener; what is typed goes through the handle.
  openTerminal(start: TerminalStart, listener: TerminalListener): TerminalHandle

  startRun(pipeline: string, input: unknown): Promise<{ executionId: string }>
  // Only for runs this app started.
  stopRun(executionId: string): Promise<void>

  // Looks at a folder, which may be anywhere, and changes nothing.
  inspectVault(path: string): Promise<VaultInfo>

  // What each harness has installed of Synapse, and what this app would install.
  getIntegrations(): Promise<Integrations>
  // Installs Synapse and its pipeline skills for the harness, as
  // `synapse configure` and `synapse-pipeline configure` do. It writes into the
  // harness's own configuration, so it is only done when asked for.
  configureHarness(harness: Harness): Promise<{ output: string }>

  // The namespace of a folder that is the repository of a graph.
  checkGraphRepo(path: string): Promise<GraphRepoCheck>
  // Reads a graph against the repository saved for its namespace.
  graphHealth(namespace: string): Promise<GraphHealth>
  // What deleting the graph of a namespace would remove, and then removing it.
  planGraphDrop(namespace: string): Promise<GraphPlan>
  dropGraph(namespace: string): Promise<{ output: string }>
  // The same for the graphs of the saved repository whose branch is gone upstream.
  planGraphClean(namespace: string): Promise<GraphPlan>
  cleanGraphs(namespace: string): Promise<{ output: string }>

  getConfig(): Promise<AppConfig>
  getPaths(): Promise<AppPaths>
  setConfig(patch: Partial<AppConfig>): Promise<AppConfig>
}
