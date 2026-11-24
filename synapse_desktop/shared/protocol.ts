// The messages between the frontend and a host, whatever carries them: a WebSocket to the Node
// host, Tauri's IPC to the Rust one, or a pair of functions in a test. A request has an id and is
// answered by one reply with the same id; a host publishes events to the clients subscribed to a
// topic; a stream carries the bytes of a terminal. Everything is written here once, as schemas, so
// that both hosts and the frontend read one definition.

import { z } from 'zod'

// Changes with any change to a message that an older frontend or host would misread.
export const PROTOCOL_VERSION = 1

// What went wrong, as a code: the frontend never has to know what carries a message.
export const errorCodeSchema = z.enum([
  // The parameters are not the ones the message takes.
  'bad_request',
  // What was asked for is not there.
  'not_found',
  // The host refuses it: outside the folders it may touch, or not allowed.
  'forbidden',
  // The state of things does not allow it: nothing set up yet, or the file changed since it was read.
  'conflict',
  'too_large',
  // Something the host depends on failed: a program, a harness.
  'unavailable',
  'internal',
])

export type ErrorCode = z.infer<typeof errorCodeSchema>

// The id a client makes for a run of an agent, so it can watch and stop it.
export const runIdSchema = z.string().regex(/^[A-Za-z0-9_-]{1,64}$/)

// What a client subscribes to. The files of a place change (no cursor: a client that reconnects
// reads again what it shows), and a run publishes its events, each with its own index as cursor.
export const topicSchema = z
  .string()
  .regex(
    /^(files\.(work|definitions|vault)|run\.[A-Za-z0-9_-]{1,64}|note-run\.[A-Za-z0-9_-]{1,64})$/,
  )

export type Topic = z.infer<typeof topicSchema>

// Where an event stream resumes: the index of the last event a client has.
export const cursorSchema = z.number().int().nonnegative()

export type Cursor = z.infer<typeof cursorSchema>

// What a host can do, which the frontend adapts to instead of assuming.
export const capabilitiesSchema = z.object({
  // Which host it is, for the one thing that is told apart by it: where it keeps its terminals.
  host: z.enum(['node', 'tauri', 'fake']),
  // A shell can be started.
  shell: z.boolean(),
  // The programs and skills can be installed into the harnesses from the app.
  installActions: z.boolean(),
})

export type Capabilities = z.infer<typeof capabilitiesSchema>

// The bytes of a terminal and what is said about it. The messages are the ones of a terminal's
// session, which have a schema of their own.
export const streamDataSchema = z.record(z.string(), z.unknown())

export type StreamData = z.infer<typeof streamDataSchema>

const requestIdSchema = z.string().min(1).max(64)

// The answer to a request: a result, or an error. A request that has nothing to say has `null` as
// its result, since a result that is not there does not travel as JSON.
const replySchema = z
  .object({
    kind: z.literal('reply'),
    id: requestIdSchema,
    result: z.unknown().optional(),
    error: z.object({ code: errorCodeSchema, message: z.string() }).optional(),
  })
  .refine((reply) => (reply.error !== undefined) !== (reply.result !== undefined), {
    message: 'a reply has a result or an error, not both and not neither',
  })

export const clientMessageSchema = z.discriminatedUnion('kind', [
  z.object({
    kind: z.literal('request'),
    id: requestIdSchema,
    name: z.string().min(1).max(64),
    params: z.unknown(),
  }),
  z.object({ kind: z.literal('subscribe'), topic: topicSchema, after: cursorSchema.optional() }),
  z.object({ kind: z.literal('unsubscribe'), topic: topicSchema }),
  z.object({
    kind: z.literal('stream'),
    session: z.string().min(1).max(64),
    data: streamDataSchema,
  }),
])

export type ClientMessage = z.infer<typeof clientMessageSchema>

export const hostMessageSchema = z.union([
  // The first message of a connection: which protocol the host speaks and what it can do.
  z.object({
    kind: z.literal('hello'),
    protocol: z.number().int().positive(),
    capabilities: capabilitiesSchema,
  }),
  replySchema,
  z.object({
    kind: z.literal('event'),
    topic: topicSchema,
    cursor: cursorSchema.optional(),
    data: z.unknown(),
  }),
  z.object({
    kind: z.literal('stream'),
    session: z.string().min(1).max(64),
    data: streamDataSchema,
  }),
])

export type HostMessage = z.infer<typeof hostMessageSchema>
