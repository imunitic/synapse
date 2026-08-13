#!/usr/bin/env bats
# Tests `synapse brief` -- one self-contained data file per node, bundling
# rank's pools and link-graph's edges (sb-011, stage 3's precondition).
# Reshaping only: the ranking and linking algorithms are covered by their own
# suites, this file is arg parsing, file I/O, tolerance of missing inputs,
# and getting the per-node filtering right.

load 'test_helper'

setup() {
  common_setup
  git init -q "$REPO"
  : > "$REPO/.gitkeep"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=t@e -c user.name=t commit -q -m init
  LISTS="$TEST_HOME/lists"
  mkdir -p "$LISTS"
  RANK="$TEST_HOME/rank"
  mkdir -p "$RANK"
  LINKS="$TEST_HOME/links.tsv"
  : > "$LINKS"
  OUT="$TEST_HOME/out"
}

teardown() {
  common_teardown
}

write_list() { # write_list <NN> <title> <path>...
  local nn="$1" title="$2"; shift 2
  printf '%s\n' "$title" > "$LISTS/$nn.title"
  printf '%s\n' "$@" > "$LISTS/$nn.txt"
}

write_pool() { # write_pool <NN> <summary|crux> <tier> <score> <path>...
  local nn="$1" pool="$2" tier="$3" score="$4"; shift 4
  local f="$RANK/$nn.$pool.tsv"
  : > "$f"
  local p
  for p in "$@"; do printf '%s\t%s\t%s\n' "$tier" "$score" "$p" >> "$f"; done
}

link_row() { # link_row <from> <to> <weight> <symbols...>
  local from="$1" to="$2" weight="$3"; shift 3
  printf '%s\t%s\t%s\t%s\n' "$from" "$to" "$weight" "$*" >> "$LINKS"
}

run_brief() {
  "$SYNAPSE_BIN" brief --lists "$LISTS" --rank "$RANK" --links "$LINKS" --repo "$REPO" --out "$OUT" "$@"
}

@test "writes one brief per node, with title, source count, both pools and this node's own edges" {
  write_list 01 A a/One.java a/Two.java
  write_list 02 B b/Three.java
  write_pool 01 summary code 3.5 a/One.java
  write_pool 01 crux code 3.5 a/One.java
  write_pool 02 summary code 1.0 b/Three.java
  write_pool 02 crux code 1.0 b/Three.java
  link_row A B 2 Widget Gadget
  link_row B A 1 Helper

  run run_brief
  [ "$status" -eq 0 ]
  [ -f "$OUT/brief/01.md" ]
  [ -f "$OUT/brief/02.md" ]

  local a; a="$(cat "$OUT/brief/01.md")"
  [[ "$a" == "# A"* ]]
  [[ "$a" == *"(2 files, exhaustive"* ]]
  [[ "$a" == *"a/One.java"* ]]
  [[ "$a" == *"A	B	2	Widget Gadget"* ]]
  [[ "$a" != *$'\nB\tA\t1\tHelper'* ]]

  local b; b="$(cat "$OUT/brief/02.md")"
  [[ "$b" == "# B"* ]]
  [[ "$b" == *"B	A	1	Helper"* ]]
  [[ "$b" != *"Widget Gadget"* ]]
}

@test "every node's title is listed for judging part_of, not just the current one" {
  write_list 01 A a/One.java
  write_list 02 B b/Two.java
  write_list 03 C c/Three.java

  run run_brief
  [ "$status" -eq 0 ]
  local a; a="$(cat "$OUT/brief/01.md")"
  [[ "$a" == *"- A"* ]]
  [[ "$a" == *"- B"* ]]
  [[ "$a" == *"- C"* ]]
}

@test "a node with no candidate links gets (none), not an empty section" {
  write_list 01 A a/One.java
  write_list 02 B b/Two.java

  run run_brief
  [ "$status" -eq 0 ]
  [[ "$(cat "$OUT/brief/01.md")" == *"Candidate links"*$'\n'"(none)"* ]]
}

@test "missing rank output is advice, not fatal: empty pools, a warning, still succeeds" {
  write_list 01 A a/One.java

  run run_brief
  [ "$status" -eq 0 ]
  [[ "$output" == *"1/1 nodes had no rank output"* ]]
  [[ "$(cat "$OUT/brief/01.md")" == *"Summary pool"*$'\n'"(none)"* ]]
}

@test "missing links.tsv is advice, not fatal: every node's links are (none), one warning" {
  write_list 01 A a/One.java
  write_list 02 B b/Two.java
  rm "$LINKS"

  run "$SYNAPSE_BIN" brief --lists "$LISTS" --rank "$RANK" --links "$TEST_HOME/nope.tsv" --repo "$REPO" --out "$OUT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no link graph at"* ]]
  [[ "$(cat "$OUT/brief/01.md")" == *"(none)"* ]]
}

@test "a missing --lists dir is an error, not a silent empty result" {
  run "$SYNAPSE_BIN" brief --lists "$TEST_HOME/nope" --rank "$RANK" --links "$LINKS" --repo "$REPO" --out "$OUT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no such lists dir"* ]]
}

@test "an empty --lists dir is an error, pointing at what to run" {
  mkdir -p "$TEST_HOME/empty-lists"
  run "$SYNAPSE_BIN" brief --lists "$TEST_HOME/empty-lists" --rank "$RANK" --links "$LINKS" --repo "$REPO" --out "$OUT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NN.txt/NN.title"* ]]
}

@test "defaults to \$SYNAPSE_WORK_DIR for --rank/--links/--out when omitted" {
  write_list 01 A a/One.java
  local work="$TEST_HOME/work"
  mkdir -p "$work/rank"
  cp "$RANK/01.summary.tsv" "$work/rank/01.summary.tsv" 2>/dev/null || true
  cp "$LINKS" "$work/links.tsv"

  run env SYNAPSE_WORK_DIR="$work" "$SYNAPSE_BIN" brief --lists "$LISTS" --repo "$REPO"
  [ "$status" -eq 0 ]
  [ -f "$work/brief/01.md" ]
}

@test "usage and environment errors" {
  run "$SYNAPSE_BIN" brief
  [ "$status" -eq 2 ]
  run "$SYNAPSE_BIN" brief --nope
  [ "$status" -eq 2 ]
}
