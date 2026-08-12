#!/bin/bash
# Removes Synapse namespaces whose branch was deleted upstream, and reports the
# ones it cannot decide about. The only destructive tool in Synapse, which is why
# it is a command you run rather than a hook that fires: these are notes in a
# permanent vault, and the system should not delete them on inference.
#
# Usage: synapse-graph-clean.sh [--dry-run]
#        synapse-graph-clean.sh --help
#
#   --dry-run  report what would be removed, delete nothing.
#
# Operates on the repo containing $PWD, across every branch's namespace for it --
# not just the branch checked out now.
#
# What it does with each `synapse/{repo}@{branch}/` namespace:
#
#   remove  the branch had an upstream and it is gone -- merged and deleted, the
#           case this exists for. `git branch -vv` shows it as `[origin/x: gone]`.
#   report  the branch is absent locally and no upstream can be confirmed. That
#           covers a never-pushed branch deleted by hand, and a branch whose
#           config went with it, which are indistinguishable after the fact.
#           Reported for a human to remove, never deleted here.
#   keep    anything else, including a branch that was never pushed and still
#           exists -- work in progress, whose namespace is in active use.
#
# A `git fetch --prune` runs first unless --dry-run: without it a deleted branch
# still has a local remote-tracking ref, every namespace looks alive, and the
# command silently does nothing.
#
# In a repo with no remote there is no upstream to consult at all, so the test
# falls back to whether the local branch still exists. Without that fallback the
# first run in a remoteless repo would classify every namespace as deleted
# upstream and wipe the lot.
#
# Deletion is on-disk rather than over the REST API, which would need one call
# per note. The vault's own git history (see synapse-db-sync.sh) is the undo.
#
# Exit codes:
#   0 - ran (removed something, or found nothing to remove)
#   1 - could not run (no vault, not in a git repo, missing dependency)
#   2 - usage error
set -uo pipefail

# WHAT IS LEFT HERE. Config, identity and dispatch. The decision tree and the
# deletion moved into `synapse graph-clean` -- see src/apps/synapse/graph_cmd.zig, and
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
[ -n "$VAULT" ] && [ -d "$VAULT" ] || { echo "synapse-graph-clean: no vault" >&2; exit 1; }

command -v git >/dev/null || { echo "synapse-graph-clean: git required" >&2; exit 1; }
REPO_ROOT="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || { echo "synapse-graph-clean: not inside a git repo" >&2; exit 1; }

# shellcheck source=/dev/null
. "${SYNAPSE_LIB_DIR:-$HOME/.claude/lib/synapse}/synapse-identity.sh" 2>/dev/null || {
    echo "synapse-graph-clean: synapse-identity.sh not installed (run setup.sh)" >&2; exit 1; }
REPO_NAME="$(synapse_namespace "$REPO_ROOT")" || exit 1

SYNAPSE_BIN_PATH="${SYNAPSE_BIN:-$HOME/.claude/bin/synapse}"
[ -x "$SYNAPSE_BIN_PATH" ] || {
    echo "synapse-graph-clean: no synapse binary at $SYNAPSE_BIN_PATH (run setup.sh)" >&2; exit 1; }

export OBSIDIAN_VAULT_DIR="$VAULT"
export SYNAPSE_NAMESPACE="$REPO_NAME"
export SYNAPSE_REPO_ROOT="$REPO_ROOT"
export SYNAPSE_WORK_DIR="${SYNAPSE_WORK_DIR:-$HOME/.claude/synapse-work/$REPO_NAME}"
export SYNAPSE_BRANCH; SYNAPSE_BRANCH="$(synapse_branch "$REPO_ROOT")"
export SYNAPSE_REMOTE; SYNAPSE_REMOTE="$(synapse_remote "$REPO_ROOT")"

exec "$SYNAPSE_BIN_PATH" graph-clean "$@"
