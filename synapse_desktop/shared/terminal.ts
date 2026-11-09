// What a terminal's WebSocket carries, as JSON text: the page asks for a
// session and types into it, and the server answers with what the program
// prints. Both ends check what they receive against these.

import { z } from 'zod'

export const MAX_INPUT_BYTES = 64 * 1024

// What a terminal runs: the user's login shell, or one of the harnesses.
export const terminalKindSchema = z.enum(['Shell', 'Claude', 'Codex', 'Opencode'])

export const terminalTaskSchema = z.enum(['init', 'rebuild-diff', 'rebuild-full'])

export const clientMessageSchema = z.discriminatedUnion('type', [
  z.object({
    type: z.literal('start'),
    kind: terminalKindSchema,
    // Where it is started: an absolute path of a folder that is there. Without
    // one, the user's home folder.
    cwd: z.string().min(1).max(4096).optional(),
    // What a harness is started to do; a shell has nothing to be told.
    task: terminalTaskSchema.optional(),
    // The id of a session of that harness to continue, as the harness lists it.
    resume: z
      .string()
      .regex(/^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/)
      .optional(),
    cols: z.number().int().min(1).max(1000),
    rows: z.number().int().min(1).max(1000),
  }),
  z.object({ type: z.literal('input'), data: z.string().max(MAX_INPUT_BYTES) }),
  z.object({
    type: z.literal('resize'),
    cols: z.number().int().min(1).max(1000),
    rows: z.number().int().min(1).max(1000),
  }),
])

export type ClientMessage = z.infer<typeof clientMessageSchema>

export const serverMessageSchema = z.discriminatedUnion('type', [
  // The program is running. `loaded` says whether the bundled Synapse was put in
  // for this session, and `note` says so to the person.
  z.object({ type: z.literal('started'), loaded: z.boolean(), note: z.string() }),
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
  z.object({ type: z.literal('error'), message: z.string() }),
])

export type ServerMessage = z.infer<typeof serverMessageSchema>
