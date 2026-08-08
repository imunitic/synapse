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
# Needs NO graph -- no nodes, no _index.json, no clustering, no vault. It reads
# $SYNAPSE_WORK_DIR/_refs.tsv and nothing else, which is why `synapse-query.sh
# callers` dispatches straight into this script ahead of that file's
# vault/namespace preamble: the property is structural, so it keeps answering
# in a repo where /synapse-init has never clustered anything. Build the index
# with:
#
#   synapse-tags-cache.sh --repo-root . --cache <cache> --paths <path:hash tsv>
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

usage() { # usage [exit-code]
  awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
  exit "${1:-2}"
}

case "${1:-}" in
  -h|--help) usage 0 ;;
esac

cname="${1:-}"; shift || true
cmode="calls"
case "${1:-}" in
  "") ;;
  --all) cmode="all"; shift ;;
  *) usage ;;
esac
[ -n "$cname" ] && [ $# -eq 0 ] || usage

command -v git >/dev/null || exit 1
croot="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$croot" ] || { echo "synapse-callers: not inside a git repo" >&2; exit 1; }
# shellcheck source=/dev/null
. "${SYNAPSE_LIB_DIR:-$HOME/.claude/lib/synapse}/synapse-identity.sh" 2>/dev/null || {
  echo "synapse-callers: synapse-identity.sh not installed (run setup.sh)" >&2; exit 1; }
cns="$(synapse_namespace "$croot")" || exit 1
cindex="${SYNAPSE_WORK_DIR:-$HOME/.claude/synapse-work/$cns}/_refs.tsv"

# Exit 1, not 0: a missing index is "could not run". Zero rows from a built
# index means "checked, not called"; silence from a missing one would be
# indistinguishable from it, which is the confusion this whole script avoids.
[ -f "$cindex" ] || {
  echo "synapse-callers: no reference index at $cindex -- run synapse-build-refs.sh" >&2
  exit 1
}

# `look` binary-searches the sorted index, then awk applies the exact field
# match. Both halves are load-bearing: `look` PREFIX-matches (asking for `bet`
# returns `beta`), so on its own it over-reports, and awk on its own is a full
# scan. Measured on a large repo's 1.4 GB index: look+awk 0.235s, awk alone 26s.
#
# Not grep, and the reason is not obvious: which `grep` is on PATH decides the
# answer. The same query measured 0.15s under ugrep and 8.3s under BSD
# /usr/bin/grep, and a script cannot assume the interactive shell's grep.
#
# THIS IS COUPLED TO synapse-build-refs.sh's `LC_ALL=C sort`. `look` compares
# raw bytes when given neither -d nor -f, which is what that sort produces; any
# change to either side must change both, because a disagreement returns
# nothing and is indistinguishable from "not called". tests/synapse-callers.bats
# asserts the two agree against a full scan rather than leaving it to review.
if command -v look >/dev/null; then
  LC_ALL=C look -t "$(printf '\t')" "$cname" "$cindex" 2>/dev/null
else
  # Correct but O(index). Only reached where `look` is absent; the answer is
  # identical, so this degrades speed rather than accuracy.
  LC_ALL=C cat "$cindex"
fi | LC_ALL=C awk -F'\t' -v n="$cname" -v mode="$cmode" '
      $1 != n { next }
      mode == "calls" && !($2 == "ref" && $3 == "call") { next }
      mode == "calls" { print $4 "\t" $5; next }
      { print $2 "\t" $3 "\t" $4 "\t" $5 }
    '

# LOAD-BEARING. `look` exits non-zero on "no match", which is a normal outcome
# here (not a failure) -- under `set -uo pipefail` that exit code is what the
# whole pipeline reports, since awk itself exits 0 even on zero matching lines.
# Without this, "never called" would silently become exit 1, indistinguishable
# from "could not run" to a caller checking $?.
exit 0
