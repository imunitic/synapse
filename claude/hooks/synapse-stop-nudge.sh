#!/bin/bash
# Stop hook, two jobs, both keyed off the fact that Stop is the only per-turn
# event: (1) every N turns, force a genuine "is anything worth capturing in
# Synapse Vault" check-in; (2) every PUSH_EVERY turns, push the vault's
# auto-commits to its remote if it has one. See the push block at the bottom
# for why that lives here rather than in synapse-db-sync.sh.
#
# The nudge uses hookSpecificOutput.additionalContext (not
# decision:block) -- an earlier predecessor hook used this same shape and
# reliably produced immediate, visible action, with the CLI labeling it
# "Stop hook feedback" instead of the alarming-looking "Stop hook error"
# that decision:block renders as. Switched back to this shape 2026-07-23
# specifically for the better label -- confirm empirically that it still
# fires immediately; if it turns out to silently defer instead, revert to
# decision:block. Mirrors a similar hook from another setup, adapted to
# this repo's Obsidian-backed Synapse Vault, with no reference to a
# /wrapup-style command, which isn't used here.
N=25
STATE_DIR="$HOME/.claude/state"
mkdir -p "$STATE_DIR"

# synapse.conf, falling back to the name this file had before the project was
# renamed, so scripts updated ahead of setup.sh still find an existing config
# rather than reporting "no vault".
CONF="$HOME/.claude/synapse.conf"
[ -f "$CONF" ] || CONF="$HOME/.claude/second-brain.conf"
[ -f "$CONF" ] && source "$CONF"

LOCATION="${OBSIDIAN_VAULT_DIR:-the Obsidian vault}"
CMD="/synapse-note"

INPUT="$(cat)"
SID="$(printf '%s' "$INPUT" | jq -r '.session_id // "default"')"
TOTAL_FILE="$STATE_DIR/synapse-stop-nudge-total-$SID"
SINCE_FILE="$STATE_DIR/synapse-stop-nudge-since-$SID"

TOTAL=$(( $(cat "$TOTAL_FILE" 2>/dev/null || echo 0) + 1 ))
SINCE=$(( $(cat "$SINCE_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$TOTAL" > "$TOTAL_FILE"

if [ "$SINCE" -ge "$N" ]; then
  echo 0 > "$SINCE_FILE"
  jq -n --arg location "$LOCATION" --arg cmd "$CMD" --arg total "$TOTAL" --arg n "$N" '
    {
      hookSpecificOutput: {
        hookEventName: "Stop",
        additionalContext: ("This session has grown substantial (\($total) turns, re-armed at the " + $n + "-turn mark). Before continuing: did this session produce a debugging/investigation/research finding, decision, or piece of context worth persisting to Synapse Vault (\($location))? If so, write it up now (see the global CLAUDE.md \"Synapse Vault as permanent memory\" section, or use " + $cmd + ") while full context is still available -- do not wait for a wrap-up step. If you already wrote or updated a note earlier this session, check whether anything since then is worth folding in too.")
      }
    }'
else
  echo "$SINCE" > "$SINCE_FILE"
fi

# --- push the vault to its remote, every PUSH_EVERY turns ------------------
#
# WHY HERE AND NOT IN synapse-db-sync.sh. That hook is PostToolUse, so it fires
# once per vault-mutating tool call -- several times in a single turn -- and a
# network round trip there would be paid on every Write/Edit. It also has no way
# to count turns: Stop is the only per-turn event. So committing stays there and
# pushing happens here, reusing this script's existing per-session TOTAL counter
# rather than adding a second one.
#
# PIGGYBACKING IS SAFE BECAUSE THIS SCRIPT HAS NO EARLY EXITS -- every path above
# falls through to here. It must stay silent on stdout, though: the branch above
# may already have written this hook's JSON, and a second write would corrupt it.
#
# A vault with no remote is a supported, ordinary configuration (local versioned
# undo only), so a missing remote or upstream is a silent no-op rather than an
# error. Nothing here is fatal: a Stop hook that fails or stalls degrades the
# visible end of every turn.
PUSH_EVERY="${SYNAPSE_VAULT_PUSH_EVERY:-5}"
VAULT_DIR="${OBSIDIAN_VAULT_DIR:-}"

if [ -n "$VAULT_DIR" ] && [ -d "$VAULT_DIR/.git" ] \
   && [ "${PUSH_EVERY:-0}" -gt 0 ] 2>/dev/null \
   && [ $(( TOTAL % PUSH_EVERY )) -eq 0 ]; then

  UPSTREAM="$(git -C "$VAULT_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"
  AHEAD="$(git -C "$VAULT_DIR" rev-list --count "$UPSTREAM..HEAD" 2>/dev/null || echo 0)"

  # Only when there is genuinely something to send: "push if needed".
  if [ -n "$UPSTREAM" ] && [ "${AHEAD:-0}" -gt 0 ] 2>/dev/null; then
    LOCK="$VAULT_DIR/.git/synapse-push.lock"
    LOG="$VAULT_DIR/.git/synapse-push.log"

    # Detached, so the turn never waits on the network. macOS ships no
    # `timeout`/`gtimeout`, so the bound is set at the SSH layer instead:
    # ConnectTimeout caps an unreachable remote (VPN off), and BatchMode=yes is
    # load-bearing for a background process -- without it a key whose passphrase
    # is not in the agent makes ssh wait forever on a prompt nobody can see.
    (
      # mkdir is the atomic test-and-set. A lock older than 10 minutes is a
      # crashed run, not a live one, so it is cleared rather than honoured.
      if [ -d "$LOCK" ] && [ -z "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
        exit 0
      fi
      rm -rf "$LOCK" 2>/dev/null
      mkdir "$LOCK" 2>/dev/null || exit 0

      GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=10' \
        git -C "$VAULT_DIR" push --quiet 2>>"$LOG" \
        || printf '%s push failed, %s commit(s) still pending\n' \
             "$(date '+%Y-%m-%d %H:%M')" "$AHEAD" >> "$LOG"

      rm -rf "$LOCK" 2>/dev/null
    ) </dev/null >/dev/null 2>&1 &
  fi
fi

exit 0
