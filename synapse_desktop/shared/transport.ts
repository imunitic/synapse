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
  startRun(pipeline: string, input: unknown): Promise<{ executionId: string }>
  // Only for runs this app started.
  stopRun(executionId: string): Promise<void>

  getConfig(): Promise<AppConfig>
  getPaths(): Promise<AppPaths>
  setConfig(patch: Partial<AppConfig>): Promise<AppConfig>
}
