// The web-phase Transport: every call is a POST to the local API server.

import { API_PREFIX, TERMINAL_PATH } from '../../shared/constants.ts'
import { serverMessageSchema, type ClientMessage } from '../../shared/terminal.ts'
import type {
  AppConfig,
  AppPaths,
  CliBinary,
  CliOptions,
  CliResult,
  DraftDefinition,
  GenerateRequest,
  GraphHealth,
  Harness,
  GraphPlan,
  GraphRepoCheck,
  GraphRepoMatches,
  NoteEdit,
  NoteRequest,
  EditNoteRequest,
  ConventionList,
  Diagnosis,
  ModelCatalog,
  PastSessions,
  Workspaces,
  ProjectList,
  Integrations,
  NewDefinition,
  DirEntry,
  RunAnswer,
  RunRequest,
  Transport,
  Unsubscribe,
  TerminalHandle,
  TerminalListener,
  TerminalStart,
  VaultInfo,
} from '../../shared/transport.ts'

type Reply<T> = { ok: true; result: T } | { ok: false; error: string }

export class HttpTransport implements Transport {
  private async call<T>(method: string, params: object): Promise<T> {
    const response = await fetch(API_PREFIX + method, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(params),
    })
    const reply = (await response.json()) as Reply<T>
    if (!reply.ok) throw new Error(reply.error)
    return reply.result
  }

  readText(path: string): Promise<string> {
    return this.call('readText', { path })
  }

  readDir(path: string): Promise<DirEntry[]> {
    return this.call('readDir', { path })
  }

  cli(binary: CliBinary, args: string[], options?: CliOptions): Promise<CliResult> {
    return this.call('cli', { binary, args, stdin: options?.stdin })
  }

  previewDraft(draft: DraftDefinition): Promise<CliResult> {
    return this.call('previewDraft', { draft })
  }

  writeDefinition(item: NewDefinition): Promise<{ path: string }> {
    return this.call('writeDefinition', item)
  }

  async saveDefinition(path: string, previous: string, text: string): Promise<void> {
    await this.call('saveDefinition', { path, previous, text })
  }

  generateDefinition(request: GenerateRequest): Promise<{ text: string }> {
    return this.call('generateDefinition', request)
  }

  createNote(request: NoteRequest): Promise<{ path: string }> {
    return this.call('createNote', request)
  }

  editNote(request: EditNoteRequest): Promise<NoteEdit> {
    return this.call('editNote', request)
  }

  async restoreNote(path: string, before: string, after: string): Promise<void> {
    await this.call('restoreNote', { path, before, after })
  }

  listProjects(): Promise<ProjectList> {
    return this.call('listProjects', {})
  }

  addProject(name: string, prefix: string): Promise<ProjectList> {
    return this.call('addProject', { name, prefix })
  }

  getDiagnosis(): Promise<Diagnosis> {
    return this.call('getDiagnosis', {})
  }

  listWorkspaces(): Promise<Workspaces> {
    return this.call('listWorkspaces', {})
  }

  listSessions(): Promise<PastSessions> {
    return this.call('listSessions', {})
  }

  listModels(harness: Harness): Promise<ModelCatalog> {
    return this.call('listModels', { harness })
  }

  seedVault(path: string): Promise<VaultInfo> {
    return this.call('seedVault', { path })
  }

  listConventions(): Promise<ConventionList> {
    return this.call('listConventions', {})
  }

  addConvention(id: string, entry: string): Promise<ConventionList> {
    return this.call('addConvention', { id, entry })
  }

  removeConvention(id: string, entry: string): Promise<ConventionList> {
    return this.call('removeConvention', { id, entry })
  }

  inspectVault(path: string): Promise<VaultInfo> {
    return this.call('inspectVault', { path })
  }

  checkGraphRepo(path: string): Promise<GraphRepoCheck> {
    return this.call('checkGraphRepo', { path })
  }

  findGraphRepos(namespace: string): Promise<GraphRepoMatches> {
    return this.call('findGraphRepos', { namespace })
  }

  graphHealth(namespace: string): Promise<GraphHealth> {
    return this.call('graphHealth', { namespace })
  }

  planGraphDrop(namespace: string): Promise<GraphPlan> {
    return this.call('planGraphDrop', { namespace })
  }

  dropGraph(namespace: string): Promise<{ output: string }> {
    return this.call('dropGraph', { namespace })
  }

  planGraphClean(namespace: string): Promise<GraphPlan> {
    return this.call('planGraphClean', { namespace })
  }

  cleanGraphs(namespace: string): Promise<{ output: string }> {
    return this.call('cleanGraphs', { namespace })
  }

  getIntegrations(): Promise<Integrations> {
    return this.call('getIntegrations', {})
  }

  // A terminal is a WebSocket to the same host, which the dev server proxies to
  // the API server with the token added.
  openTerminal(start: TerminalStart, listener: TerminalListener): TerminalHandle {
    const scheme = location.protocol === 'https:' ? 'wss' : 'ws'
    const socket = new WebSocket(`${scheme}://${location.host}${TERMINAL_PATH}`)
    // Set when the session has ended, so that the close that follows is not a failure.
    let ended = false
    // What is typed before the program has started waits, and goes to it then.
    let running = false
    const typed: string[] = []
    const send = (message: ClientMessage) => {
      if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message))
    }
    socket.onopen = () => send({ type: 'start', ...start })
    socket.onmessage = (event: MessageEvent<unknown>) => {
      const parsed = serverMessageSchema.safeParse(
        typeof event.data === 'string' ? JSON.parse(event.data) : null,
      )
      if (!parsed.success) return
      const message = parsed.data
      switch (message.type) {
        case 'started':
          running = true
          for (const data of typed.splice(0)) send({ type: 'input', data })
          listener.onStarted({ loaded: message.loaded, note: message.note })
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
          listener.onExit(message.code)
          break
        case 'error':
          ended = true
          listener.onError(message.message)
          break
      }
    }
    socket.onclose = () => {
      if (!ended) {
        ended = true
        listener.onError('The connection to the server was closed.')
      }
    }
    return {
      write: (data) => (running ? send({ type: 'input', data }) : typed.push(data)),
      resize: (cols, rows) => send({ type: 'resize', cols, rows }),
      close: () => {
        ended = true
        socket.close()
      },
    }
  }

  getConfig(): Promise<AppConfig> {
    return this.call('getConfig', {})
  }

  setConfig(patch: Partial<AppConfig>): Promise<AppConfig> {
    return this.call('setConfig', { patch })
  }

  getPaths(): Promise<AppPaths> {
    return this.call('getPaths', {})
  }

  runRequest(executionId: string, request: RunRequest): Promise<RunAnswer> {
    return this.call('runRequest', { executionId, request })
  }

  // The server has no event stream yet.
  watch(): Unsubscribe {
    throw new Error('watch is not available: the server has no event stream yet')
  }

  startRun(pipeline: string, input: unknown): Promise<{ executionId: string }> {
    return this.call('startRun', { pipeline, input })
  }

  async stopRun(executionId: string): Promise<void> {
    await this.call('stopRun', { executionId })
  }
}
