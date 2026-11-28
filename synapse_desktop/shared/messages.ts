// Every request a client can make of a host: its name, the parameters it takes and the result it
// has. The two hosts and the frontend read this table, so a message is defined once. A request
// that has nothing to say answers `null`.

import { z } from 'zod'
import { runIdSchema } from './protocol.ts'
import {
  commitIdSchema,
  commitLogSchema,
  folderChangesSchema,
  snapshotSchema,
  treeIdSchema,
} from './changes.ts'
import {
  terminalAttachSchema,
  terminalInfoSchema,
  terminalStartSchema,
  sessionIdSchema,
} from './terminal.ts'
import {
  appConfigSchema,
  definitionNameSchema,
  executionIdSchema,
  harnessSchema,
  modelSchema,
  namespaceSchema,
  runRequestSchema,
} from './calls.ts'
import { effortSchema } from './efforts.ts'

const text = z.string()
const path = z.string().min(1).max(4096)
const draftText = z.string().max(200_000)
const nullResult = z.null()

// Where a run's snapshot is pinned, under `refs/synapse/`: its start or its end.
export const pinRefSchema = z.string().regex(/^runs\/[A-Za-z0-9_-]{1,64}\/(start|end)$/)

// What a task note's `status` may be.
export const noteStatusSchema = z.enum(['TODO', 'IN-PROGRESS', 'REVIEW', 'DONE', 'CANCELED'])
export type NoteStatus = z.infer<typeof noteStatusSchema>

// What the request says about a model and a harness to run it.
const agentChoice = {
  harness: harnessSchema.optional(),
  model: modelSchema.optional(),
  effort: effortSchema.optional(),
}

// ---------------------------------------------------------------------------------------------
// What the messages answer
// ---------------------------------------------------------------------------------------------

export const dirEntrySchema = z.object({
  name: z.string(),
  isDir: z.boolean(),
  mtimeMs: z.number(),
})

export const cliResultSchema = z.object({
  code: z.number().int(),
  stdout: z.string(),
  stderr: z.string(),
})

export const appPathsSchema = z.object({
  definitionDirs: z.array(z.string()),
  recordsDir: z.string().nullable(),
})

const configAnswerSchema = z.object({ config: appConfigSchema, paths: appPathsSchema })

const projectListSchema = z.object({
  projects: z.array(z.object({ name: z.string(), prefix: z.string() })),
  file: z.string(),
})

const conventionSchema = z.object({
  id: z.string(),
  group: z.enum(['Vault', 'Code graph', 'Prompts']),
  title: z.string(),
  about: z.string(),
  file: z.string(),
  exists: z.boolean(),
  editable: z.boolean(),
  entries: z.array(z.object({ text: z.string(), detail: z.string().optional() })),
  problem: z.string().nullable(),
})

const conventionListSchema = z.object({ conventions: z.array(conventionSchema) })

export const modelCatalogSchema = z.object({
  models: z.array(
    z.object({
      id: z.string(),
      provider: z.string().nullable(),
      available: z.boolean(),
      detail: z.string().nullable(),
    }),
  ),
  note: z.string().nullable(),
  readAt: z.string().nullable(),
})

const pastSessionsSchema = z.object({
  Claude: z.array(
    z.object({
      id: z.string(),
      path: z.string(),
      title: z.string().nullable(),
      lastUsed: z.string().nullable(),
    }),
  ),
  Codex: z.array(
    z.object({
      id: z.string(),
      path: z.string(),
      title: z.string().nullable(),
      lastUsed: z.string().nullable(),
    }),
  ),
  Opencode: z.array(
    z.object({
      id: z.string(),
      path: z.string(),
      title: z.string().nullable(),
      lastUsed: z.string().nullable(),
    }),
  ),
})

const workspaceList = z.array(z.object({ path: z.string(), lastUsed: z.string().nullable() }))

const workspacesSchema = z.object({
  Claude: workspaceList,
  Codex: workspaceList,
  Opencode: workspaceList,
})

const noteEditSchema = z.object({
  before: z.string(),
  after: z.string(),
  touched: z.array(z.string()),
})

const vaultInfoSchema = z.object({
  path: z.string(),
  exists: z.boolean(),
  hasIndex: z.boolean(),
  isGit: z.boolean(),
  notes: z.number().int().nonnegative(),
  capped: z.boolean(),
})

const runAnswerSchema = z.union([
  z.object({ ok: z.literal(true), result: z.unknown() }),
  z.object({ ok: z.literal(false), error: z.string() }),
])

const graphRepoCheckSchema = z.object({ key: z.string().nullable(), error: z.string().nullable() })

