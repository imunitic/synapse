#!/usr/bin/env bats
# Tests `synapse link-graph` -- the node-to-node link graph computed before
# any prose is written (synapse-001, step 9). The algorithm itself is
# core/links.zig's own exhaustive unit-test suite; this file is the CLI
# wrapper's concerns: arg parsing, file I/O, error messages, output on disk.

load 'test_helper'

setup() {
  common_setup
  REFS="$TEST_HOME/_refs.tsv"
  LISTS="$TEST_HOME/lists"
  mkdir -p "$LISTS"
  OUT="$TEST_HOME/out"
  : > "$REFS"
}

teardown() {
  common_teardown
}

# One _refs.tsv row.
refline() { # refline <name> <def|ref> <kind> <path> <line> <expr>
  printf '%s\t%s\t%s\t%s:%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >> "$REFS"
}

# A synapse-build-lists.sh-shaped lists/ dir entry: NN.txt paths, NN.title name.
write_list() { # write_list <NN> <title> <path>...
  local nn="$1" title="$2"; shift 2
  printf '%s\n' "$title" > "$LISTS/$nn.title"
  printf '%s\n' "$@" > "$LISTS/$nn.txt"
}

run_links() {
  "$SYNAPSE_BIN" link-graph --refs "$REFS" --lists "$LISTS" --out "$OUT" "$@"
}

edges() { # edges <output>
  grep -E $'^[^\t]+\t[^\t]+\t[0-9]+\t' <<< "$1" || true
}

@test "a ref in one node to a def in another is an edge, weighted and evidenced" {
  write_list 01 A a/Widget.java
  write_list 02 B b/Gadget.java
  refline Helper def class b/Gadget.java 1 'class Helper {'
  refline Helper ref call a/Widget.java 5 'Helper.run();'

  run run_links
  [ "$status" -eq 0 ]
  [ "$(cat "$OUT/links.tsv")" = "$(printf 'A\tB\t1\tHelper')" ]
}

@test "a ref and its def in the same node produce no edge" {
  write_list 01 A a/One.java a/Two.java
  refline Local def class a/One.java 1 'class Local {'
  refline Local ref call a/Two.java 2 'Local.run();'

  run run_links
  [ "$status" -eq 0 ]
  [ ! -s "$OUT/links.tsv" ]
}

@test "a symbol referenced from too many nodes is filtered out, not just down-weighted" {
  # rare_max = max(2, 4/20) = 2. Three referencing nodes exceeds it.
  write_list 01 D d/Def.java
  write_list 02 A a/A.java
  write_list 03 B b/B.java
  write_list 04 C c/C.java
  refline Common def class d/Def.java 1 'class Common {'
  refline Common ref call a/A.java 1 'Common.run();'
  refline Common ref call b/B.java 1 'Common.run();'
  refline Common ref call c/C.java 1 'Common.run();'

  run run_links
  [ "$status" -eq 0 ]
  [ ! -s "$OUT/links.tsv" ]
}

@test "weight is distinct rare symbols, so two calls to the same one still weigh one" {
  write_list 01 B b/B.java
  write_list 02 A a/A.java
  refline Widget def class b/B.java 1 'class Widget {'
  refline Widget ref call a/A.java 3 'Widget.run();'
  refline Widget ref call a/A.java 9 'Widget.run();'

  run run_links
  [ "$status" -eq 0 ]
  [ "$(awk -F'\t' '{print $3}' "$OUT/links.tsv")" = "1" ]
}

@test "--top caps edges kept per node, strongest first" {
  write_list 01 A a/A.java
  write_list 02 B b/B.java
  write_list 03 C c/C.java
  write_list 04 D d/D.java
  refline X def class b/B.java 1 'class X {'
  refline X ref call a/A.java 1 'X.run();'
  refline Y def class c/C.java 1 'class Y {'
  refline Y ref call a/A.java 2 'Y.run();'
  refline Z def class d/D.java 1 'class Z {'
  refline Z ref call a/A.java 3 'Z.run();'

  run run_links --top 2
  [ "$status" -eq 0 ]
  [ "$(edges "$(cat "$OUT/links.tsv")" | wc -l | tr -d ' ')" -eq 2 ]

  run run_links --top 0
  [ "$status" -eq 0 ]
  [ "$(edges "$(cat "$OUT/links.tsv")" | wc -l | tr -d ' ')" -eq 3 ]
}

@test "a path claimed by two nodes fans out an edge from each" {
  write_list 01 B b/B.java
  write_list 02 A a/A.java
  write_list 03 C a/A.java
  refline Alpha def class b/B.java 1 'class Alpha {'
  refline Alpha ref call a/A.java 1 'Alpha.run();'

  run run_links
  [ "$status" -eq 0 ]
  [ "$(awk -F'\t' '$1 == "A"' "$OUT/links.tsv" | wc -l | tr -d ' ')" -eq 1 ]
  [ "$(awk -F'\t' '$1 == "C"' "$OUT/links.tsv" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "a missing --lists dir is an error, not a silent empty result" {
  run "$SYNAPSE_BIN" link-graph --refs "$REFS" --lists "$TEST_HOME/nope" --out "$OUT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"no such lists dir"* ]]
}

@test "an empty --lists dir is an error, pointing at what to run" {
  run "$SYNAPSE_BIN" link-graph --refs "$REFS" --lists "$TEST_HOME/empty-lists" --out "$OUT"
  mkdir -p "$TEST_HOME/empty-lists"
  run "$SYNAPSE_BIN" link-graph --refs "$REFS" --lists "$TEST_HOME/empty-lists" --out "$OUT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NN.txt/NN.title"* ]]
}

@test "a missing _refs.tsv points at build-refs rather than failing opaquely" {
  write_list 01 A a/A.java
  run "$SYNAPSE_BIN" link-graph --refs "$TEST_HOME/nope.tsv" --lists "$LISTS" --out "$OUT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"build-refs"* ]]
}

@test "an empty refs table and a real lists dir produce an empty, present links.tsv" {
  write_list 01 A a/A.java
  write_list 02 B b/B.java

  run run_links
  [ "$status" -eq 0 ]
  [ -f "$OUT/links.tsv" ]
  [ ! -s "$OUT/links.tsv" ]
}

@test "defaults to \$SYNAPSE_WORK_DIR when --refs/--out are omitted" {
  write_list 01 A a/A.java
  write_list 02 B b/B.java
  local work="$TEST_HOME/work"
  mkdir -p "$work"
  cp "$REFS" "$work/_refs.tsv"

  run env SYNAPSE_WORK_DIR="$work" "$SYNAPSE_BIN" link-graph --lists "$LISTS"
  [ "$status" -eq 0 ]
  [ -f "$work/links.tsv" ]
}

@test "usage and environment errors" {
  run "$SYNAPSE_BIN" link-graph
  [ "$status" -eq 2 ]
  run "$SYNAPSE_BIN" link-graph --lists "$LISTS" --top bogus
  [ "$status" -eq 2 ]
  run "$SYNAPSE_BIN" link-graph --nope
  [ "$status" -eq 2 ]
}
