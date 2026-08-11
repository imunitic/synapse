#!/usr/bin/env bats
# Tests `synapse tags-cache` -- the mechanical helper that keeps a per-project
# tags cache current for a set of path:hash pairs, re-tagging only what changed
# and never touching a file that is already current. It replaced
# claude/lib/synapse/synapse-tags-cache.sh, which is deleted.
#
# The binary under test is `synapse-fake`, the same app with only the grammar
# compile-and-load step stubbed -- $SYNAPSE_BIN, set by common_setup. So the
# diff, the attribution and the storage are all real code here; only the
# tagging is scripted.
#
# The cache is a binary file now, so assertions read it through
# `tags-cache --dump`, which is the same door synapse-query.sh uses.

load 'test_helper'


setup() {
  common_setup
  GRAMMARS_DIR="$TEST_HOME/grammars"
  FAKE_TS_LOG="$TEST_HOME/ts.log"
  FAKE_GIT_LOG="$TEST_HOME/git.log"
  : > "$FAKE_TS_LOG"
  : > "$FAKE_GIT_LOG"
  printf '{"ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}' \
    > "$HOME/.claude/synapse-grammars.conf"
}

teardown() {
  common_teardown
}

run_cache() {
  PATH="$FAKE_BIN:$PATH" \
    SYNAPSE_GRAMMARS_DIR="$GRAMMARS_DIR" \
    FAKE_TS_LOG="$FAKE_TS_LOG" \
    FAKE_GIT_LOG="$FAKE_GIT_LOG" \
    "$SYNAPSE_BIN" tags-cache "$@"
}

# The cache is binary now, so the tests read it the way every other consumer
# does -- `--dump`, one marker-prefixed line per fact. Asserting through the
# same door the scripts use is the point: a projection that broke would fail
# here rather than only in whatever reads it next.
#
#   H <TAB> path <TAB> hash   |   U <TAB> path   |   P <TAB> path   |   T <TAB> path <TAB> tag
dump() { "$SYNAPSE_BIN" tags-cache --dump "$1"; }

entry_count() { dump "$1" | grep -c '^H	' || true; }
hash_of() { dump "$1" | awk -F'\t' -v p="$2" '$1 == "H" && $2 == p { print $3 }'; }
is_unsupported() { dump "$1" | grep -qx "U	$2"; }
is_parsed() { dump "$1" | grep -qx "P	$2"; }
tags_of() { dump "$1" | awk -F'\t' -v p="$2" '$1 == "T" && $2 == p { print substr($0, length($1) + length($2) + 3) }'; }

# Writes N real .ml files under $REPO and a path:hash TSV for them (using
# real `git hash-object`, since the fake git only intercepts `clone`).
write_sample_files() { # write_sample_files <count>
  mkdir -p "$REPO"
  : > "$TEST_HOME/paths.tsv"
  local i
  for i in $(seq 1 "$1"); do
    printf 'let x_%d = %d\n' "$i" "$i" > "$REPO/sample_$i.ml"
    h="$(git -C "$REPO" hash-object "sample_$i.ml")"
    printf 'sample_%d.ml\t%s\n' "$i" "$h" >> "$TEST_HOME/paths.tsv"
  done
}

@test "cold cache: tags every requested file, records hash and tags" {
  make_repo
  write_sample_files 3

  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.bin" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]

  [ "$(entry_count "$TEST_HOME/_tags_cache.bin")" -eq 3 ]
  [[ "$(tags_of "$TEST_HOME/_tags_cache.bin" sample_1.ml)" == *"FAKE_NAME"* ]]
  is_parsed "$TEST_HOME/_tags_cache.bin" sample_1.ml
  # Every requested file was tagged in ONE extraction, not three. Grammar load
  # is nearly all of the per-file cost, so a per-file loop here would undo the
  # batching the Extractor port is shaped around.
  [ "$(grep -c '^path ' "$FAKE_TS_LOG")" -eq 3 ]
  [ "$(grep -c '^tags ' "$FAKE_TS_LOG")" -eq 1 ]
}

