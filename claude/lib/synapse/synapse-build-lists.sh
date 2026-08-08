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

reenumerate_flag=()
case "${1:-}" in
    "") ;;
    --reenumerate) reenumerate_flag=(--reenumerate) ;;
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
readonly ALL="$WORK_DIR/all.txt"
readonly MANIFEST="$WORK_DIR/manifest.tsv"
readonly LISTS="$WORK_DIR/lists"

[[ -f "$MANIFEST" ]] || { echo "synapse-build-lists: no manifest.tsv in $WORK_DIR" >&2; exit 1; }

# Enumeration has no real dependency on the manifest -- it is its own
# vault-free script now (claude/lib/synapse/synapse-enumerate.sh), called here
# as this build's first step with the same work dir this script already
# resolved, so the two never disagree about where $ALL lives.
SYNAPSE_WORK_DIR="$WORK_DIR" "${SYNAPSE_LIB_DIR:-$HOME/.claude/lib/synapse}/synapse-enumerate.sh" "${reenumerate_flag[@]}"

rm -rf "$LISTS"
mkdir -p "$LISTS"

node_index=0
while IFS=$'\t' read -r title include exclude; do
    [[ -n "$title" ]] || continue
    node_index=$((node_index + 1))
    slug="$(printf '%02d' "$node_index")"
    printf '%s\n' "$title" > "$LISTS/$slug.title"
    # An empty exclude column means "exclude nothing"; `^$` never matches a path.
    grep -E "$include" "$ALL" | grep -vE "${exclude:-^$}" > "$LISTS/$slug.txt" || true
    printf '%s\t%s\t%s\n' "$slug" "$(wc -l < "$LISTS/$slug.txt" | tr -d ' ')" "$title"
done < "$MANIFEST"

echo "--- coverage"
cat "$LISTS"/*.txt | LC_ALL=C sort -u > "$WORK_DIR/covered.txt"
LC_ALL=C sort "$ALL" > "$WORK_DIR/all-sorted.txt"
# LC_ALL=C on comm as well as on the sorts. comm verifies its inputs against the
# *ambient* collation, and under a UTF-8 locale it silently reports every line as
# unique once uppercase filenames are involved (README.md sorts before crates/ in C
# but not in en_US.UTF-8) -- which would make the coverage report claim nothing is
# covered, with no warning at all.
LC_ALL=C comm -23 "$WORK_DIR/all-sorted.txt" "$WORK_DIR/covered.txt" > "$WORK_DIR/unassigned.txt"
printf 'covered:    %s\nunassigned: %s\n' \
    "$(wc -l < "$WORK_DIR/covered.txt" | tr -d ' ')" \
    "$(wc -l < "$WORK_DIR/unassigned.txt" | tr -d ' ')"
