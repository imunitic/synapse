// Synapse for OpenCode: shells out to the same `synapse-hook` binary Claude
// Code's hooks.json already calls, translating OpenCode's plugin callbacks
// into the same stdin JSON payload / stdout `hookSpecificOutput` shape the
// binary already reads and writes. No engine change -- see
// `src/apps/hook/main.zig`'s own doc comment for that contract.
//
// Session lifecycle isn't a named `Hooks` key in OpenCode's plugin API --
// confirmed against the real `@opencode-ai/plugin`/`@opencode-ai/sdk` type
// packages, not assumed from prose docs. `session.created` is delivered
// only through the generic catch-all `event` hook as an `Event` union
// member (`event.type === "session.created"`), so this plugin instead
// piggybacks the equivalent one-per-session injection on `chat.message`,
// gated on whether this session has already received it -- checked against
// real session history (`client.session.messages`), not just in-memory
// state, since each `opencode run` CLI invocation is its own short-lived
// process and an in-memory Set alone re-injects on every `--continue` call.
//
// `tool.execute.after`'s real tool names/args, live-verified against a real
// edit: `write` (`args.filePath`, `args.content`) and `edit` (`args.filePath`,
// `args.oldString`, `args.newString`) -- both share `filePath`, matching
// Claude Code's `Write`/`Edit` sharing `tool_input.file_path`. Fired on
// write/edit tools for `staleness` -- the vault's own version control
// (`SYNAPSE_VAULT_INTEGRATIONS=git`) commits from inside `synapse`'s own CLI
// (`vault-write`/`vault-patch`) itself now, needing no `PostToolUse`-style
// hook here or on any other harness.
//
// `stop-nudge`'s Claude Code trigger (`Stop`, once per turn) maps to
// `session.idle` -- live-verified as firing exactly once, after every tool
// call and the final response for a turn. Its own `additionalContext` (the
// periodic "worth capturing" nudge) has nowhere to land at that moment --
// `session.idle` is a pure notification, no message `output` to push a part
// onto the way `chat.message` has -- so it's queued and delivered as a
// synthetic part on the *next* `chat.message` instead of dropped.
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
async function alreadyInjected(client, sessionID) {
  if (injected.has(sessionID)) return true
  try {
    const res = await client.session.messages({ path: { id: sessionID } })
    const history = res?.data ?? []
    const found = history.some((m) => m.parts.some((p) => p.type === "text" && p.text.startsWith(SESSION_START_MARKER)))
    if (found) injected.add(sessionID)
    return found
  } catch {
    return false
  }
}

const EDIT_TOOLS = new Set(["write", "edit"])

// sessionID -> nudge text from a `stop-nudge` call that had nowhere to land
// yet -- delivered on that session's next `chat.message`.
const pendingNudge = new Map()

// sessionID -> queued `staleness` output, same reason and same delivery as
// `pendingNudge` above: `tool.execute.after` has no message `output` to push
// a part onto, so a drift/grounding warning from it would otherwise be
// silently discarded instead of just reaching the next turn late.
const pendingStaleness = new Map()

export const Synapse = async ({ directory, client }) => {
  return {
    "chat.message": async (input, output) => {
      const sessionID = input.sessionID
      const newParts = []

      if (!(await alreadyInjected(client, sessionID))) {
        injected.add(sessionID)
        const ctx = runHook("session-start", { cwd: directory })
        if (ctx) newParts.push(textPart(sessionID, output, `${SESSION_START_MARKER}\n${ctx}`))
      }

      const queuedNudge = pendingNudge.get(sessionID)
      if (queuedNudge) {
        pendingNudge.delete(sessionID)
        newParts.push(textPart(sessionID, output, `[SYNAPSE-STOP-NUDGE]\n${queuedNudge}`))
      }

      const queuedStaleness = pendingStaleness.get(sessionID)
      if (queuedStaleness) {
        pendingStaleness.delete(sessionID)
        newParts.push(textPart(sessionID, output, `[SYNAPSE-STALENESS]\n${queuedStaleness}`))
      }

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
      const sessionID = event.properties.sessionID
      const text = runHook("stop-nudge", { session_id: sessionID })
      if (text) pendingNudge.set(sessionID, text)
    },
  }
}