@test "unchanged hashes: no re-tagging on a second run" {
  make_repo
  write_sample_files 3
  run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.bin" --paths "$TEST_HOME/paths.tsv"
  : > "$FAKE_TS_LOG"

  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.bin" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_TS_LOG" ]
}

@test "one file's hash changes: only that file is re-tagged, others untouched" {
  make_repo
  write_sample_files 3
  run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.bin" --paths "$TEST_HOME/paths.tsv"
  before_2="$(dump "$TEST_HOME/_tags_cache.bin" | grep '	sample_2.ml')"
  before_3="$(dump "$TEST_HOME/_tags_cache.bin" | grep '	sample_3.ml')"

  printf 'let x_1 = 999 (* changed *)\n' > "$REPO/sample_1.ml"
  new_hash="$(git -C "$REPO" hash-object "$REPO/sample_1.ml")"
  sed -i.bak "s#^sample_1.ml\t.*#sample_1.ml\t$new_hash#" "$TEST_HOME/paths.tsv"
  : > "$FAKE_TS_LOG"

  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.bin" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]
  # Which file was tagged, not how many invocations happened: once tagging is
  # batched, an invocation count no longer distinguishes "re-tagged one file"
  # from "re-tagged all three in one call".
  [ "$(grep -c '^path ' "$FAKE_TS_LOG")" -eq 1 ]
  grep -qx 'path sample_1.ml' "$FAKE_TS_LOG"
  [ "$(hash_of "$TEST_HOME/_tags_cache.bin" sample_1.ml)" = "$new_hash" ]
  [ "$(dump "$TEST_HOME/_tags_cache.bin" | grep '	sample_2.ml')" = "$before_2" ]
  [ "$(dump "$TEST_HOME/_tags_cache.bin" | grep '	sample_3.ml')" = "$before_3" ]
}

@test "unsupported file: recorded as unsupported, never retried while unchanged" {
  make_repo
  mkdir -p "$REPO"
  printf 'no grammar for this\n' > "$REPO/sample.unknownext"
  h="$(git -C "$REPO" hash-object "$REPO/sample.unknownext")"
  printf 'sample.unknownext\t%s\n' "$h" > "$TEST_HOME/paths.tsv"
  # No registry entry for "unknownext", which the extractor reports as
  # `.unsupported` -- the same outcome as a grammar that cannot be built.

  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.bin" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]
  is_unsupported "$TEST_HOME/_tags_cache.bin" sample.unknownext
  [ -z "$(tags_of "$TEST_HOME/_tags_cache.bin" sample.unknownext)" ]

  : > "$FAKE_TS_LOG"
  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.bin" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_TS_LOG" ]
}

@test "a file that parsed to no tags is NOT recorded as unsupported" {
  # The distinction the batched form rests on, and the one it could most easily
  # lose: an unparseable file is absent from the batch output entirely, while a
  # file that parsed and simply had nothing in it still gets its path line.
  # Conflating them would make `synapse-query.sh symbol` report a perfectly
  # readable file as "not checked", and re-tag it on every single call.
  make_repo
  mkdir -p "$REPO"
  printf 'notags\n' > "$REPO/empty.ml"
  printf 'let x = 1\n' > "$REPO/full.ml"
  printf 'no grammar for this\n' > "$REPO/other.unknownext"
  for f in empty.ml full.ml other.unknownext; do
    printf '%s\t%s\n' "$f" "$(git -C "$REPO" hash-object "$f")" >> "$TEST_HOME/paths.tsv"
  done

  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.bin" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]

  is_parsed "$TEST_HOME/_tags_cache.bin" empty.ml
  [ -z "$(tags_of "$TEST_HOME/_tags_cache.bin" empty.ml)" ]
  [[ "$(tags_of "$TEST_HOME/_tags_cache.bin" full.ml)" == *"FAKE_NAME"* ]]
  is_unsupported "$TEST_HOME/_tags_cache.bin" other.unknownext

  # And all three are current: none is re-attempted.
  : > "$FAKE_TS_LOG"
  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.bin" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_TS_LOG" ]
}

