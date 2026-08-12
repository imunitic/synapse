#!/bin/bash
# PostToolUse hook (Write|Edit|mcp__obsidian__vault_(write|patch|append|delete|move)):
# commit any agent-driven vault change to the vault's local git repo (if
# one exists -- this is opt-in per-vault, not assumed). Matches on the MCP
# vault mutation tools too, not just the native Write/Edit tools, since
# /synapse-note and the synapse-task skill write through mcp__obsidian__vault_*
# rather than editing files directly.

# WHAT IS LEFT HERE. Config, identity and dispatch. The hook itself is
# `synapse-hook db-sync` -- see src/apps/hook/db_sync.zig. Identity stays here
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

exec "$HOOK_BIN" db-sync
