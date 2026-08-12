#!/bin/bash
# Repo-wide call sites of an exact name, over the flat reference index
# synapse-build-refs.sh projects from the tags cache.
#
# Usage: synapse-callers.sh <name> [--all]   (operates on the repo containing $PWD)
#
#   <name>          exact symbol name (not a prefix, not a regex)
#   (default)        calls only, as path:line<TAB>calling expression
#   --all            every def and ref, not only calls, as
#                    def|ref<TAB>kind<TAB>path:line<TAB>expression
#
# Needs NO graph -- no nodes, no reverse index, no clustering, no vault. It reads
# $SYNAPSE_WORK_DIR/_refs.tsv and nothing else, which is why `synapse-query.sh
# callers` dispatches straight into this script ahead of that file's
# vault/namespace preamble: the property is structural, so it keeps answering
# in a repo where /synapse-init has never clustered anything. Build the index
# with:
#
#   synapse tags-cache --repo-root . --cache <cache> --paths <path:hash tsv>
#   synapse-build-refs.sh
#
# It is name-based like `symbol`, so hits are candidates with evidence rather
# than resolved callers -- the calling expression is on the line, which usually
# settles the receiver without opening the file. Out of reach, and not worked
# around: reflective invocation, and a call whose receiver sits on another line
# (a fluent chain split across lines). Interface dispatch appears as the
# interface method, which is normally the answer wanted rather than a loss.
#
# `symbol` and `callers` differ in scope, not technique. `symbol` is scoped to
# one node's sources and re-hashes them on every call, so it answers "within this
# subsystem" and costs O(node sources); `callers` is repo-wide over a precomputed
# index, so it answers "anywhere" and costs one pass over a text file.
#
# Exit codes:
#   0 - ran successfully. Empty output means "checked, never called" -- a real
#       answer, not an error.
#   1 - could not run (not a git repo, synapse-identity.sh missing, no
#       reference index built yet)
#   2 - usage error
set -uo pipefail

# WHAT IS LEFT HERE. Namespace resolution and dispatch. The lookup moved into
# `synapse callers`: `look` and `awk` are gone, and with them the "which grep is
# on PATH decides the answer" hazard and the O(index) fallback for machines
# without `look`. The binary search is now `core/refs.zig`, which improves on
# `look` in one respect -- `look` matched by prefix, so a query for `bet`
# returned every `beta` and the exact match needed a second pass.

usage() { # usage [exit-code]
  awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
  exit "${1:-2}"
}

case "${1:-}" in
  -h|--help) usage 0 ;;
esac

command -v git >/dev/null || exit 1
croot="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$croot" ] || { echo "synapse-callers: not inside a git repo" >&2; exit 1; }
# shellcheck source=/dev/null
. "${SYNAPSE_LIB_DIR:-$HOME/.claude/lib/synapse}/synapse-identity.sh" 2>/dev/null || {
  echo "synapse-callers: synapse-identity.sh not installed (run setup.sh)" >&2; exit 1; }
cns="$(synapse_namespace "$croot")" || exit 1

SYNAPSE_BIN_PATH="${SYNAPSE_BIN:-$HOME/.claude/bin/synapse}"
[ -x "$SYNAPSE_BIN_PATH" ] || {
  echo "synapse-callers: no synapse binary at $SYNAPSE_BIN_PATH (run setup.sh)" >&2; exit 1; }

export SYNAPSE_WORK_DIR="${SYNAPSE_WORK_DIR:-$HOME/.claude/synapse-work/$cns}"
exec "$SYNAPSE_BIN_PATH" callers "$@"