@test "tags are attributed to the right file within one batch" {
  # Batch output is one flat stream for many files, so misattribution is the
  # new failure mode: every path's tags must be its own, not the previous
  # path's or the whole batch's.
  make_repo
  mkdir -p "$REPO"
  printf 'symbol:AlphaOnly\n' > "$REPO/a.ml"
  printf 'symbol:BetaOnly\n'  > "$REPO/b.ml"
  printf 'notags\n'           > "$REPO/c.ml"
  for f in a.ml b.ml c.ml; do
    printf '%s\t%s\n' "$f" "$(git -C "$REPO" hash-object "$f")" >> "$TEST_HOME/paths.tsv"
  done

  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.bin" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^tags ' "$FAKE_TS_LOG")" -eq 1 ]

  [[ "$(tags_of "$TEST_HOME/_tags_cache.bin" a.ml)" == *"AlphaOnly"* ]]
  [[ "$(tags_of "$TEST_HOME/_tags_cache.bin" a.ml)" != *"BetaOnly"* ]]
  [[ "$(tags_of "$TEST_HOME/_tags_cache.bin" b.ml)" == *"BetaOnly"* ]]
  [[ "$(tags_of "$TEST_HOME/_tags_cache.bin" b.ml)" != *"AlphaOnly"* ]]
  [ -z "$(tags_of "$TEST_HOME/_tags_cache.bin" c.ml)" ]
  # No trailing newline, matching what the per-file form recorded.
  [ "$(tags_of "$TEST_HOME/_tags_cache.bin" a.ml | wc -l | tr -d ' ')" -eq 2 ]
}

@test "cached tag lines carry no batch indent, so field 1 is still the symbol" {
  # Batch output indents every tag line under its path; single-file output does
  # not. Consumers split on \t and read field 1 as the symbol name, so leaving
  # the indent makes field 1 empty on every line and `synapse-query.sh symbol`
  # matches nothing -- reporting a clean not-found for a file it did read.
  # Asserted here rather than only through that downstream symptom, because the
  # symptom looks like a query bug and this is where it would originate.
  make_repo
  mkdir -p "$REPO"
  printf 'symbol:AlphaOnly\n' > "$REPO/a.ml"
  printf 'a.ml\t%s\n' "$(git -C "$REPO" hash-object a.ml)" > "$TEST_HOME/paths.tsv"

  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.bin" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]

  run dump "$TEST_HOME/_tags_cache.bin"
  # No tag line carries the batch indent: consumers split on tab and read
  # field 1 as the symbol, so a leading tab would empty it. In the dump the
  # tag is everything after `T<TAB>path<TAB>`, so an indent shows as a tab
  # immediately after the second one.
  [ "$(grep -c '^T	[^	]*		' <<< "$output")" -eq 0 ]
  # And field 1 of the tag itself is the symbol. Trailing spaces are stripped
  # before comparing: tree-sitter space-pads the name column to ten characters,
  # so it is `AlphaOnly ` and never the bare name -- which is the point of the
  # trim in `model.Tag`'s own contract, and why asserting exact equality on the
  # raw field would be asserting the opposite.
  [ "$(tags_of "$TEST_HOME/_tags_cache.bin" a.ml \
       | awk -F'\t' '{ sub(/[ \t]+$/, "", $1) } $1 == "AlphaOnly"' \
       | wc -l | tr -d ' ')" -eq 1 ]
}