const graphRepoMatchesSchema = z.object({ paths: z.array(z.string()) })

const graphCheckSchema = z.union([
  z.object({
    ok: z.literal(true),
    findings: z.array(z.object({ node: z.string(), reason: z.string() })),
  }),
  z.object({ ok: z.literal(false), error: z.string() }),
])

const graphHealthSchema = z.object({
  stale: graphCheckSchema,
  drift: graphCheckSchema,
  grounding: graphCheckSchema,
})

const graphPlanSchema = z.object({ lines: z.array(z.string()) })

const diagnosisSchema = z.object({
  findings: z.array(
    z.object({
      key: z.string(),
      name: z.string(),
      status: z.enum(['ok', 'warn', 'fail']),
      detail: z.string(),
      value: z.string(),
    }),
  ),
  counts: z.object({
    ok: z.number().int().nonnegative(),
    warn: z.number().int().nonnegative(),
    fail: z.number().int().nonnegative(),
  }),
})

const integrationsSchema = z.object({
  bundled: z.object({
    version: z.string().nullable(),
    hook: z.string().nullable(),
    contentRoot: z.string().nullable(),
    pipelineRoot: z.string().nullable(),
  }),
  harnesses: z.array(
    z.object({
      harness: harnessSchema,
      state: z.enum(['absent', 'current', 'different', 'broken', 'installed', 'newer']),
      hook: z.string().nullable(),
      version: z.string().nullable(),
    }),
  ),
})

// ---------------------------------------------------------------------------------------------
// The table
// ---------------------------------------------------------------------------------------------

interface Message {
  params: z.ZodType
  result: z.ZodType
}

