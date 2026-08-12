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

# WHAT IS LEFT HERE. Config, identity and dispatch. The hook itself is
# `synapse-hook stop-nudge` -- see src/apps/hook/stop_nudge.zig. Identity stays here
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

exec "$HOOK_BIN" stop-nudge
