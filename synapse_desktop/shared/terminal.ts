// What a terminal session is asked and told. A session is started, attached to and ended by
// requests; what is typed and what the program prints go as the messages of a stream, tied to the
// session's id. Both ends check what they receive against these.

import { z } from 'zod'

export const MAX_INPUT_BYTES = 64 * 1024

// What a terminal runs: the user's login shell, one of the harnesses, or an interactive run of a
// pipeline, whose harnesses use the terminal.
export const terminalKindSchema = z.enum(['Shell', 'Pipeline', 'Claude', 'Codex', 'Opencode'])

export const terminalTaskSchema = z.enum(['init', 'rebuild-diff', 'rebuild-full'])

// A session's name, which the page chooses and the host keeps it by.
export const sessionIdSchema = z.string().regex(/^[A-Za-z0-9_-]{1,64}$/)

const sizeSchema = {
  cols: z.number().int().min(1).max(1000),
  rows: z.number().int().min(1).max(1000),
}

export const terminalStartSchema = z.object({
  session: sessionIdSchema,
  // What the tab is called, kept by the host so that a page that attaches again can name the tab.
  title: z.string().min(1).max(100),
  kind: terminalKindSchema,
  // Where it is started: an absolute path of a folder that is there. Without one, the user's home
  // folder.
  cwd: z.string().min(1).max(4096).optional(),
  // What a harness is started to do; a shell has nothing to be told.
  task: terminalTaskSchema.optional(),
  // The pipeline an interactive run is started for, by name, and the input it is given: any JSON
  // value, none when absent.
  pipeline: z
    .string()
    .regex(/^[A-Za-z][A-Za-z0-9_]*$/)
    .max(128)
    .optional(),
  input: z.unknown().optional(),
  // The id of a session of that harness to continue, as the harness lists it.
  resume: z
    .string()
    .regex(/^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/)
    .optional(),
  ...sizeSchema,
})

export type TerminalStartParams = z.infer<typeof terminalStartSchema>

export const terminalAttachSchema = z.object({ session: sessionIdSchema, ...sizeSchema })

// What the host says of a session when it starts, when it is attached to and when they are listed.
export const terminalInfoSchema = z.object({
  session: sessionIdSchema,
  title: z.string(),
  kind: terminalKindSchema,
  cwd: z.string(),
  task: terminalTaskSchema.optional(),
  pipeline: z.string().optional(),
  // The id of the run a pipeline terminal started, which names its record.
  executionId: z.string().optional(),
  // Whether the bundled Synapse was put in for this session, and what to tell the person of it.
  loaded: z.boolean(),
  note: z.string(),
  // The exit code, once the program has ended; null while it runs.
  exited: z.number().nullable(),
})

export type TerminalInfo = z.infer<typeof terminalInfoSchema>

// What the page sends on a session's stream.
export const terminalClientStreamSchema = z.discriminatedUnion('type', [
  z.object({ type: z.literal('input'), data: z.string().max(MAX_INPUT_BYTES) }),
  z.object({ type: z.literal('resize'), ...sizeSchema }),
])

export type TerminalClientStream = z.infer<typeof terminalClientStreamSchema>

// What the host sends on it. A snapshot is the screen and its scrollback as the program drew them,
// sent when a client attaches and before any output that follows.
export const terminalHostStreamSchema = z.discriminatedUnion('type', [
  z.object({ type: z.literal('snapshot'), data: z.string() }),
  z.object({ type: z.literal('output'), data: z.string() }),
  // The conversation of a harness started in the session is being followed.
  z.object({
    type: z.literal('transcript-source'),
    id: z.string(),
    harness: z.enum(['Claude', 'Codex', 'Opencode']),
    cwd: z.string(),
  }),
  // Lines of that conversation's session file, as they were appended.
  z.object({ type: z.literal('transcript'), id: z.string(), lines: z.array(z.string()) }),
  z.object({ type: z.literal('exit'), code: z.number() }),
])

export type TerminalHostStream = z.infer<typeof terminalHostStreamSchema>