export const messages = {
  // Files, within the folders the host allows.
  'fs.read': { params: z.object({ path: z.string() }), result: z.object({ text }) },
  'fs.list': {
    params: z.object({ path: z.string() }),
    result: z.object({ entries: z.array(dirEntrySchema) }),
  },

  // A program of Synapse, from the allowlist the host keeps.
  cli: {
    params: z.object({
      binary: z.enum(['synapse-pipeline', 'synapse']),
      args: z.array(z.string()),
      stdin: z.string().optional(),
    }),
    result: cliResultSchema,
  },

  // The settings, and where the app looks.
  'config.get': { params: z.object({}), result: configAnswerSchema },
  'config.set': {
    params: z.object({ patch: appConfigSchema.partial() }),
    result: configAnswerSchema,
  },

  // The projects and the conventions, each a list that is read, added to and taken from.
  'registry.list': {
    params: z.object({ kind: z.enum(['projects', 'conventions']) }),
    result: z.union([
      z.object({ kind: z.literal('projects'), list: projectListSchema }),
      z.object({ kind: z.literal('conventions'), list: conventionListSchema }),
    ]),
  },
  'registry.add': {
    params: z.discriminatedUnion('kind', [
      z.object({
        kind: z.literal('projects'),
        name: z.string().min(1).max(64),
        prefix: z.string().min(1).max(32),
      }),
      z.object({
        kind: z.literal('conventions'),
        id: z.string().min(1).max(64),
        entry: z.string().min(1).max(1000),
      }),
    ]),
    result: z.union([
      z.object({ kind: z.literal('projects'), list: projectListSchema }),
      z.object({ kind: z.literal('conventions'), list: conventionListSchema }),
    ]),
  },
  'registry.remove': {
    params: z.object({
      kind: z.literal('conventions'),
      id: z.string().min(1).max(64),
      entry: z.string().min(1).max(1000),
    }),
    result: z.object({ kind: z.literal('conventions'), list: conventionListSchema }),
  },

  // What the harnesses know: their models, and the sessions and folders they remember.
  'models.get': {
    params: z.object({ harness: harnessSchema, refresh: z.boolean().optional() }),
    result: modelCatalogSchema,
  },
  'history.get': {
    params: z.object({ what: z.enum(['sessions', 'workspaces']) }),
    result: z.union([
      z.object({ what: z.literal('sessions'), sessions: pastSessionsSchema }),
      z.object({ what: z.literal('workspaces'), workspaces: workspacesSchema }),
    ]),
  },

  // An agent writes something: a definition, a note, a change to a note, the input of a run.
  'agent.run': {
    params: z.discriminatedUnion('kind', [
      z.object({
        kind: z.literal('definition'),
        what: z.enum(['pipeline', 'system', 'agent', 'prompt']),
        prompt: z.string().min(1).max(20_000),
        ...agentChoice,
        current: draftText.optional(),
        definitions: z
          .array(
            z.object({
              name: definitionNameSchema,
              kind: z.enum(['pipeline', 'system', 'agent', 'prompt']),
            }),
          )
          .max(1000),
        run: runIdSchema.optional(),
      }),
      z.object({
        kind: z.literal('note'),
        what: z.enum(['note', 'task', 'design']),
        prompt: z.string().min(1).max(20_000),
        ...agentChoice,
        project: z.string().min(1).max(64).optional(),
        run: runIdSchema.optional(),
      }),
      z.object({
        kind: z.literal('note-edit'),
        path: z.string().min(1).max(1024),
        prompt: z.string().min(1).max(20_000),
        ...agentChoice,
        run: runIdSchema.optional(),
      }),
      z.object({
        kind: z.literal('run-input'),
        pipeline: definitionNameSchema,
        prompt: z.string().min(1).max(20_000),
        ...agentChoice,
        // The JSON in the editor now, which the description may add to.
        current: draftText.optional(),
        run: runIdSchema.optional(),
      }),
    ]),
    result: z.union([
      z.object({ kind: z.literal('definition'), text }),
      z.object({ kind: z.literal('note'), path: z.string() }),
      z.object({ kind: z.literal('note-edit'), edit: noteEditSchema }),
      z.object({ kind: z.literal('run-input'), text }),
    ]),
  },
  // Ends the run of an agent that has this id; an id that is not running is not an error.
  'agent.stop': { params: z.object({ run: runIdSchema }), result: nullResult },
  // Sets the status of a task note, which only a person does: an agent that changes a note never
  // sets DONE, so this is not one of the things an agent is asked to do.
  'note.status': {
    params: z.object({ path: z.string().min(1).max(1024), status: noteStatusSchema }),
    result: nullResult,
  },
  'note.restore': {
    params: z.object({
      path: z.string().min(1).max(1024),
      before: draftText,
      after: draftText,
    }),
    result: nullResult,
  },

  // Definitions: looked at as a draft, and written as new or in place of what was read.
  'definition.preview': {
    params: z.object({
      draft: z.object({
        kind: z.enum(['pipeline', 'system', 'agent', 'prompt']),
        name: definitionNameSchema,
        text: draftText,
      }),
    }),
    result: cliResultSchema,
  },
  'definition.write': {
    params: z.union([
      z.object({
        mode: z.literal('create'),
        kind: z.literal('definition'),
        name: definitionNameSchema,
        text: draftText,
      }),
      // Refused when the file is not what the caller read.
      z.object({
        mode: z.literal('replace'),
        path: z.string(),
        previous: draftText,
        text: draftText,
      }),
      // A definition file is removed.
      z.object({ mode: z.literal('delete'), path: z.string() }),
    ]),
    result: z.object({ path: z.string() }),
  },

  // Runs of a pipeline.
  'run.start': {
    params: z.object({
      pipeline: z.string().regex(/^[A-Za-z][A-Za-z0-9_]*$/),
      input: z.unknown(),
      folder: z.string().optional(),
      // The run's name; the engine checks it (`run --name`).
      runName: z.string().min(1).max(480).optional(),
    }),
    result: z.object({ executionId: z.string() }),
  },
  'run.stop': { params: z.object({ executionId: executionIdSchema }), result: nullResult },
  'run.ask': {
    params: z.object({ executionId: executionIdSchema, request: runRequestSchema }),
    result: runAnswerSchema,
  },

  // The folder of a vault.
  'vault.inspect': { params: z.object({ path }), result: vaultInfoSchema },
  'vault.seed': { params: z.object({ path }), result: vaultInfoSchema },

  // Code graphs: the repository of one, its health, and dropping or cleaning.
  'graph.repo': {
    params: z.discriminatedUnion('action', [
      z.object({ action: z.literal('check'), path }),
      z.object({ action: z.literal('find'), namespace: namespaceSchema }),
    ]),
    result: z.union([
      z.object({ action: z.literal('check'), check: graphRepoCheckSchema }),
      z.object({ action: z.literal('find'), matches: graphRepoMatchesSchema }),
    ]),
  },
  'graph.health': { params: z.object({ namespace: namespaceSchema }), result: graphHealthSchema },
  'graph.manage': {
    params: z.object({
      // The dry run, or the thing itself.
      action: z.enum(['plan', 'apply']),
      what: z.enum(['drop', 'clean']),
      namespace: namespaceSchema,
    }),
    result: z.union([
      z.object({ action: z.literal('plan'), plan: graphPlanSchema }),
      z.object({ action: z.literal('apply'), output: z.string() }),
    ]),
  },

  // Terminal sessions, which the host holds. What is typed and what the program prints go on the
  // stream of the session, which a start or an attach opens.
  'terminal.start': { params: terminalStartSchema, result: terminalInfoSchema },
  'terminal.attach': { params: terminalAttachSchema, result: terminalInfoSchema },
  'terminal.list': {
    params: z.object({}),
    result: z.object({ sessions: z.array(terminalInfoSchema) }),
  },
  // Ends the session and its program.
  'terminal.close': { params: z.object({ session: sessionIdSchema }), result: nullResult },

  // What changed in a folder's working tree. A snapshot is the id of a tree object, null when the
  // folder is not in a git repository, with where HEAD was; the changes are those since a snapshot.
  'changes.snapshot': {
    // `of: 'head'` is the tree of the last commit, which is the empty tree before there is one,
    // so that everything not committed is a change.
    params: z.object({ folder: path, of: z.enum(['head']).optional() }),
    result: snapshotSchema,
  },
  // With `after`, the changes are those between two snapshots, and none is taken of the working tree.
  'changes.diff': {
    params: z.object({
      folder: path,
      before: treeIdSchema,
      path: path.optional(),
      after: treeIdSchema.optional(),
    }),
    result: folderChangesSchema,
  },
  // Pins a snapshot under `refs/synapse/<ref>`, so that it is kept through `git gc`, and deletes
  // that ref; deleting a ref that is not there is not an error. These are the only writes to a
  // repository, and the ref is never a branch or a tag.
  'changes.pin': {
    params: z.object({ folder: path, ref: pinRefSchema, tree: treeIdSchema }),
    result: nullResult,
  },
  'changes.unpin': {
    params: z.object({ folder: path, ref: pinRefSchema }),
    result: nullResult,
  },
  // The commits of the branch a folder is on, newest first along the first parent, `limit` at a
  // time; `before` is the last one already listed, and the answer starts after it. Read-only.
  'changes.log': {
    params: z.object({
      folder: path,
      limit: z.number().int().min(1).max(200),
      before: commitIdSchema.optional(),
    }),
    result: commitLogSchema,
  },
  // What a commit changed against its first parent, or against the empty tree for the first
  // commit; with a path, that file's whole patch.
  'changes.commit': {
    params: z.object({ folder: path, commit: commitIdSchema, path: path.optional() }),
    result: folderChangesSchema,
  },

  // The host itself.
  diagnose: { params: z.object({}), result: diagnosisSchema },
  integrations: { params: z.object({}), result: integrationsSchema },
} as const satisfies Record<string, Message>

