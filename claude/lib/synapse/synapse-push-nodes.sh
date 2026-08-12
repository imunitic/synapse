#!/bin/bash
# Writes every node that has both a path list and an authored body. Step 2 of a
# scripted /synapse-init.
#
# Usage: synapse-push-nodes.sh [NN ...]      (default: every staged or authored node)
#   Work dir: $SYNAPSE_WORK_DIR, default ~/.claude/synapse-work/{repo}@{branch}/.
#
# Reads  $SYNAPSE_WORK_DIR/lists/NN.txt + NN.title   (from synapse-build-lists.sh)
#        $SYNAPSE_WORK_DIR/b-NN.md                   (authored per node, see below)
# Calls  synapse-write-node.sh once per node.
#
# Each b-NN.md carries its own one-line summary in frontmatter, so everything
# authored about a node lives in one file:
#
#     ---
#     summary: One line differentiating this node from its siblings.
#     ---
#
#     ## Summary
#     ...
#
# The frontmatter is stripped before the rest is passed on as the node body, and the
# summary becomes the node's `summary` field. A node without one is an error rather
# than a default, because the index bullet has nothing to say without it.
#
# Note for agent callers: needs the sandbox disabled (localhost REST API).
set -euo pipefail

# WHAT IS LEFT HERE. Namespace resolution and dispatch. The loop moved into
# `synapse push-nodes`, and with it the one spawn of synapse-write-node.sh per
# node -- plus everything that writer spawned in turn. Only the PUT's `curl`
# remains, once per node, because the PUT is the point.
#
# Gone with the loop: resolving the writer as a sibling so an installed copy
# would not pick up whatever was on PATH, and the `mktemp -d` for the stripped
# bodies. There is no second file to find and no intermediate to write.

usage() { # usage [exit-code]
    awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
    exit "${1:-2}"
}

case "${1:-}" in
    -h|--help) usage 0 ;;
esac

command -v git >/dev/null || { echo "synapse-push-nodes: git required" >&2; exit 1; }
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_ROOT" ]] || { echo "synapse-push-nodes: not inside a git repo" >&2; exit 1; }

CONF="$HOME/.claude/synapse.conf"
[ -f "$CONF" ] || CONF="$HOME/.claude/second-brain.conf"
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"
VAULT="${OBSIDIAN_VAULT_DIR:-}"
[[ -n "$VAULT" && -d "$VAULT" ]] || { echo "synapse-push-nodes: no vault" >&2; exit 1; }

# Keyed by the same "{repo}@{branch}" its siblings use -- build-lists.sh writes
# the lists directory and this reads it, so a different key here would have them
# silently disagree about where a build's path lists live.
# shellcheck source=/dev/null
. "${SYNAPSE_LIB_DIR:-$HOME/.claude/lib/synapse}/synapse-identity.sh" 2>/dev/null || {
    echo "synapse-push-nodes: synapse-identity.sh not installed (run setup.sh)" >&2; exit 1; }
REPO_NAME="$(synapse_namespace "$REPO_ROOT")" || exit 1

SYNAPSE_BIN_PATH="${SYNAPSE_BIN:-$HOME/.claude/bin/synapse}"
[[ -x "$SYNAPSE_BIN_PATH" ]] || {
    echo "synapse-push-nodes: no synapse binary at $SYNAPSE_BIN_PATH (run setup.sh)" >&2; exit 1; }

export OBSIDIAN_VAULT_DIR="$VAULT"
export SYNAPSE_NAMESPACE="$REPO_NAME"
export SYNAPSE_REPO_ROOT="$REPO_ROOT"
export SYNAPSE_WORK_DIR="${SYNAPSE_WORK_DIR:-$HOME/.claude/synapse-work/$REPO_NAME}"
export SYNAPSE_BRANCH; SYNAPSE_BRANCH="$(synapse_branch "$REPO_ROOT")"
export SYNAPSE_REMOTE; SYNAPSE_REMOTE="$(synapse_remote "$REPO_ROOT")"

exec "$SYNAPSE_BIN_PATH" push-nodes "$@"
