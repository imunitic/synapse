#!/bin/bash
# Wipes the current checkout's Synapse namespace, preserving any hand-written
# `## Notes` content first, ahead of a full /synapse-rebuild-full rebuild. The
# second destructive tool in Synapse (after synapse-graph-clean.sh), so it follows
# the same discipline: --dry-run support, and rm -rf gated behind a belt-and-braces
# path check that only ever removes a directory whose name was just matched inside
# the vault's own synapse/ directory.
#
# Usage: synapse-graph-wipe.sh [--dry-run]
#        synapse-graph-wipe.sh --help
#
#   --dry-run  report node count and which nodes have `## Notes` content at risk,
#              delete nothing, preserve nothing.
#
# Operates on {repo}@{branch} resolved from $PWD via synapse-identity.sh -- the
# same resolution /synapse-init and /synapse-rebuild-diff use. Never takes a
# namespace on the command line: this wipes the current checkout's own namespace,
# nothing else's.
#
# `## Notes` is the one thing in a node file that is human-authored and lives
# outside every generated fence -- no script regenerates it. Before deleting
# anything, every node's `## Notes` section is scanned; non-empty ones are dumped
# into a staging note at scratchpad/{repo}@{branch} -- preserved notes before full
# rebuild.md, so nothing is silently lost even though the namespace directory that
# held them is about to be removed. /synapse-rebuild-full reads that staging note
# back after rebuilding and merges what it can into the new nodes.
#
# Exit codes:
#   0 - ran (removed the namespace, or --dry-run reported cleanly)
#   1 - could not run (no vault, not in a git repo, missing dependency, namespace absent)
#   2 - usage error
set -uo pipefail

# WHAT IS LEFT HERE. Config, identity and dispatch. The decision tree and the
# deletion moved into `synapse graph-wipe` -- see src/apps/synapse/graph_cmd.zig, and
# src/core/graph_clean.zig for the classification, which is now testable
# exhaustively without a vault or a repo.

usage() { # usage [exit-code]
    awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
    exit "${1:-2}"
}

case "${1:-}" in
    ""|--dry-run) ;;
    -h|--help) usage 0 ;;
    *) usage ;;
esac

CONF="$HOME/.claude/synapse.conf"
[ -f "$CONF" ] || CONF="$HOME/.claude/second-brain.conf"
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"
VAULT="${OBSIDIAN_VAULT_DIR:-}"
[ -n "$VAULT" ] && [ -d "$VAULT" ] || { echo "synapse-graph-wipe: no vault" >&2; exit 1; }

command -v git >/dev/null || { echo "synapse-graph-wipe: git required" >&2; exit 1; }
REPO_ROOT="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || { echo "synapse-graph-wipe: not inside a git repo" >&2; exit 1; }

# shellcheck source=/dev/null
. "${SYNAPSE_LIB_DIR:-$HOME/.claude/lib/synapse}/synapse-identity.sh" 2>/dev/null || {
    echo "synapse-graph-wipe: synapse-identity.sh not installed (run setup.sh)" >&2; exit 1; }
REPO_NAME="$(synapse_namespace "$REPO_ROOT")" || exit 1

SYNAPSE_BIN_PATH="${SYNAPSE_BIN:-$HOME/.claude/bin/synapse}"
[ -x "$SYNAPSE_BIN_PATH" ] || {
    echo "synapse-graph-wipe: no synapse binary at $SYNAPSE_BIN_PATH (run setup.sh)" >&2; exit 1; }

export OBSIDIAN_VAULT_DIR="$VAULT"
export SYNAPSE_NAMESPACE="$REPO_NAME"
export SYNAPSE_REPO_ROOT="$REPO_ROOT"
export SYNAPSE_WORK_DIR="${SYNAPSE_WORK_DIR:-$HOME/.claude/synapse-work/$REPO_NAME}"
export SYNAPSE_BRANCH; SYNAPSE_BRANCH="$(synapse_branch "$REPO_ROOT")"
export SYNAPSE_REMOTE; SYNAPSE_REMOTE="$(synapse_remote "$REPO_ROOT")"

exec "$SYNAPSE_BIN_PATH" graph-wipe "$@"
