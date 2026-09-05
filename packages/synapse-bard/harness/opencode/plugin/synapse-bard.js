// synapse-bard for OpenCode: shells out to the same `synapse-bard-hook`
// binary Claude Code's hooks.json already calls, translating OpenCode's
// plugin callbacks into the same stdin JSON payload / stdout
// `hookSpecificOutput` shape the binary already reads and writes. Same
// approach as @imunitic/synapse's own harness/opencode/plugin/synapse.js,
// scaled down to bard's two hooks -- `session-start` and `stop-nudge` are
// the only ones synapse-bard-hook has (see src/apps/bard_hook/main.zig);
// there is no `prompt-context`/`staleness` equivalent to wire up here.
//
// `synapse-bard-hook`'s own binary path isn't resolved here the usual way --
// OpenCode plugins get no `${CLAUDE_PLUGIN_ROOT}`-equivalent "where am I
// installed" value, unlike Claude Code/Codex, and an npm install's binary
// lives inside a per-platform optionalDependency package
// (node_modules/@imunitic/synapse-bard-{platform}-{arch}/bin/), a path with
// no fixed location this file could hardcode or compute at import time.
// `synapse-bard-setup configure opencode` resolves it once, at configure
// time, and rewrites the literal string below to the real absolute path --
// this file as shipped in the npm package is a template, not the copy that
// actually runs. `SYNAPSE_BARD_HOOK_BIN` overrides it if ever needed.

import { spawnSync } from "child_process"

const HOOK_BIN = process.env.SYNAPSE_BARD_HOOK_BIN || "__SYNAPSE_BARD_HOOK_BIN__"
const SESSION_START_MARKER = "[SYNAPSE-BARD-SESSION-START]"

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
// correct across separate CLI invocations, not just within one, matching
// @imunitic/synapse's own plugin here.
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

// sessionID -> nudge text from a `stop-nudge` call that had nowhere to land
// yet -- `session.idle` is a pure notification, no message `output` to push
// a part onto the way `chat.message` has, so the nudge is queued and
// delivered as a synthetic part on the session's next `chat.message` instead
// of dropped.
const pendingNudge = new Map()

export const SynapseBard = async ({ directory, client }) => {
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
        newParts.push(textPart(sessionID, output, `[SYNAPSE-BARD-STOP-NUDGE]\n${queuedNudge}`))
      }

      if (newParts.length) output.parts.push(...newParts)
    },

    event: async ({ event }) => {
      if (event.type !== "session.idle") return
      const sessionID = event.properties.sessionID
      const text = runHook("stop-nudge", { session_id: sessionID })
      if (text) pendingNudge.set(sessionID, text)
    },
  }
}
