#!/usr/bin/env bats
# Tests claude/lib/synapse/synapse-build-refs.sh -- the projection from a project's tags
# cache to the flat, sorted reference index that `synapse-query.sh callers`
# reads.
#
# The cache fixtures here are hand-written rather than produced by running
# tree-sitter, and deliberately so: this script's whole job is parsing the tag
# line, so the tests need to state exactly what that line looks like (including
# the space-padded name column, which is the failure mode that silently returns
# nothing) rather than inheriting it from a stub that could drift.

load 'test_helper'


setup() {
  common_setup
  CACHE="$TEST_HOME/_tags_cache.bin"
  OUT="$TEST_HOME/_refs.tsv"
}

teardown() {
  common_teardown
}

# One tab-separated tag line exactly as tree-sitter emits it, name column padded.
tagline() { # tagline <padded-name> <kind> <def|ref> <row> <expression>
  printf '%s\t | %s\t%s (%s, 13) - (%s, 39) `%s`' "$1" "$2" "$3" "$4" "$4" "$5"
}

# Builds a cache from `--dump`'s own format, which is the inverse operation and
# how a test authors one now that the file is binary. Same expressive power the
# hand-written JSON had: an arbitrary tag line per path, verbatim.
write_cache() { # write_cache <dump-format lines on stdin>
  "$SYNAPSE_BIN" tags-cache --load "$CACHE"
}

# One entry: a path, a hash, and its tag lines (newline separated, may be empty).
cache_entry() { # cache_entry <path> <hash40> <tags>
  printf 'H\t%s\t%s\n' "$1" "$2"
  printf 'P\t%s\n' "$1"
  [ -z "$3" ] || printf '%s\n' "$3" | while IFS= read -r l; do printf 'T\t%s\t%s\n' "$1" "$l"; done
}

cache_unsupported() { # cache_unsupported <path> <hash40>
  printf 'H\t%s\t%s\n' "$1" "$2"
  printf 'U\t%s\n' "$1"
}

H1="1111111111111111111111111111111111111111"
H2="2222222222222222222222222222222222222222"

@test "build-refs: emits name/reftype/kind/path:line/expression, tab separated" {
  local tags
  tags="$(tagline 'Token     ' 'class  ' 'def' 15 'public class Token {')"
  cache_entry "src/Token.java" "$H1" "$tags" | write_cache

  run "$SYNAPSE_BIN" build-refs --cache "$CACHE" --out "$OUT"
  [ "$status" -eq 0 ]

  run cat "$OUT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  # Name trimmed of its padding; row taken from the first coordinate.
  [ "$(printf '%s' "${lines[0]}" | cut -f1)" = "Token" ]
  [ "$(printf '%s' "${lines[0]}" | cut -f2)" = "def" ]
  [ "$(printf '%s' "${lines[0]}" | cut -f3)" = "class" ]
  [ "$(printf '%s' "${lines[0]}" | cut -f4)" = "src/Token.java:15" ]
  [ "$(printf '%s' "${lines[0]}" | cut -f5)" = "public class Token {" ]
}

# The padding is the reason this script exists in the form it does: an untrimmed
# index looks correct and silently answers nothing for every short name.
@test "build-refs: a short padded name is trimmed, so exact lookup finds it" {
  local tags
  tags="$(tagline 'execute   ' 'call   ' 'ref' 42 'foo.execute();')"
  cache_entry "src/A.java" "$H1" "$tags" | write_cache

  run "$SYNAPSE_BIN" build-refs --cache "$CACHE" --out "$OUT"
  [ "$status" -eq 0 ]

  run awk -F'\t' '$1=="execute"' "$OUT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
}

@test "build-refs: unsupported files contribute nothing and are counted separately" {
  local tags
  tags="$(tagline 'Kept      ' 'class  ' 'def' 1 'class Kept {}')"
  { cache_entry "src/Kept.java" "$H1" "$tags"
    cache_unsupported "src/data.sql" "$H2"
  } | write_cache

  run "$SYNAPSE_BIN" build-refs --cache "$CACHE" --out "$OUT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 unsupported"* ]]

  run grep -c 'data.sql' "$OUT"
  [ "$status" -ne 0 ] # no rows for the unsupported file
}

