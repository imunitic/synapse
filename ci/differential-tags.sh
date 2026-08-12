#!/bin/bash
# Acceptance check for the tree-sitter port: the production tagger against the
# tree-sitter CLI, over real repositories, at scale.
#
# Not part of `just check` -- it needs real grammars, a real CLI to compare
# against, and repositories large enough for the comparison to mean anything.
# Run it when the extraction path changes.
#
#   ci/differential-tags.sh <grammar-repo-dir> <symbol> <file-list>
#
# Exits non-zero on any disagreement, and refuses to pass when either side is
# empty -- an empty-versus-empty comparison succeeds and looks exactly like
# agreement.
set -euo pipefail

cd "$(dirname "$0")/.."

repo="${1:?grammar repo dir}"
symbol="${2:?symbol, e.g. tree_sitter_java}"
list="${3:?file list}"

command -v tree-sitter >/dev/null || { echo "tree-sitter CLI needed to compare against" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/synapse-differential.XXXXXX")"
trap 'rm -rf "$work"' EXIT

zig build differential
{ echo "$repo"; echo "$work/grammar.so"; echo "$symbol"; cat "$list"; } > job.txt
trap 'rm -rf "$work" job.txt zig-tags.tsv' EXIT
./zig-out/bin/tags-differential
LC_ALL=C sort zig-tags.tsv > "$work/zig.tsv"

# The CLI's batch shape: an unindented path line, then that path's tab-indented
# tags. Normalised to the same columns the tool emits.
tree-sitter tags --paths "$list" 2>/dev/null | awk -F'\t' '
  /^[^\t]/ { path=$0; next }
  NF>=4 {
    name=$2; gsub(/^[ \t|]+|[ \t]+$/,"",name)
    k=$3;    gsub(/^[ \t|]+|[ \t]+$/,"",k)
    rest=$4; split(rest,a," "); role=a[1]
    p=index(rest,"("); if (p==0) next
    s=substr(rest,p+1); q=index(s,","); if (q==0) next
    row=substr(s,1,q-1); gsub(/[ \t]/,"",row)
    if ((role=="def"||role=="ref") && name!="") print path "\t" name "\t" role "\t" k "\t" row
  }' | LC_ALL=C sort > "$work/cli.tsv"

zc=$(wc -l < "$work/zig.tsv")
cc=$(wc -l < "$work/cli.tsv")
printf 'files:%s  cli rows:%s  zig rows:%s  ' "$(wc -l < "$list" | tr -d ' ')" "$cc" "$zc"

if [ "$zc" -eq 0 ] || [ "$cc" -eq 0 ]; then
    echo "REFUSED: one side is empty, the comparison would be vacuous"
    exit 1
fi

if cmp -s "$work/cli.tsv" "$work/zig.tsv"; then
    echo "IDENTICAL"
else
    echo "DIFFER"
    diff "$work/cli.tsv" "$work/zig.tsv" | head -20
    exit 1
fi
