// The Transport the pages use, over a Bus: each method is one message, or a choice inside one.
// The pages keep the interface they had; what changed is what is behind it.

import type { Bus } from '../../shared/bus.ts'
import type { CommitLog, FolderChanges, Snapshot } from '../../shared/changes.ts'
import type { NoteStatus, Params } from '../../shared/messages.ts'
import type {
  AppConfig,
  AppPaths,
  CliBinary,
  CliOptions,
  CliResult,
  ConventionList,
  Diagnosis,
  DirEntry,
  DraftDefinition,
  EditNoteRequest,
  GenerateRequest,
  GraphHealth,
  GraphPlan,
  GraphRepoCheck,
  GraphRepoMatches,
  Harness,
  Integrations,
  ModelCatalog,
  NewDefinition,
  NoteEdit,
  NoteRequest,
  PastSessions,
  ProjectList,
  RunAnswer,
  RunInputRequest,
  RunRequest,
  TerminalHandle,
  TerminalInfo,
  TerminalListener,
  TerminalStart,
  Transport,
  Unsubscribe,
  VaultInfo,
  WatchPlace,
  Workspaces,
} from '../../shared/transport.ts'
import { terminalHostStreamSchema } from '../../shared/terminal.ts'
import { usageEventSchema, type UsageEvent } from '../../shared/usage.ts'

// How many commits the Git tab asks for at a time.
const COMMIT_PAGE = 50

type Graph = Params<'graph.manage'>

export class BusTransport implements Transport {
  private readonly get: () => Bus

  // The bus is asked for when it is first used, so that what only imports the Transport opens
  // no connection.
  constructor(bus: Bus | (() => Bus)) {
    this.get = typeof bus === 'function' ? bus : () => bus
  }

  private get bus(): Bus {
    return this.get()
  }

  async readText(path: string): Promise<string> {
    return (await this.bus.request('fs.read', { path })).text
  }

  async readDir(path: string): Promise<DirEntry[]> {
    return (await this.bus.request('fs.list', { path })).entries
  }

  cli(binary: CliBinary, args: string[], options?: CliOptions): Promise<CliResult> {
    return this.bus.request('cli', { binary, args, stdin: options?.stdin })
  }

  previewDraft(draft: DraftDefinition): Promise<CliResult> {
    return this.bus.request('definition.preview', { draft })
  }

  writeDefinition(item: NewDefinition): Promise<{ path: string }> {
    return this.bus.request('definition.write', { mode: 'create', ...item })
  }

  async saveDefinition(path: string, previous: string, text: string): Promise<void> {
    await this.bus.request('definition.write', { mode: 'replace', path, previous, text })
  }

  async deleteDefinition(path: string): Promise<void> {
    await this.bus.request('definition.write', { mode: 'delete', path })
  }

  snapshotChanges(folder: string, of?: 'head'): Promise<Snapshot> {
    return this.bus.request('changes.snapshot', { folder, ...(of === undefined ? {} : { of }) })
  }

  diffChanges(
    folder: string,
    before: string,
    path?: string,
    after?: string,
  ): Promise<FolderChanges> {
    return this.bus.request('changes.diff', {
      folder,
      before,
      ...(path === undefined ? {} : { path }),
      ...(after === undefined ? {} : { after }),
    })
  }

  async pinSnapshot(folder: string, ref: string, tree: string): Promise<void> {
    await this.bus.request('changes.pin', { folder, ref, tree })
  }

  async unpinSnapshot(folder: string, ref: string): Promise<void> {
    await this.bus.request('changes.unpin', { folder, ref })
  }
  // A page of the Git tab: as many commits as it shows at a time.
  listCommits(folder: string, before?: string): Promise<CommitLog> {
    return this.bus.request('changes.log', {
      folder,
      limit: COMMIT_PAGE,
      ...(before === undefined ? {} : { before }),
    })
  }

  commitChanges(folder: string, commit: string, path?: string): Promise<FolderChanges> {
    return this.bus.request('changes.commit', {
      folder,
      commit,
      ...(path === undefined ? {} : { path }),
    })
  }

  async generateDefinition(request: GenerateRequest): Promise<{ text: string }> {
    const { kind: what, ...rest } = request
    const answer = await this.bus.request('agent.run', { kind: 'definition', what, ...rest })
    if (answer.kind !== 'definition') throw new Error('the host answered another message')
    return { text: answer.text }
  }

  async createNote(request: NoteRequest): Promise<{ path: string }> {
    const { kind: what, ...rest } = request
    const answer = await this.bus.request('agent.run', { kind: 'note', what, ...rest })
    if (answer.kind !== 'note') throw new Error('the host answered another message')
    return { path: answer.path }
  }

  async editNote(request: EditNoteRequest): Promise<NoteEdit> {
    const answer = await this.bus.request('agent.run', { kind: 'note-edit', ...request })
    if (answer.kind !== 'note-edit') throw new Error('the host answered another message')
    return answer.edit
  }

