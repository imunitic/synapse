#!/bin/bash
# PostToolUse hook (Write|Edit|MultiEdit): Synapse Tier 1 staleness flagging.
# A hook is a plain script, not an agent turn -- it already knows with
# certainty which file just changed, so this is pure bookkeeping (no
# git-hash verification, that's Tier 2 at read time). Talks to the Obsidian
# Local REST API directly rather than through the mcp__obsidian__ tools,
# same reasoning as synapse-db-sync.sh.
set -uo pipefail

# WHAT IS LEFT HERE. Config, identity and dispatch. The hook itself is
# `synapse-hook staleness` -- see src/apps/hook/staleness.zig. Identity stays here
# because synapse-identity.sh is still bash and this was one of its sourcers; the
# wrapper collapses when that lands.
#
# Every failure to resolve anything exits 0. A hook that errors is worse than one
# that quietly does nothing: it interrupts a turn to report a condition the user
# did not ask about and usually cannot act on.

CONF="$HOME/.claude/synapse.conf"
[ -f "$CONF" ] || CONF="$HOME/.claude/second-brain.conf"
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"
[ -n "${OBSIDIAN_VAULT_DIR:-}" ] && export OBSIDIAN_VAULT_DIR

HOOK_BIN="${SYNAPSE_HOOK_BIN:-$HOME/.claude/bin/synapse-hook}"
[ -x "$HOOK_BIN" ] || exit 0
export SYNAPSE_HOOK_BIN="$HOOK_BIN"

# Identity comes from the *edited file's* directory, not from $PWD: a session's cwd
# and the file it just wrote are not always in the same repo.
command -v jq >/dev/null || exit 0
INPUT="$(cat)"
FILE="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_response.filePath // empty')"
[ -n "$FILE" ] || exit 0
CWD="$(dirname "$FILE")"

# The namespace, resolved once and exported -- the same arrangement every ported
# script uses, so a hook cannot disagree with a command about which graph a
# checkout belongs to.
if command -v git >/dev/null; then
  REPO_ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$REPO_ROOT" ]; then
    # shellcheck source=/dev/null
    if . "${SYNAPSE_LIB_DIR:-$HOME/.claude/lib/synapse}/synapse-identity.sh" 2>/dev/null; then
      # A detached HEAD has no branch and so no namespace. Not an error: the hook
      # simply has nothing to say, and every consumer treats an absent
      # SYNAPSE_NAMESPACE as exactly that.
      if REPO_NAME="$(synapse_namespace "$REPO_ROOT" 2>/dev/null)"; then
        export SYNAPSE_NAMESPACE="$REPO_NAME"
        export SYNAPSE_REPO_ROOT="$REPO_ROOT"
        export SYNAPSE_BRANCH; SYNAPSE_BRANCH="$(synapse_branch "$REPO_ROOT")"
        export SYNAPSE_REMOTE; SYNAPSE_REMOTE="$(synapse_remote "$REPO_ROOT")"
        export SYNAPSE_WORK_DIR="${SYNAPSE_WORK_DIR:-$HOME/.claude/synapse-work/$REPO_NAME}"
      fi
    fi
  fi
fi

printf '%s' "$INPUT" | exec "$HOOK_BIN" staleness