@test "a single file needing tagging is cached with its tags, not as unsupported" {
  # The regression this batching shipped with. One changed file is the COMMON
  # case, and the real CLI drops path lines and indentation for a one-path list
  # -- so attribution saw the path as absent from the output and recorded a
  # perfectly readable file as `unsupported: true` with empty tags. Reported by
  # `synapse-query.sh symbol` as "not checked", and re-tagged on every call
  # forever, since an unsupported entry that never gains tags never settles.
  make_repo
  write_sample_files 3
  run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.bin" --paths "$TEST_HOME/paths.tsv"

  printf 'let x_1 = 999 (* changed *)\n' > "$REPO/sample_1.ml"
  new_hash="$(git -C "$REPO" hash-object "$REPO/sample_1.ml")"
  sed_i "s#^sample_1.ml	.*#sample_1.ml	$new_hash#" "$TEST_HOME/paths.tsv"

  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.bin" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]
  is_parsed "$TEST_HOME/_tags_cache.bin" sample_1.ml
  [[ "$(tags_of "$TEST_HOME/_tags_cache.bin" sample_1.ml)" == *"FAKE_NAME"* ]]

  # And it has genuinely settled: a third run re-tags nothing.
  : > "$FAKE_TS_LOG"
  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.bin" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_TS_LOG" ]
}

@test "several files needing tagging at once: every one ends up correctly cached" {
  make_repo
  write_sample_files 6

  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.bin" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]
  [ "$(entry_count "$TEST_HOME/_tags_cache.bin")" -eq 6 ]
  for i in 1 2 3 4 5 6; do
    [[ "$(tags_of "$TEST_HOME/_tags_cache.bin" "sample_$i.ml")" == *"FAKE_NAME"* ]]
  done
}

@test "path containing a space: cached correctly, no stray result file" {
  # Regression: the parallel step used `xargs -L 1` with three positional
  # args, and xargs word-splits on spaces as well as tabs -- so this path
  # shifted every field, tagged the wrong file, and wrote its result outside
  # $WORK/results (where the merge never saw it). The entry silently never
  # entered the cache and was re-attempted on every subsequent call.
  make_repo
  mkdir -p "$REPO/src/some dir"
  printf 'let spaced = 1\n' > "$REPO/src/some dir/spaced.ml"
  printf 'let plain = 2\n' > "$REPO/plain.ml"
  h_spaced="$(git -C "$REPO" hash-object "src/some dir/spaced.ml")"
  h_plain="$(git -C "$REPO" hash-object "plain.ml")"
  printf 'src/some dir/spaced.ml\t%s\nplain.ml\t%s\n' "$h_spaced" "$h_plain" > "$TEST_HOME/paths.tsv"

  cd "$TEST_HOME"
  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.bin" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]

  [ "$(entry_count "$TEST_HOME/_tags_cache.bin")" -eq 2 ]
  [[ "$(tags_of "$TEST_HOME/_tags_cache.bin" "src/some dir/spaced.ml")" == *"FAKE_NAME"* ]]
  [ "$(hash_of "$TEST_HOME/_tags_cache.bin" "src/some dir/spaced.ml")" = "$h_spaced" ]
  is_parsed "$TEST_HOME/_tags_cache.bin" "src/some dir/spaced.ml"
  # The stray-file symptom: a result written to a name derived from a shifted
  # field lands in the caller's cwd instead of the work dir.
  [ ! -e "$TEST_HOME/$h_spaced" ]

  # And it is genuinely current -- not re-tagged on the next run.
  : > "$FAKE_TS_LOG"
  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.bin" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_TS_LOG" ]
}

@test "missing arguments: usage error, exit 1" {
  run run_cache --repo-root "$REPO"
  [ "$status" -eq 1 ]
}

@test "nonexistent paths file: exit 1" {
  make_repo
  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.bin" --paths "$TEST_HOME/does-not-exist.tsv"
  [ "$status" -eq 1 ]
}

@test "empty paths file: nothing to do, exit 0, cache created but empty" {
  make_repo
  : > "$TEST_HOME/paths.tsv"
  run run_cache --repo-root "$REPO" --cache "$TEST_HOME/_tags_cache.bin" --paths "$TEST_HOME/paths.tsv"
  [ "$status" -eq 0 ]
}
