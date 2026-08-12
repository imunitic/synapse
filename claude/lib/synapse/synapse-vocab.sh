#!/bin/bash
# Reduces a whole repository to its symbol vocabulary, grouped by directory:
# `group <TAB> word <TAB> count`. Evidence for the clustering step of
# /synapse-init, so that deciding what a subsystem is about costs symbol names
# rather than source lines. See docs/synapse-graph.md's "Orientation from
# vocabulary" section.
#
# Usage: synapse-vocab.sh [--repo <path>] [--depth N] [--chunk N] [--out <dir>]
#                         [--lists <dir>]
#   --repo   default: the git toplevel containing $PWD.
#   --depth  directory levels that make a group, default 2 (`src/main` from
#            `src/main/java/Foo.java`). A path shallower than that groups by
#            whatever prefix it has; a repo-root file groups as `(repo root)`.
#   --chunk  files per tree-sitter invocation, default: one chunk per core,
#            floor 500. Only a parallelism knob -- see below.
#   --out    default: $SYNAPSE_WORK_DIR, i.e. ~/.claude/synapse-work/{repo}@{branch}/.
#   --lists  key by CLUSTER instead of by directory: a synapse-build-lists.sh
#            lists/ dir, where each NN.txt is a node's paths and NN.title its
#            name. Files no list claims are skipped. --depth is then unused.
#
# Writes  <out>/groupwords.tsv   group <TAB> word <TAB> count, group then count desc
#         <out>/counts.tsv       group <TAB> file count, count desc
#
# TWO GROUPINGS, ONE SCRIPT, AND WHY BOTH ARE NEEDED. Directory grouping is the
# orientation evidence -- it exists before anyone has decided what the nodes
# are, which is the whole point of it. Cluster grouping is what the quality gate
# scores, and a cluster is not generally a union of directories, so it cannot be
# derived from the directory-keyed table after the fact. The second run costs
# another tagging pass (~51s on a large repo) against a build that was measured in
# hours, so exactness was the cheaper side of that trade.
#
# Prints groups / files / code files / pairs on stderr, so a repo that yielded
# no vocabulary is a number rather than an empty file nobody looked at.
#
# WHY THIS IS AFFORDABLE. Tagging is one in-process pass per worker thread, so
# there is no CLI startup to amortise and a grammar loads once per extension per
# thread. Chunking exists only to use more than one core; it is not what makes
# this cheap.
#
# THE PARALLELISM IS LOAD-BEARING, unlike the equivalent apparatus stage 1 dropped
# from the tags cache. Measured on syrius-querschnitt-basis (3,642 code files):
# 1987ms for the twelve-process bash, 4453ms for a sequential in-process pass, and
# 1142ms threaded -- byte-identical output in all three. Tree-sitter parsing
# thousands of files is real CPU work, so cores win even against process overhead.
#
# RAW TAGS ARE NEVER STORED. Each worker pipes `synapse tags` straight into
# the word reduction and keeps only `group <TAB> word`. The tags themselves are
# ~942 MB on a large repo against 6.9 MB of vocabulary, so writing them out first
# would cost more disk than the entire graph.
#
# EVERY TRANSFORM IS awk, NOT sed. `sed` works on whole lines, so a character
# class meant for the symbol field also mangles the group key and the tab
# between them -- and BSD `sed` reads `\t` inside a bracket expression as a
# literal `t`, which silently destroys the field separator rather than erroring.
# Everything runs under LC_ALL=C for the same class of reason: macOS `awk`
# aborts mid-stream on Latin-1 bytes, which real repos contain.
#
# Word splitting matches the identifier conventions, not English: `getUserName`
# gives get/user/name, `user_name` gives user/name, and a run of capitals stays
# with what follows it (`HTTPServer` is one word). Words shorter than 4
# characters, pure digits, and anything in ~/.claude/synapse-prompt-stopwords.conf
# are dropped -- the same list the prompt tokenizer uses, deliberately, because
# two stopword lists that disagree is how two mechanisms start giving different
# answers.
#
# Exit codes:
#   0 - ran. An EMPTY groupwords.tsv is a legitimate outcome (no file had a
#       usable grammar) and the caller must test for it: that is the signal to
#       fall back to `synapse-orientation`, not an error to report.
#   1 - could not run (not a git repo, no synapse binary, no work dir)
#   2 - usage error
set -uo pipefail

