// Synapse for OpenCode: shells out to the same `synapse-hook` binary Claude
// Code's hooks.json already calls, translating OpenCode's plugin callbacks
// into the same stdin JSON payload / stdout `hookSpecificOutput` shape the
// binary already reads and writes. No engine change -- see
// `src/hooks/synapse-hooks-dispatch.ads`'s own doc comment for that contract.
//
// Ported to the OpenCode v2 plugin API (2.0.x). The v2 loader rejects this
// file's old shape outright at load time -- it requires a default export
// carrying an `id` plus a `setup(ctx)` function, and it never runs a bare
// named-export factory ("Plugin must export a default definition with an id
// and an effect or setup function"). The v1 hook map is kept as `server()`
// for OpenCode 1.18.29+ hosts, which read exactly that key off the default
// export; the two implementations share all state and helpers below, and
// only the wiring differs.
//
// v1 `chat.message` -> v2 `ctx.session.hook("prompt", ...)`. The v2 prompt
// hook runs once at prompt admission, before the durable inbox write, and an
// edit to `event.prompt.text` becomes the canonical persisted user input --
// so appending the synapse blocks there lands them where v1's synthetic parts
// did: delivered to the model call answering this prompt, and persisted in
// session history. That persistence is what makes the one-per-session gate
// correct across separate `opencode run` invocations -- each CLI call is its
// own short-lived process with an empty in-memory Set, so the gate re-checks
// real session history (`ctx.session.context`), not just memory.
//
// v1 `tool.execute.after` -> v2 `ctx.tool.hook("execute.after", ...)`, same
// event fields under different names (`event.tool`, `event.input` instead of
// `input.tool`, `input.args`).
//
// v1 `event` -> v2 `ctx.event.subscribe()`, filtered to `session.idle` --
// live-verified in v1 as firing exactly once, after every tool call and the
// final response for a turn. `stop-nudge`'s `additionalContext` (the periodic
// "worth capturing" nudge) still has nowhere to land at that moment -- idle
// is a pure notification -- so it stays queued and delivered as a block on
// the *next* admitted prompt instead of dropped. Same for `staleness`
// warnings: `tool.execute.after` is a post-hoc notification with no way to
// reach the current turn, so its output queues the same way.
//
// `synapse-hook`'s own binary path isn't resolved here the usual way --
// OpenCode plugins get no `${CLAUDE_PLUGIN_ROOT}`-equivalent "where am I
// installed" value, unlike Claude Code/Codex, and an npm install's binary
// lives inside a per-platform optionalDependency package
// (node_modules/@imunitic/synapse-{platform}-{arch}/bin/), a path with no
// fixed location this file could hardcode or compute at import time.
// `synapse-setup configure opencode` resolves it once, at configure time,
// and rewrites the literal string below to the real absolute path -- this
// file as shipped in the npm package is a template, not the copy that
// actually runs. `SYNAPSE_HOOK_BIN` overrides it if ever needed.

import { spawnSync } from "child_process"

const HOOK_BIN = process.env.SYNAPSE_HOOK_BIN || "__SYNAPSE_HOOK_BIN__"
const SESSION_START_MARKER = "[SYNAPSE-SESSION-START]"

function runHook(subcommand, payload) {
  const res = spawnSync(HOOK_BIN, [subcommand], {
    input: JSON.stringify(payload),
    encoding: "utf8",
  })
  if (res.status !== 0 || !res.stdout) return null
  try {
    const parsed = JSON.parse(res.stdout)
    return parsed?.hookSpecificOutput?.additionalContext ?? null
  } catch {
    return null
  }
}

function partID() {
  return "prt_" + Math.random().toString(36).slice(2) + Date.now().toString(36)
}

function textPart(sessionID, output, text) {
  return {
    id: partID(),
    sessionID,
    messageID: output.message.id,
    type: "text",
    text,
    synthetic: true,
  }
}

const injected = new Set()

// In-memory `injected` is a fast path only, good within one long-lived
// process (the interactive TUI). Each `opencode run` invocation is its own
// process, so `--continue`/`--session` against an existing session starts
// with an empty Set -- checking real session history is what makes this
// correct across separate CLI invocations, not just within one, confirmed
// live: without this check, a second `opencode run --continue` call
// re-injected the full vault index every time.
//
// The Set claim happens synchronously *before* the awaited history read, so
// two prompts admitted concurrently in one process cannot both pass the
// check (v1 marked only after the await, leaving that race open).
async function alreadyInjected(fetchHistory, sessionID) {
  if (injected.has(sessionID)) return true
  injected.add(sessionID)
  try {
    const history = await fetchHistory(sessionID)
    return history.some(messageHasMarker)
  } catch {
    return false
  }
}

// v1 messages carry text in `parts`; v2 session-context messages (user and
// synthetic alike) carry it flat on `text`.
function messageHasMarker(m) {
  if (typeof m?.text === "string") return m.text.startsWith(SESSION_START_MARKER)
  return (m?.parts ?? []).some((p) => p.type === "text" && p.text.startsWith(SESSION_START_MARKER))
}