export type MessageName = keyof typeof messages

export type Params<N extends MessageName> = z.input<(typeof messages)[N]['params']>

export type Result<N extends MessageName> = z.output<(typeof messages)[N]['result']>

export function isMessageName(name: string): name is MessageName {
  return Object.hasOwn(messages, name)
}

// Where each of the methods of the interface the pages used is now: a message, an event topic or
// a stream. A method that has a place inside a message says which.
export const methodHomes = {
  readText: 'fs.read',
  readDir: 'fs.list',
  watch: 'subscribe',
  watchUsage: 'subscribe',
  runRequest: 'run.ask',
  cli: 'cli',
  previewDraft: 'definition.preview',
  writeDefinition: 'definition.write',
  saveDefinition: 'definition.write',
  deleteDefinition: 'definition.write',
  generateDefinition: 'agent.run',
  createNote: 'agent.run',
  editNote: 'agent.run',
  stopAgentRun: 'agent.stop',
  restoreNote: 'note.restore',
  setNoteStatus: 'note.status',
  listProjects: 'registry.list',
  addProject: 'registry.add',
  getDiagnosis: 'diagnose',
  listWorkspaces: 'history.get',
  listModels: 'models.get',
  refreshModels: 'models.get',
  listSessions: 'history.get',
  seedVault: 'vault.seed',
  listConventions: 'registry.list',
  addConvention: 'registry.add',
  removeConvention: 'registry.remove',
  snapshotChanges: 'changes.snapshot',
  diffChanges: 'changes.diff',
  openTerminal: 'terminal.start',
  listTerminals: 'terminal.list',
  startRun: 'run.start',
  stopRun: 'run.stop',
  inspectVault: 'vault.inspect',
  getIntegrations: 'integrations',
  checkGraphRepo: 'graph.repo',
  findGraphRepos: 'graph.repo',
  graphHealth: 'graph.health',
  planGraphDrop: 'graph.manage',
  dropGraph: 'graph.manage',
  planGraphClean: 'graph.manage',
  cleanGraphs: 'graph.manage',
  getConfig: 'config.get',
  getPaths: 'config.get',
  setConfig: 'config.set',
} as const satisfies Record<string, MessageName | 'subscribe'>
