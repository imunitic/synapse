#!/bin/bash
# Flags candidate clusters that own no vocabulary of their own, before anyone
# pays to author their prose. The one quality check /synapse-init never had:
# coverage was already provable by regex expansion plus `comm`, but whether a
# cluster corresponds to a *concept* was judgment, discovered only when someone
# tried to write its summary and found there was nothing to say.
#
# Usage: synapse-gate.sh --vocab <groupwords.tsv> [--all] [--top N]
#   --vocab  cluster-keyed vocabulary: `cluster <TAB> word <TAB> count`, i.e.
#            synapse-vocab.sh run with --lists. NOT the directory-keyed table --
#            see "RUN IT ON CLUSTERS" below, which is the whole reason the
#            threshold ever looked unstable.
#   --all    print every cluster with its score, not only the flagged ones.
#   --top    terms per cluster the rule looks at, default 8.
#
# Prints `cluster <TAB> rare-count <TAB> flagged|ok <TAB> top terms`, one line
# per flagged cluster -- so empty output means every cluster is differentiated,
# matching the reporting convention of `synapse-query.sh stale`/`drift`/
# `grounding`. `--all` adds the `ok` rows in the same shape rather than a
# second one, so the same field positions parse either way.
#
# THE RULE, and why it is this and not something more obvious:
#
#   rare  := df <= max(2, N/20)      # N = number of clusters, df over clusters
#   flag  := count of rare terms among the cluster's top TOP <= 1
#
# Terms rank within a cluster by raw count. Ranking by tf-idf *sum* is what
# fails: a sum follows frequency rather than rarity, and it put two known-bad
# clusters near the TOP of the list. What separates a real concept from a
# generic one is not how much distinctive vocabulary it has in total, it is
# whether it has any at all -- so the rule counts near-unique terms rather than
# weighing them.
#
# Measured against the four known-undifferentiated clusters in a large repo
# (46 nodes): tolerance 0 catches three with no false positives, tolerance 1
# catches all four with no false positives, tolerance 2 catches four but flags
# five good clusters as well. The `max(2, N/20)` form reduces to the constant
# that worked at that corpus size and scales with cluster count instead of
# needing recalibration per repo.
#
# RUN IT ON CLUSTERS, NOT ON MODULE GROUPS. A few dozen candidate clusters, not
# the several hundred directory groups that form the orientation evidence.
# Document frequency across 500 groups means something entirely different from
# document frequency across 46 clusters, and feeding the wrong table in is what
# made the threshold look like it needed tuning.
#
# KNOWN LIMIT, deliberately unfixed: the rule cannot distinguish "owns no
# distinctive vocabulary" from "produced no vocabulary". Both present as zero
# rare terms. In a single-language repo the ambiguity cannot arise. In a mixed
# repo, a cluster whose code is in a language with no grammar is flagged as
# undifferentiated when it should be left alone -- so treat a flag on such a
# cluster as "look at it", which is all a flag ever means here. Whatever
# eventually addresses mixed repos has to give this rule a parseable-fraction
# signal to tell the two cases apart.
#
# Exit codes:
#   0 - ran. Flagged clusters, if any, are on stdout; a flag is advice to
#       re-cluster or disperse, never a hard stop, so this is 0 either way.
#   1 - could not run (unreadable or empty vocabulary file)
#   2 - usage error
set -uo pipefail

# WHAT IS LEFT HERE. Dispatch. The rule moved into `synapse gate`, and with it
# the 60-line awk program that carried it -- see src/core/gate.zig, where the
# calibration above is pinned by tests rather than by this header alone. Nothing
# here resolves a namespace or reads the repo: the input is a table
# `synapse vocab` produced, so there is no preamble to keep.

usage() { # usage [exit-code]
    awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
    exit "${1:-2}"
}

case "${1:-}" in
    -h|--help) usage 0 ;;
esac

SYNAPSE_BIN_PATH="${SYNAPSE_BIN:-$HOME/.claude/bin/synapse}"
[ -x "$SYNAPSE_BIN_PATH" ] || {
    echo "synapse-gate: no synapse binary at $SYNAPSE_BIN_PATH (run setup.sh)" >&2; exit 1; }

exec "$SYNAPSE_BIN_PATH" gate "$@"