const EDIT_TOOLS = new Set(["write", "edit"])

// sessionID -> nudge text from a `stop-nudge` call that had nowhere to land
// yet -- delivered on that session's next admitted prompt.
const pendingNudge = new Map()

// sessionID -> queued `staleness` output, same reason and same delivery as
// `pendingNudge` above: `tool.execute.after` has no channel into the turn
// that just ran, so a drift/grounding warning from it would otherwise be
// silently discarded instead of just reaching the next turn late.
const pendingStaleness = new Map()

// Blocks delivered alongside a prompt, in v1's part order: session-start,
// queued nudge, queued staleness, prompt-context.
async function collectBlocks(sessionID, opts) {
  const blocks = []

  if (!(await opts.injected())) {
    const ctx = runHook("session-start", { cwd: opts.directory })
    if (ctx) blocks.push(`${SESSION_START_MARKER}\n${ctx}`)
  }

  const queuedNudge = pendingNudge.get(sessionID)
  if (queuedNudge) {
    pendingNudge.delete(sessionID)
    blocks.push(`[SYNAPSE-STOP-NUDGE]\n${queuedNudge}`)
  }

  const queuedStaleness = pendingStaleness.get(sessionID)
  if (queuedStaleness) {
    pendingStaleness.delete(sessionID)
    blocks.push(`[SYNAPSE-STALENESS]\n${queuedStaleness}`)
  }

  return blocks
}

// ---------------------------------------------------------------------------
// v1 wiring (OpenCode 1.x): named factory plus `server()` on the default
// export, per the v1->v2 migration guide's dual-entrypoint shape.
// ---------------------------------------------------------------------------

export const Synapse = async ({ directory, client }) => {
  return {
    "chat.message": async (input, output) => {
      const sessionID = input.sessionID
      const newParts = []

      const history = async (id) => {
        const res = await client.session.messages({ path: { id } })
        return res?.data ?? []
      }
      const blocks = await collectBlocks(sessionID, {
        directory,
        injected: () => alreadyInjected(history, sessionID),
      })
      for (const block of blocks) newParts.push(textPart(sessionID, output, block))

      const promptText = (output.parts || [])
        .filter((p) => p.type === "text")
        .map((p) => p.text)
        .join("\n")
      const nudge = runHook("prompt-context", { cwd: directory, prompt: promptText || "x" })
      if (nudge) newParts.push(textPart(sessionID, output, `[SYNAPSE-PROMPT-CONTEXT]\n${nudge}`))

      if (newParts.length) output.parts.push(...newParts)
    },

    "tool.execute.after": async (input) => {
      const filePath = input.args?.filePath
      if (EDIT_TOOLS.has(input.tool) && filePath) {
        const text = runHook("staleness", {
          session_id: input.sessionID,
          tool_input: { file_path: filePath },
        })
        if (text) pendingStaleness.set(input.sessionID, text)
      }
    },

    event: async ({ event }) => {
      if (event.type !== "session.idle") return
      const sessionID = event.properties?.sessionID ?? event.data?.sessionID
      const text = runHook("stop-nudge", { session_id: sessionID })
      if (text && sessionID) pendingNudge.set(sessionID, text)
    },
  }
}

// ---------------------------------------------------------------------------
// v2 wiring (OpenCode 2.x): registrations through the plugin context.
// ---------------------------------------------------------------------------

async function setup(ctx) {
  const directory = ctx.location.directory

  await ctx.session.hook("prompt", async (event) => {
    const sessionID = event.sessionID

    const history = async (id) => {
      const res = await ctx.session.context({ sessionID: id })
      return Array.isArray(res) ? res : res?.data ?? []
    }
    const blocks = await collectBlocks(sessionID, {
      directory,
      injected: () => alreadyInjected(history, sessionID),
    })

    const promptText = event.prompt?.text ?? ""
    const nudge = runHook("prompt-context", { cwd: directory, prompt: promptText || "x" })
    if (nudge) blocks.push(`[SYNAPSE-PROMPT-CONTEXT]\n${nudge}`)

    if (blocks.length) {
      event.prompt.text = promptText ? `${promptText}\n\n${blocks.join("\n\n")}` : blocks.join("\n\n")
    }
  })

  await ctx.tool.hook("execute.after", async (event) => {
    const filePath = event.input?.filePath
    if (EDIT_TOOLS.has(event.tool) && filePath) {
      const text = runHook("staleness", {
        session_id: event.sessionID,
        tool_input: { file_path: filePath },
      })
      if (text) pendingStaleness.set(event.sessionID, text)
    }
  })

  const controller = new AbortController()
  void (async () => {
    for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
      if (event?.type !== "session.idle") continue
      const sessionID = event.data?.sessionID ?? event.properties?.sessionID
      if (!sessionID) continue
      const text = runHook("stop-nudge", { session_id: sessionID })
      if (text) pendingNudge.set(sessionID, text)
    }
  })().catch(() => {})

  return () => controller.abort()
}

export default {
  id: "synapse",
  setup,
  // v1 hook factory, read by OpenCode 1.18.29+ loaders; v2 hosts ignore it.
  server: Synapse,
}