  async fillRunInput(request: RunInputRequest): Promise<{ text: string }> {
    const answer = await this.bus.request('agent.run', { kind: 'run-input', ...request })
    if (answer.kind !== 'run-input') throw new Error('the host answered another message')
    return { text: answer.text }
  }

  async stopAgentRun(run: string): Promise<void> {
    await this.bus.request('agent.stop', { run })
  }

  // The lines a run publishes, as the host got them from the agent.
  watchNoteRun(run: string, onLine: (line: string) => void): Unsubscribe {
    return this.bus.subscribe(`note-run.${run}`, (data) => {
      const line = (data as { line?: unknown } | null)?.line
      if (typeof line === 'string') onLine(line)
    })
  }

  async setNoteStatus(path: string, status: NoteStatus): Promise<void> {
    await this.bus.request('note.status', { path, status })
  }

  async restoreNote(path: string, before: string, after: string): Promise<void> {
    await this.bus.request('note.restore', { path, before, after })
  }

  async listProjects(): Promise<ProjectList> {
    return this.projects(await this.bus.request('registry.list', { kind: 'projects' }))
  }

  async addProject(name: string, prefix: string): Promise<ProjectList> {
    return this.projects(await this.bus.request('registry.add', { kind: 'projects', name, prefix }))
  }

  async listConventions(): Promise<ConventionList> {
    return this.conventions(await this.bus.request('registry.list', { kind: 'conventions' }))
  }

  async addConvention(id: string, entry: string): Promise<ConventionList> {
    return this.conventions(
      await this.bus.request('registry.add', { kind: 'conventions', id, entry }),
    )
  }

  async removeConvention(id: string, entry: string): Promise<ConventionList> {
    return this.conventions(
      await this.bus.request('registry.remove', { kind: 'conventions', id, entry }),
    )
  }

  getDiagnosis(): Promise<Diagnosis> {
    return this.bus.request('diagnose', {})
  }

  async listWorkspaces(): Promise<Workspaces> {
    const answer = await this.bus.request('history.get', { what: 'workspaces' })
    if (answer.what !== 'workspaces') throw new Error('the host answered another message')
    return answer.workspaces
  }

  async listSessions(): Promise<PastSessions> {
    const answer = await this.bus.request('history.get', { what: 'sessions' })
    if (answer.what !== 'sessions') throw new Error('the host answered another message')
    return answer.sessions
  }

  listModels(harness: Harness): Promise<ModelCatalog> {
    return this.bus.request('models.get', { harness })
  }

  refreshModels(harness: Harness): Promise<ModelCatalog> {
    return this.bus.request('models.get', { harness, refresh: true })
  }

  seedVault(path: string): Promise<VaultInfo> {
    return this.bus.request('vault.seed', { path })
  }

  inspectVault(path: string): Promise<VaultInfo> {
    return this.bus.request('vault.inspect', { path })
  }

  async checkGraphRepo(path: string): Promise<GraphRepoCheck> {
    const answer = await this.bus.request('graph.repo', { action: 'check', path })
    if (answer.action !== 'check') throw new Error('the host answered another message')
    return answer.check
  }

  async findGraphRepos(namespace: string): Promise<GraphRepoMatches> {
    const answer = await this.bus.request('graph.repo', { action: 'find', namespace })
    if (answer.action !== 'find') throw new Error('the host answered another message')
    return answer.matches
  }

  graphHealth(namespace: string): Promise<GraphHealth> {
    return this.bus.request('graph.health', { namespace })
  }

  planGraphDrop(namespace: string): Promise<GraphPlan> {
    return this.plan({ action: 'plan', what: 'drop', namespace })
  }

  planGraphClean(namespace: string): Promise<GraphPlan> {
    return this.plan({ action: 'plan', what: 'clean', namespace })
  }

  dropGraph(namespace: string): Promise<{ output: string }> {
    return this.apply({ action: 'apply', what: 'drop', namespace })
  }

  cleanGraphs(namespace: string): Promise<{ output: string }> {
    return this.apply({ action: 'apply', what: 'clean', namespace })
  }

  getIntegrations(): Promise<Integrations> {
    return this.bus.request('integrations', {})
  }

  async getConfig(): Promise<AppConfig> {
    return (await this.bus.request('config.get', {})).config
  }

  async getPaths(): Promise<AppPaths> {
    return (await this.bus.request('config.get', {})).paths
  }

  async setConfig(patch: Partial<AppConfig>): Promise<AppConfig> {
    return (await this.bus.request('config.set', { patch })).config
  }

  runRequest(executionId: string, request: RunRequest): Promise<RunAnswer> {
    return this.bus.request('run.ask', { executionId, request })
  }

  startRun(
    pipeline: string,
    input: unknown,
    folder?: string,
    runName?: string,
  ): Promise<{ executionId: string }> {
    return this.bus.request('run.start', {
      pipeline,
      input,
      ...(folder === undefined ? {} : { folder }),
      ...(runName === undefined ? {} : { runName }),
    })
  }

