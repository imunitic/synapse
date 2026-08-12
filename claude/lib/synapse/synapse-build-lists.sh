#!/bin/bash
# Expands a node manifest into one path list per node, then reports coverage.
# Step 1 of a scripted /synapse-init.
#
# Usage: synapse-build-lists.sh [--reenumerate]
#   Work dir: $SYNAPSE_WORK_DIR, default ~/.claude/synapse-work/{repo}@{branch}/.
#   Never the script's own location, and never the repo -- see below.
#
# Reads   $SYNAPSE_WORK_DIR/manifest.tsv   title <TAB> include-ERE <TAB> exclude-ERE
# Calls   claude/lib/synapse/synapse-enumerate.sh  for $SYNAPSE_WORK_DIR/all.txt -- see its
#         own header for the exclusion rules, the size cap and --reenumerate.
# Writes  $SYNAPSE_WORK_DIR/lists/NN.txt   one path list per manifest line
#         $SYNAPSE_WORK_DIR/lists/NN.title the node title for that list
#         $SYNAPSE_WORK_DIR/unassigned.txt files no node claimed
#
# Prints enumerated/covered/unassigned counts, so a bad pattern shows up as a
# number rather than a silent gap.
#
# Exit codes: 0 ok, 1 could not run, 2 usage error
set -euo pipefail

# Extracted from the header block, so help and docs/scripts.md cannot disagree.
usage() { # usage [exit-code]
    awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
    exit "${1:-2}"
}

case "${1:-}" in
    ""|--reenumerate) ;;
    -h|--help) usage 0 ;;
    *) usage ;;
esac

command -v git >/dev/null || { echo "synapse-build-lists: git required" >&2; exit 1; }
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_ROOT" ]] || { echo "synapse-build-lists: not inside a git repo" >&2; exit 1; }

# "{repo}@{branch}", not a bare repo name -- see synapse-identity.sh.
# shellcheck source=/dev/null
. "${SYNAPSE_LIB_DIR:-$HOME/.claude/lib/synapse}/synapse-identity.sh" 2>/dev/null || {
    echo "synapse-build-lists: synapse-identity.sh not installed (run setup.sh)" >&2; exit 1; }
REPO_NAME="$(synapse_namespace "$REPO_ROOT")" || exit 1

# Not $PWD: the repo is resolved from $PWD, so a $PWD default would write the
# lists into the user's checkout. Per repo, so a re-run finds the previous
# manifest.
readonly WORK_DIR="${SYNAPSE_WORK_DIR:-$HOME/.claude/synapse-work/$REPO_NAME}"
mkdir -p "$WORK_DIR"

# WHAT IS LEFT HERE. The work moved into `synapse build-lists`; this resolves the
# namespace and dispatches, same split as synapse-enumerate.sh and for the same
# reason -- synapse-identity.sh is sourced rather than executed and stays bash
# until every one of its sourcers is ported, so the namespace keeps exactly one
# implementation.
#
# Measured on syrius-querschnitt-basis (32 manifest lines, 4,892 files): 3166ms
# before, 1147ms after, with stdout, all five output files and all 64 lists/
# files byte-identical. The include/exclude EREs are still `grep -E`, spawned
# per node exactly as they were -- of the original 3166ms those greps were only
# 329ms, and the rest was the enumeration plus one `wc -l | tr -d ' '` pair per
# node to count a file the script had just written.

# Required, not optional: the binary is the only implementation of this now.
readonly SYNAPSE_BIN_PATH="${SYNAPSE_BIN:-$HOME/.claude/bin/synapse}"
[[ -x "$SYNAPSE_BIN_PATH" ]] || {
    echo "synapse-build-lists: no synapse binary at $SYNAPSE_BIN_PATH (run setup.sh)" >&2; exit 1; }

# Rebuilt rather than forwarded as "$@" -- see synapse-enumerate.sh for the empty
# argument this avoids handing the binary.
args=()
[[ "${1:-}" == "--reenumerate" ]] && args=(--reenumerate)

SYNAPSE_WORK_DIR="$WORK_DIR" exec "$SYNAPSE_BIN_PATH" build-lists ${args[@]+"${args[@]}"}
