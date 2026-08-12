#!/bin/bash
# Enumerates a repo's tracked files, dropping binaries, generated/lockfile
# noise, submodule gitlinks and oversized files. Standalone and vault-free --
# no manifest.tsv, no clustering, nothing beyond git and the repo itself.
#
# Usage: synapse-enumerate.sh [--reenumerate]
#   Work dir: $SYNAPSE_WORK_DIR, default ~/.claude/synapse-work/{repo}@{branch}/.
#   Never the script's own location, and never the repo -- see below.
#
# Writes  $SYNAPSE_WORK_DIR/all.txt        enumerated tracked files (kept if present)
#         $SYNAPSE_WORK_DIR/oversize.txt   size<TAB>path for files over the cap
#
# An existing all.txt is reused as-is unless --reenumerate forces a rebuild --
# a caller that only needs the file list, not a fresh one, pays nothing extra.
#
# Two ways to drop more than the built-in exclusions, both OR'd together:
#   ~/.claude/synapse-ignore-files.conf   one ERE per line, comments allowed
#   $SYNAPSE_EXTRA_EXCLUDE_RE             a single ERE, for one-off invocations
# Excluding a path removes it from the graph entirely -- no owning node, no
# vault search hit, no staleness flag when it changes. Right for build output
# and vendored code; wrong for anything whose edits still matter.
#
# Files over $SYNAPSE_MAX_FILE_BYTES (default 1048576, 1 MB) are skipped and
# reported, not dropped silently: no extension or name rule anticipates a
# generated monster, and a silent skip makes `enumerated` disagree with the repo.
#
# Exit codes: 0 ok, 1 could not run, 2 usage error
#
# WHAT IS LEFT HERE. The work moved into `synapse enumerate`; this resolves the
# namespace and dispatches. That split is not tidiness -- synapse-identity.sh is
# sourced, not executed, and stays bash until every one of its twelve sourcers is
# ported, so the namespace has exactly one implementation for as long as any of
# them remain. The binary is told the work dir and never derives it.
#
# Measured on syrius3 (125,351 tracked files, 124,817 enumerated): 15.9s and 65
# process spawns before, 0.59s and one spawn after -- byte-identical all.txt and
# oversize.txt. 45 of those 65 spawns were one `sed` per line of
# synapse-ignore-files.conf, comment lines included.
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

command -v git >/dev/null || { echo "synapse-enumerate: git required" >&2; exit 1; }
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_ROOT" ]] || { echo "synapse-enumerate: not inside a git repo" >&2; exit 1; }

# "{repo}@{branch}", not a bare repo name -- see synapse-identity.sh.
# shellcheck source=/dev/null
. "${SYNAPSE_LIB_DIR:-$HOME/.claude/lib/synapse}/synapse-identity.sh" 2>/dev/null || {
    echo "synapse-enumerate: synapse-identity.sh not installed (run setup.sh)" >&2; exit 1; }
REPO_NAME="$(synapse_namespace "$REPO_ROOT")" || exit 1

# Not $PWD: the repo is resolved from $PWD, so a $PWD default would write the
# enumeration into the user's checkout. Per repo, so a re-run finds the
# previous enumeration.
readonly WORK_DIR="${SYNAPSE_WORK_DIR:-$HOME/.claude/synapse-work/$REPO_NAME}"

# Required, not optional: the binary is the only implementation of this now, so
# its absence is a hard failure that names the fix rather than a degraded path.
readonly SYNAPSE_BIN_PATH="${SYNAPSE_BIN:-$HOME/.claude/bin/synapse}"
[[ -x "$SYNAPSE_BIN_PATH" ]] || {
    echo "synapse-enumerate: no synapse binary at $SYNAPSE_BIN_PATH (run setup.sh)" >&2; exit 1; }

# Rebuilt rather than forwarded as "$@", because a caller may pass one empty
# argument: synapse-build-lists.sh invokes this as `"${reenumerate_flag[@]:-}"`,
# and an unset array under that expansion becomes a single empty string rather
# than nothing at all. The old `case "${1:-}"` absorbed it silently and forwarded
# nothing; forwarding "$@" verbatim hands the binary an empty argument it is
# right to reject. Normalising here rather than teaching the binary to ignore
# empty arguments keeps the tolerance in the compatibility layer, where it
# belongs, and lets the CLI stay strict.
args=()
[[ "${1:-}" == "--reenumerate" ]] && args=(--reenumerate)

# `exec`, so the binary's own exit code is this script's -- 0 ok, 2 usage -- with
# no shell frame left to translate anything.
SYNAPSE_WORK_DIR="$WORK_DIR" exec "$SYNAPSE_BIN_PATH" enumerate ${args[@]+"${args[@]}"}