usage() { # usage [exit-code]
    awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
    exit "${1:-2}"
}

REPO=""
DEPTH=2
CHUNK=""
OUT=""
LISTS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo)  REPO="${2:-}";  shift 2 || usage ;;
        --depth) DEPTH="${2:-}"; shift 2 || usage ;;
        --chunk) CHUNK="${2:-}"; shift 2 || usage ;;
        --out)   OUT="${2:-}";   shift 2 || usage ;;
        --lists) LISTS="${2:-}"; shift 2 || usage ;;
        -h|--help) usage 0 ;;
        *) usage ;;
    esac
done
case "$DEPTH" in ''|*[!0-9]*) usage ;; esac
[ "$DEPTH" -ge 1 ] || usage
[ -z "$CHUNK" ] || case "$CHUNK" in ''|*[!0-9]*) usage ;; esac
[ -z "$LISTS" ] || [ -d "$LISTS" ] || { echo "synapse-vocab: no such lists dir: $LISTS" >&2; exit 1; }

command -v git >/dev/null || { echo "synapse-vocab: git required" >&2; exit 1; }
if [ -n "$REPO" ]; then
    REPO_ROOT="$(cd "$REPO" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"
else
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
[ -n "$REPO_ROOT" ] || { echo "synapse-vocab: not inside a git repo" >&2; exit 1; }


# WHAT IS LEFT HERE. The work moved into `synapse vocab`; this resolves the
# namespace and dispatches, same split as the other ported scripts -- and for the
# same reason, that synapse-identity.sh is sourced rather than executed and stays
# bash until every one of its sourcers is ported.
#
# Gone with it: `split`, the generated `worker.sh`, `xargs -P`, one `synapse tags`
# spawn per chunk, one `awk` per chunk, the `words/*.tsv` intermediates, and both
# awk programs. The reduction lives in src/core/vocab.zig, checked against the awk
# over 5,007 real identifiers.

# Required, not optional: the binary is the only implementation of this now.
readonly SYNAPSE_BIN_PATH="${SYNAPSE_BIN:-$HOME/.claude/bin/synapse}"
[ -x "$SYNAPSE_BIN_PATH" ] || {
    echo "synapse-vocab: $SYNAPSE_BIN_PATH not installed (run setup.sh) -- use synapse-orientation instead" >&2
    exit 1; }

# `--out` is resolved here when the caller did not give one, because that is the
# branch that needs the namespace. With one, nothing here needs identity at all.
if [ -z "$OUT" ]; then
    # shellcheck source=/dev/null
    . "${SYNAPSE_LIB_DIR:-$HOME/.claude/lib/synapse}/synapse-identity.sh" 2>/dev/null || {
        echo "synapse-vocab: synapse-identity.sh not installed (run setup.sh)" >&2; exit 1; }
    REPO_NAME="$(synapse_namespace "$REPO_ROOT")" || exit 1
    OUT="${SYNAPSE_WORK_DIR:-$HOME/.claude/synapse-work/$REPO_NAME}"
fi

set -- --depth "$DEPTH" --out "$OUT"
[ -z "$CHUNK" ] || set -- "$@" --chunk "$CHUNK"
[ -z "$LISTS" ] || set -- "$@" --lists "$LISTS"
[ -z "$REPO" ] || set -- "$@" --repo "$REPO"
exec "$SYNAPSE_BIN_PATH" vocab "$@"
