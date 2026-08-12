#!/bin/bash
# Builds $SYNAPSE_WORK_DIR/_index.bin -- the machine-only reverse index from
# every source path to the node filenames that claim it, plus the unassigned
# list. Step 3 of a scripted /synapse-init.
#
# Usage: synapse-build-index.sh
#   Work dir: $SYNAPSE_WORK_DIR, default ~/.claude/synapse-work/{repo}@{branch}/.
#
# Reads  $SYNAPSE_WORK_DIR/lists/NN.txt + NN.title, unassigned.txt
# Writes $SYNAPSE_WORK_DIR/_index.bin
#
# Read by the PostToolUse staleness hook, so it must cover every enumerated file:
# an edit to an unlisted path flags nothing stale.
#
# `synapse index build --lists` does the whole job: it authors the (path, node)
# pairs from lists/NN.txt and NN.title, encodes them, and reports what a reader
# will actually find by reopening what it just wrote. Two earlier changes stand:
# the index no longer lives in the vault -- it is derived, gitignored there and
# never travelled, so PUT-ing 26 MB over the REST API bought nothing, which is
# why this needs no sandbox exemption and reads no API key -- and `jq` is gone,
# since authoring tens of megabytes of JSON was the only reason it was here.
#
# What went with the pair authoring: one `basename` and one `tr` and one `awk`
# per node list, and the mktemp holding the pairs between the two halves.
set -euo pipefail

# Extracted from the header block, so help and docs/scripts.md cannot disagree.
usage() { # usage [exit-code]
    awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
    exit "${1:-2}"
}

case "${1:-}" in
    -h|--help) usage 0 ;;
esac

command -v git >/dev/null || { echo "synapse-build-index: git required" >&2; exit 1; }
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_ROOT" ]] || { echo "synapse-build-index: not inside a git repo" >&2; exit 1; }

# REPO_NAME holds the namespace key "{repo}@{branch}", not a bare repo name -- a
# namespace describes one branch.
# shellcheck source=/dev/null
. "${SYNAPSE_LIB_DIR:-$HOME/.claude/lib/synapse}/synapse-identity.sh" 2>/dev/null || {
    echo "synapse-build-index: synapse-identity.sh not installed (run setup.sh)" >&2; exit 1; }
REPO_NAME="$(synapse_namespace "$REPO_ROOT")" || exit 1

# Never $PWD: that is the repo, and working files do not belong in a user's checkout.
readonly WORK_DIR="${SYNAPSE_WORK_DIR:-$HOME/.claude/synapse-work/$REPO_NAME}"
readonly LISTS="$WORK_DIR/lists"
readonly INDEX_FILE="$WORK_DIR/_index.bin"

[[ -d "$LISTS" ]] || { echo "synapse-build-index: no lists/ in $WORK_DIR" >&2; exit 1; }
[[ -f "$WORK_DIR/unassigned.txt" ]] || { echo "synapse-build-index: no unassigned.txt in $WORK_DIR" >&2; exit 1; }

# Required, not optional -- unlike synapse-write-node.sh's tags-cache refresh,
# which is a byproduct and degrades to skipping. Here the binary is the only
# writer there is, so its absence is a hard failure that names the fix.
readonly SYNAPSE_BIN_PATH="${SYNAPSE_BIN:-$HOME/.claude/bin/synapse}"
[[ -x "$SYNAPSE_BIN_PATH" ]] || {
    echo "synapse-build-index: no synapse binary at $SYNAPSE_BIN_PATH (run setup.sh)" >&2; exit 1; }

# The binary reports what a reader will actually find, by reopening what it just
# wrote; this script owns the wording and takes the numbers.
if ! stats="$("$SYNAPSE_BIN_PATH" index build \
        --lists "$LISTS" \
        --unassigned "$WORK_DIR/unassigned.txt" \
        --out "$INDEX_FILE")"; then
    exit 1
fi

printf '_index.bin written: %s\n' "$stats"