  async stopRun(executionId: string): Promise<void> {
    await this.bus.request('run.stop', { executionId })
  }

  watch(place: WatchPlace, onChange: () => void): Unsubscribe {
    return this.bus.subscribe(`files.${place}`, () => onChange())
  }

  // An event that does not parse is dropped: the page keeps the last one it could read.
  watchUsage(onEvent: (event: UsageEvent) => void): Unsubscribe {
    return this.bus.subscribe('usage', (data) => {
      const parsed = usageEventSchema.safeParse(data)
      if (parsed.success) onEvent(parsed.data)
    })
  }

  async listTerminals(): Promise<TerminalInfo[]> {
    return (await this.bus.request('terminal.list', {})).sessions
  }

  async closeTerminal(session: string): Promise<void> {
    await this.bus.request('terminal.close', { session })
  }

  // A terminal is a session the host holds, and the messages of its stream. Closing it ends the
  // session; a connection that is lost leaves it, and is attached again when there is another.
  openTerminal(start: TerminalStart, listener: TerminalListener): TerminalHandle {
    const bus = this.bus
    const id = start.session
    let ended = false
    let running = false
    // Set once the session was started or attached to, which is when a new connection attaches again.
    let claimed = false
    let size = { cols: start.cols, rows: start.rows }
    // What is typed before the program has started waits, and goes to it then.
    const typed: string[] = []

    const stopStream = bus.onStream(id, (raw) => {
      const parsed = terminalHostStreamSchema.safeParse(raw)
      if (!parsed.success || ended) return
      const message = parsed.data
      switch (message.type) {
        case 'snapshot':
          listener.onSnapshot(message.data)
          break
        case 'output':
          listener.onOutput(message.data)
          break
        case 'transcript-source':
          listener.onTranscript({
            kind: 'source',
            id: message.id,
            harness: message.harness,
            cwd: message.cwd,
          })
          break
        case 'transcript':
          listener.onTranscript({ kind: 'lines', id: message.id, lines: message.lines })
          break
        case 'exit':
          ended = true
          running = false
          listener.onExit(message.code)
          break
      }
    })

    const fail = (error: unknown) => {
      if (ended) return
      ended = true
      running = false
      listener.onError(error instanceof Error ? error.message : String(error))
    }

    const onClaimed = (info: TerminalInfo) => {
      if (ended) return
      claimed = true
      running = true
      for (const data of typed.splice(0)) bus.stream(id, { type: 'input', data })
      listener.onStarted({ loaded: info.loaded, note: info.note, cwd: info.cwd })
      if (info.executionId !== undefined) listener.onRun(info.executionId)
    }

    const attach = () => bus.request('terminal.attach', { session: id, ...size })
    const first =
      start.attach === true
        ? attach()
        : bus.request('terminal.start', {
            session: id,
            title: start.title,
            kind: start.kind,
            ...(start.cwd === undefined ? {} : { cwd: start.cwd }),
            ...(start.task === undefined ? {} : { task: start.task }),
            ...(start.pipeline === undefined ? {} : { pipeline: start.pipeline }),
            ...(start.input === undefined ? {} : { input: start.input }),
            ...(start.runName === undefined ? {} : { runName: start.runName }),
            ...(start.resume === undefined ? {} : { resume: start.resume }),
            ...size,
          })
    first.then(onClaimed, fail)

    // After a lost connection the host's session is still there: attach to it on the next.
    const stopHello = bus.onHello(() => {
      if (!claimed || ended) return
      attach().then(onClaimed, (error: unknown) =>
        fail(new Error(`The session is gone: ${String(error)}`)),
      )
    })

    return {
      write: (data) => (running ? bus.stream(id, { type: 'input', data }) : typed.push(data)),
      resize: (cols, rows) => {
        size = { cols, rows }
        if (running) bus.stream(id, { type: 'resize', cols, rows })
      },
      detach: () => {
        ended = true
        stopStream()
        stopHello()
      },
    }
  }

  private projects(answer: { kind: string; list: unknown }): ProjectList {
    if (answer.kind !== 'projects') throw new Error('the host answered another message')
    return answer.list as ProjectList
  }

  private conventions(answer: { kind: string; list: unknown }): ConventionList {
    if (answer.kind !== 'conventions') throw new Error('the host answered another message')
    return answer.list as ConventionList
  }

  private async plan(params: Graph): Promise<GraphPlan> {
    const answer = await this.bus.request('graph.manage', params)
    if (answer.action !== 'plan') throw new Error('the host answered another message')
    return answer.plan
  }

  private async apply(params: Graph): Promise<{ output: string }> {
    const answer = await this.bus.request('graph.manage', params)
    if (answer.action !== 'apply') throw new Error('the host answered another message')
    return { output: answer.output }
  }
}
