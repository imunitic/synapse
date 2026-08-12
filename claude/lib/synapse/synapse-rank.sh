#!/bin/bash
# Ranks a node's sources by how much they are worth READING when authoring its
# prose. Decides reading order only: `sources` stays exhaustive, so coverage,
# staleness and vault search are all unaffected by anything here. See
# docs/synapse-graph.md's "Orientation from vocabulary" section.
#
# Usage: synapse-rank.sh --sources <file> [--repo <path>] [--top N] [--tier T]
#                        [--pool summary|crux]
#   --sources  file of repo-relative paths, one per line -- a node's `sources`,
#              or synapse-build-lists.sh's lists/NN.txt.
#   --repo     default: the git toplevel containing $PWD.
#   --top      lines per tier, default 10. `--top 0` prints every ranked file.
#   --tier     restrict output to `code` or `dsl`. Default: both.
#   --pool     which half of the authoring job this is for, default `summary`
#              (which is the unrestricted behaviour). See below.
#
# THE TWO POOLS ARE NOT THE SAME SET OF FILES, and that is a measured result
# rather than tidiness.
#
#   summary   everything. A summary is made of NAMES, so it draws on test class
#             names and DSL consumer names as well as implementation -- both at
#             zero read cost, and both carrying domain concepts nothing else
#             surfaces. On a real node `Gegenpartei` and `Frist` came only from
#             test class names.
#
#   crux      implementation only, tests excluded, code tier only. A crux is
#             concentrated logic, and none of the seven `crux_path` values
#             recorded in a real namespace is a test. Density ranks tests high
#             for a structural reason -- many small `@Test` methods, each a
#             definition, in a small file -- so without this they would crowd
#             out the thing a crux is supposed to point at.
#
# What counts as a test is a path/filename heuristic, not a parse, and it is
# deliberately conservative about the boundary: `FooTest.java` is a test,
# `Latest.java` is not. Override the whole rule with $SYNAPSE_TEST_PATH_RE (one
# ERE) for a project that names tests some other way.
#
# Prints `tier <TAB> score <TAB> path`, ranked within each tier, code first.
# Counts per tier go to stderr, so a node whose files all scored zero is a
# number rather than an empty answer.
#
# THREE TIERS, because "relevant" means different things per kind of file.
#
#   code    definitions per KB. NOT raw definition counts: those rank generated
#           constant tables first, which is the opposite of useful. Normalising
#           by size moved a known crux from rank 17 to rank 7 of 574 on a real
#           node. Definitions specifically, not all tags -- a reference says the
#           file USES something, a definition says it DECLARES it, and a summary
#           is made of what a subsystem declares.
#
#   dsl     a declarative file carries little meaning on its own; the code that
#           consumes it carries the domain verbs. So the CONSUMER is what gets
#           ranked, scored by how many declarations it serves. Resolved by stem
#           plus module prefix, never by parsing.
#
#   ignore  everything else -- config, data, docs, generated output. Scored
#           zero and omitted from the ranking, still fully covered by `sources`.
#
# WHAT COUNTS AS DSL IS DERIVED, NOT LISTED. A non-code file is a declaration
# exactly when some code file in the same module has a stem starting with its
# own -- `Adresse.domvo` resolving to `Adresse.java`, `Kunde.gui` to
# `KundeController.java`. Shipping a list of extensions instead would have meant
# shipping one project's vocabulary (`.gui`, `.domvo`, `.bo`, `.paramvo`) as if
# it were universal, and this toolkit is meant to be language-agnostic with no
# per-repo curation.
#
# THE MODULE PREFIX IS LOAD-BEARING, not a tie-breaker. Generic stems -- the
# measured examples were `Adresse` and `NatPerson` -- match dozens of unrelated
# classes across a large repo, so a stem-only hop resolves to whichever one
# sorts first and is worse than no answer. Constraining to the declaration's own
# module is what makes the hop mean anything.
#
# Consumers are searched repo-wide rather than within `sources`: the code that
# uses a node's declarations is frequently the reason to read it, and is not
# always a file the node itself owns.
#
# Exit codes:
#   0 - ran. Empty output means nothing scored above zero, which for a node made
#       entirely of config is the correct answer, not a failure.
#   1 - could not run (not a git repo, unreadable sources, no synapse binary)
#   2 - usage error
set -uo pipefail

usage() { # usage [exit-code]
    awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
    exit "${1:-2}"
}

SOURCES=""
REPO=""
TOP=10
TIER=""
POOL="summary"
while [ $# -gt 0 ]; do
    case "$1" in
        --sources) SOURCES="${2:-}"; shift 2 || usage ;;
        --repo)    REPO="${2:-}";    shift 2 || usage ;;
        --top)     TOP="${2:-}";     shift 2 || usage ;;
        --tier)    TIER="${2:-}";    shift 2 || usage ;;
        --pool)    POOL="${2:-}";    shift 2 || usage ;;
        -h|--help) usage 0 ;;
        *) usage ;;
    esac
done
[ -n "$SOURCES" ] || usage
case "$TOP" in ''|*[!0-9]*) usage ;; esac
case "$TIER" in ''|code|dsl) ;; *) usage ;; esac
case "$POOL" in summary|crux) ;; *) usage ;; esac
# A crux is code, so the DSL tier has nothing to contribute to it. Set here
# rather than checked at every use, so the two selectors cannot disagree.
[ "$POOL" != "crux" ] || TIER="code"
[ -f "$SOURCES" ] || { echo "synapse-rank: no such sources file: $SOURCES" >&2; exit 1; }

command -v git >/dev/null || { echo "synapse-rank: git required" >&2; exit 1; }
if [ -n "$REPO" ]; then
    REPO_ROOT="$(cd "$REPO" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"
else
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
fi
[ -n "$REPO_ROOT" ] || { echo "synapse-rank: not inside a git repo" >&2; exit 1; }


# WHAT IS LEFT HERE. Argument validation and dispatch. The ranking moved into
# `synapse rank`, threaded on the strength of the measurement synapse-vocab.sh's
# port produced: tagging is real per-file CPU work, so the `xargs -P` chunking was
# buying parallelism rather than amortising startup.
#
# Gone with it: split, the generated worker.sh, xargs -P, one `synapse tags` spawn
# per chunk, the .tags intermediates, the batched stat, and four awk programs. The
# two tier rules, the test heuristic and the stem/module keying live in
# src/core/rank.zig -- the heuristic checked against this script's own ERE over
# 138,832 real paths, agreeing on all 24,911 it calls tests.

# Required, not optional: the binary is the only implementation of this now.
readonly SYNAPSE_BIN_PATH="${SYNAPSE_BIN:-$HOME/.claude/bin/synapse}"
[ -x "$SYNAPSE_BIN_PATH" ] || { echo "synapse-rank: $SYNAPSE_BIN_PATH not installed (run setup.sh)" >&2; exit 1; }

set -- --sources "$SOURCES" --top "$TOP" --pool "$POOL"
[ -z "$TIER" ] || set -- "$@" --tier "$TIER"
[ -z "$REPO" ] || set -- "$@" --repo "$REPO"
exec "$SYNAPSE_BIN_PATH" rank "$@"
