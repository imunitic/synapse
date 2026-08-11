#!/bin/bash
# Projects a project's tags cache into a flat, sorted reference index -- the
# artifact `synapse-query.sh callers` reads. One line per tag, so "who calls X"
# is a text lookup rather than a JSON traversal.
#
# Usage: synapse-build-refs.sh [--cache <path>] [--out <path>] [--repo <path>]
#        synapse-build-refs.sh --help
#
#   --cache  the tags cache to project. Default $SYNAPSE_WORK_DIR/_tags_cache.bin,
#            i.e. ~/.claude/synapse-work/{repo}@{branch}/_tags_cache.bin.
#   --out    where to write the index. Default $SYNAPSE_WORK_DIR/_refs.tsv.
#   --repo   the repo whose work dir supplies those defaults. Default: the git
#            toplevel containing $PWD. Only used to resolve defaults; nothing
#            here reads the working tree.
#
# Output, LC_ALL=C sorted, one tag per line:
#
#   name <TAB> def|ref <TAB> kind <TAB> path:line <TAB> expression
#
# `def|ref` is what tree-sitter calls the tag; `kind` is its syntactic category
# (`class`, `method`, `call`, `implementation`, ...). Both are kept because they
# answer different questions: a `ref` is not necessarily a call -- an
# `implements Foo` clause is `ref | implementation` -- so a callers query that
# filtered on `ref` alone would over-report.
#
# WHY A SEPARATE FILE RATHER THAN QUERYING THE CACHE. The constraint is format,
# not size. Disk is cheap and the cache already lives in the work dir rather
# than the version-controlled vault. What bites is querying JSON at scale: one
# `jq` pass over a 4.6 MB cache measured 0.064s, which extrapolates to ~13s per
# query at a large repo's 942 MB -- for something meant to feel interactive. The same
# data as flat sorted lines is a different regime: measured against a 560 MB
# index, `grep` answered in 0.092s.
#
# THE NAME COLUMN IS SPACE-PADDED IN tree-sitter's OUTPUT and is trimmed here.
# `execute` is emitted as `execute   `, so an exact-match lookup against the raw
# text silently finds nothing -- the failure returns success and no rows, which
# is indistinguishable from "not called anywhere". synapse-query.sh's `symbol`
# already trims for the same reason.
#
# Rebuilt, never appended to: it is derived from the cache and cheap to redo, so
# a partial write from an interrupted run is replaced rather than merged. Files
# the cache marks `unsupported` (no grammar) contribute nothing and are counted
# separately, so "no hits" can be told apart from "never parsed".
#
# Exit codes:
#   0 - index written; prints tags/files/unsupported counts on stderr
#   1 - could not run (no cache, unreadable cache, missing dependency)
#   2 - usage error
set -euo pipefail

# Extracted from the header block, so help and docs/scripts.md cannot disagree.
usage() { # usage [exit-code]
  awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
  exit "${1:-2}"
}

CACHE=""
OUT=""
REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --cache) CACHE="${2:-}"; [ -n "$CACHE" ] || usage; shift 2 ;;
    --out)   OUT="${2:-}";   [ -n "$OUT" ] || usage;   shift 2 ;;
    --repo)  REPO="${2:-}";  [ -n "$REPO" ] || usage;  shift 2 ;;
    -h|--help) usage 0 ;;
    *) usage ;;
  esac
done

# The compiled binary. `$SYNAPSE_BIN` overrides it, which is how the test suite
# points this at a build with the grammar step stubbed.
SYNAPSE_BIN="${SYNAPSE_BIN:-$HOME/.claude/bin/synapse}"
[ -x "$SYNAPSE_BIN" ] || { echo "synapse-build-refs: $SYNAPSE_BIN not installed (run setup.sh)" >&2; exit 1; }

# Only needed to resolve the work-dir defaults. An explicit --cache and --out
# make this script usable against a cache for a repo that is not checked out
# here at all, which is what the tests do.
if [ -z "$CACHE" ] || [ -z "$OUT" ]; then
  command -v git >/dev/null || { echo "synapse-build-refs: git required" >&2; exit 1; }
  [ -n "$REPO" ] || REPO="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$REPO" ] || { echo "synapse-build-refs: not inside a git repo and no --cache/--out given" >&2; exit 1; }
  # shellcheck source=/dev/null
  . "${SYNAPSE_LIB_DIR:-$HOME/.claude/lib/synapse}/synapse-identity.sh" 2>/dev/null || {
    echo "synapse-build-refs: synapse-identity.sh not installed (run setup.sh)" >&2; exit 1; }
  REPO_NAME="$(synapse_namespace "$REPO")" || exit 1
  WORK_DIR="${SYNAPSE_WORK_DIR:-$HOME/.claude/synapse-work/$REPO_NAME}"
  [ -n "$CACHE" ] || CACHE="$WORK_DIR/_tags_cache.bin"
  [ -n "$OUT" ] || OUT="$WORK_DIR/_refs.tsv"
fi

[ -f "$CACHE" ] || { echo "synapse-build-refs: no tags cache at $CACHE -- run 'synapse tags-cache' first" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")" || exit 1

TMP="$(mktemp -d "${TMPDIR:-/tmp}/synapse-build-refs.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

# The projection is `synapse tags-cache --refs`, which walks the cache's record
# table and re-parses each cached tag line into the columns below. That replaced
# a jq pass plus ~50 lines of awk doing the same parse; the awk's exact
# behaviour, quirks included, is what `src/core/tag_line.zig` was verified
# against over 329,362 real rows.
"$SYNAPSE_BIN" tags-cache --refs "$CACHE" > "$TMP/parsed.tsv" \
  || { echo "synapse-build-refs: unreadable cache: $CACHE" >&2; exit 1; }

UNSUPPORTED="$("$SYNAPSE_BIN" tags-cache --dump "$CACHE" 2>/dev/null | LC_ALL=C grep -c '^U	' || true)"

# LC_ALL=C, AND THAT IS A CONTRACT, NOT A PREFERENCE. `synapse-query.sh callers`
# binary-searches this file with `look`, which compares raw bytes when given
# neither -d nor -f -- exactly what LC_ALL=C sort produces. Sorting under any
# other collation makes that search miss, and a miss returns nothing, which is
# indistinguishable from "this name is never called". Changing this line means
# changing the lookup in synapse-query.sh too.
LC_ALL=C sort -u "$TMP/parsed.tsv" > "$OUT"

TAGS="$(LC_ALL=C wc -l < "$OUT" | tr -d ' ')"
FILES="$(LC_ALL=C cut -f4 "$OUT" | sed 's/:[0-9]*$//' | LC_ALL=C sort -u | LC_ALL=C wc -l | tr -d ' ')"
DEFS="$(LC_ALL=C awk -F'\t' '$2=="def"' "$OUT" | LC_ALL=C wc -l | tr -d ' ')"
REFS="$(LC_ALL=C awk -F'\t' '$2=="ref"' "$OUT" | LC_ALL=C wc -l | tr -d ' ')"

printf 'synapse-build-refs: %s tags (%s def, %s ref) over %s files, %s unsupported -> %s\n' \
  "$TAGS" "$DEFS" "$REFS" "$FILES" "$UNSUPPORTED" "$OUT" >&2