@test "build-refs: multiple tag lines in one file all become rows" {
  local a b
  a="$(tagline 'A         ' 'class  ' 'def' 1 'class A {}')"
  b="$(tagline 'run       ' 'call   ' 'ref' 7 'a.run();')"
  cache_entry "src/A.java" "$H1" "$a
$b" | write_cache

  run "$SYNAPSE_BIN" build-refs --cache "$CACHE" --out "$OUT"
  [ "$status" -eq 0 ]
  run wc -l < "$OUT"
  [ "$(printf '%s' "$output" | tr -d ' ')" = "2" ]
}

# The ordering is a contract with `synapse-query.sh callers`, which binary-searches
# this file with `look`. Asserted here rather than left to review, because a
# disagreement returns no rows and reads exactly like "never called".
@test "build-refs: output is LC_ALL=C sorted" {
  local a b c
  a="$(tagline 'Zebra     ' 'class  ' 'def' 1 'class Zebra {}')"
  b="$(tagline 'apple     ' 'call   ' 'ref' 2 'apple();')"
  c="$(tagline 'Apple     ' 'class  ' 'def' 3 'class Apple {}')"
  cache_entry "src/A.java" "$H1" "$a
$b
$c" | write_cache

  run "$SYNAPSE_BIN" build-refs --cache "$CACHE" --out "$OUT"
  [ "$status" -eq 0 ]

  run bash -c "LC_ALL=C sort -c '$OUT' && echo sorted"
  [ "$status" -eq 0 ]
  [ "$output" = "sorted" ]
}

@test "build-refs: a tab inside the expression cannot add a column" {
  local tags
  tags="$(printf 'weird     \t | call   \tref (5, 13) - (5, 39) `a\tb();`')"
  cache_entry "src/A.java" "$H1" "$tags" | write_cache

  run "$SYNAPSE_BIN" build-refs --cache "$CACHE" --out "$OUT"
  [ "$status" -eq 0 ]

  run awk -F'\t' 'NF != 5 { print "bad:" NF }' "$OUT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "build-refs: a malformed tag line is skipped, not emitted half-parsed" {
  cache_entry "src/A.java" "$H1" "no tabs here at all" | write_cache

  run "$SYNAPSE_BIN" build-refs --cache "$CACHE" --out "$OUT"
  [ "$status" -eq 0 ]
  run wc -l < "$OUT"
  [ "$(printf '%s' "$output" | tr -d ' ')" = "0" ]
}

@test "build-refs: missing cache is exit 1 with a pointer to the fix" {
  run "$SYNAPSE_BIN" build-refs --cache "$TEST_HOME/nope.json" --out "$OUT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"synapse tags-cache"* ]]
}

@test "build-refs: unreadable cache is exit 1, not a silently empty index" {
  printf 'this is not json' > "$CACHE"
  run "$SYNAPSE_BIN" build-refs --cache "$CACHE" --out "$OUT"
  [ "$status" -eq 1 ]
}

@test "build-refs: rebuilds rather than appending" {
  local tags
  tags="$(tagline 'Once      ' 'class  ' 'def' 1 'class Once {}')"
  cache_entry "src/A.java" "$H1" "$tags" | write_cache

  "$SYNAPSE_BIN" build-refs --cache "$CACHE" --out "$OUT"
  "$SYNAPSE_BIN" build-refs --cache "$CACHE" --out "$OUT"

  run wc -l < "$OUT"
  [ "$(printf '%s' "$output" | tr -d ' ')" = "1" ]
}

@test "build-refs: --help is exit 0, a bad flag is exit 2" {
  run "$SYNAPSE_BIN" build-refs --help
  [ "$status" -eq 0 ]
  run "$SYNAPSE_BIN" build-refs --nonsense
  [ "$status" -eq 2 ]
}
