#!/bin/bash
# Builds and uploads synapse/{repo}/Index.md -- the per-project node map, carrying
# the `remote` field the SessionStart hook verifies before injecting a pointer.
# Step 4 (last) of a scripted /synapse-init.
#
# Usage: synapse-build-project-index.sh
#   Work dir: $SYNAPSE_WORK_DIR, default ~/.claude/synapse-work/{repo}@{branch}/.
#
# Reads  $SYNAPSE_WORK_DIR/lists/NN.txt + NN.title   (for titles and file counts)
#        each node's `summary` frontmatter field, fetched from the vault
#
# Run after the nodes exist: summaries are read back off the nodes, and a node that
# is missing or has no `summary` is a hard error. Emits no repo-specific prose of
# its own -- see docs/synapse-graph.md for why.
#
# Note for agent callers: needs the sandbox disabled (localhost REST API) -- the
# PUT still goes through it, which is what keeps Obsidian's view and the vault's
# git history correct.
#
# WHAT IS LEFT HERE. Namespace resolution and dispatch. The build moved into
# `synapse build-project-index`, and the format itself into src/core/
# project_index.zig -- one writer, three readers (the SessionStart hook, query's
# preamble, write-node), which is exactly the shape that drifts when it lives in
# a heredoc.
#
# Gone with it: the JsonLogic search that fetched every node's summary and the
# `jq` filter that read it -- summaries come off the nodes on disk now, which
# also answers "missing node" versus "missing summary" without a follow-up stat.
# And `find`, `basename`, `cat`, `tr`, `wc`, `sort`, `awk` and the mktemp.
set -euo pipefail

# Extracted from the header block, so help and docs/scripts.md cannot disagree.
usage() { # usage [exit-code]
    awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
    exit "${1:-2}"
}

case "${1:-}" in
    -h|--help) usage 0 ;;
esac

command -v git >/dev/null || { echo "synapse-build-project-index: git required" >&2; exit 1; }
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_ROOT" ]] || {
    echo "synapse-build-project-index: not inside a git repo" >&2; exit 1; }

CONF="$HOME/.claude/synapse.conf"
[ -f "$CONF" ] || CONF="$HOME/.claude/second-brain.conf"
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"
VAULT="${OBSIDIAN_VAULT_DIR:-}"
[[ -n "$VAULT" && -d "$VAULT" ]] || {
    echo "synapse-build-project-index: no vault" >&2; exit 1; }

readonly CERT="$HOME/.claude/obsidian-local-rest-api-ca.pem"
readonly PLUGIN_DATA="$VAULT/.obsidian/plugins/obsidian-local-rest-api/data.json"
[[ -f "$PLUGIN_DATA" && -f "$CERT" ]] || {
    echo "synapse-build-project-index: REST API not configured" >&2; exit 1; }

# "{repo}@{branch}", not a bare repo name -- see synapse-identity.sh.
# shellcheck source=/dev/null
. "${SYNAPSE_LIB_DIR:-$HOME/.claude/lib/synapse}/synapse-identity.sh" 2>/dev/null || {
    echo "synapse-build-project-index: synapse-identity.sh not installed (run setup.sh)" >&2; exit 1; }
REPO_NAME="$(synapse_namespace "$REPO_ROOT")" || exit 1

SYNAPSE_BIN_PATH="${SYNAPSE_BIN:-$HOME/.claude/bin/synapse}"
[[ -x "$SYNAPSE_BIN_PATH" ]] || {
    echo "synapse-build-project-index: no synapse binary at $SYNAPSE_BIN_PATH (run setup.sh)" >&2; exit 1; }

export OBSIDIAN_VAULT_DIR="$VAULT"
export SYNAPSE_NAMESPACE="$REPO_NAME"
export SYNAPSE_REPO_ROOT="$REPO_ROOT"
export SYNAPSE_WORK_DIR="${SYNAPSE_WORK_DIR:-$HOME/.claude/synapse-work/$REPO_NAME}"
export SYNAPSE_BRANCH; SYNAPSE_BRANCH="$(synapse_branch "$REPO_ROOT")"
export SYNAPSE_REMOTE; SYNAPSE_REMOTE="$(synapse_remote "$REPO_ROOT")"

exec "$SYNAPSE_BIN_PATH" build-project-index "$@"
