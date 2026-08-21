#!/usr/bin/env bats
# CLI-layer usage-error checks for commands whose actual logic is fully
# covered natively -- each of these used to be its own file, one bare
# `run()`-argv-parsing assertion apiece, nothing else. Consolidated here
# rather than kept as 8 near-identical single-test files: real per-command
# fixture setup that earned its own file stays split out (build-index,
# vocab, write-node, ...), this is only the bare exit-code residue.
#
# One @test per command, named with the command up front, so a failure
# still says which command broke without needing the filename.

load 'test_helper'

setup() {
  common_setup
}

teardown() {
  common_teardown
}

@test "brief: usage and environment errors" {
  run "$SYNAPSE_BIN" brief
  [ "$status" -eq 2 ]
  run "$SYNAPSE_BIN" brief --nope
  [ "$status" -eq 2 ]
}

@test "build-refs: --help is exit 0, a bad flag is exit 2" {
  run "$SYNAPSE_BIN" build-refs --help
  [ "$status" -eq 0 ]
  run "$SYNAPSE_BIN" build-refs --nonsense
  [ "$status" -eq 2 ]
}

@test "doctor: --help works outside a repo and with no environment at all" {
  # Asserted here as well as in the generator, because this is the command a
  # broken machine reaches for first.
  run env -i PATH="$PATH" "$SYNAPSE_BIN" doctor --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: synapse doctor"* ]]
}

@test "gate: usage errors exit 2" {
  local vocab="$TEST_HOME/groupwords.tsv"
  : > "$vocab"
  run "$SYNAPSE_BIN" gate
  [ "$status" -eq 2 ]
  run "$SYNAPSE_BIN" gate --vocab "$vocab" --top zero
  [ "$status" -eq 2 ]
  run "$SYNAPSE_BIN" gate --nope
  [ "$status" -eq 2 ]
}

@test "graph-clean: outside a git repo it exits 1, and an unknown flag exits 2" {
  run bash -c 'cd "$1" && exec "$2" "$3"' _ "$TEST_HOME" "$SYNAPSE_BIN" graph-clean
  [ "$status" -eq 1 ]

  make_repo
  run bash -c 'cd "$1" && shift && exec "$@"' _ "$REPO" "$SYNAPSE_BIN" graph-clean --bogus
  [ "$status" -eq 2 ]
}

@test "link-graph: usage and environment errors" {
  local refs="$TEST_HOME/_refs.tsv"
  local lists="$TEST_HOME/lists"
  mkdir -p "$lists"
  : > "$refs"
  run "$SYNAPSE_BIN" link-graph
  [ "$status" -eq 2 ]
  run "$SYNAPSE_BIN" link-graph --lists "$lists" --top bogus
  [ "$status" -eq 2 ]
  run "$SYNAPSE_BIN" link-graph --nope
  [ "$status" -eq 2 ]
}

@test "rank: usage errors" {
  local src="$TEST_HOME/sources.txt"
  : > "$src"
  local out="$TEST_HOME/out"
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" rank
  [ "$status" -eq 2 ]
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" rank --sources "$src" --tier bogus
  [ "$status" -eq 2 ]
  # --lists and --sources pick two different input modes; giving both is a
  # usage error, not a silent pick of one.
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" rank --sources "$src" --lists "$out/lists" --repo "$REPO" --out "$out"
  [ "$status" -eq 2 ]
  # --pool and --tier select one pool/tier for a single stream; --lists always
  # writes both pools per node, so combining them is a usage error too.
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" rank --lists "$out/lists" --repo "$REPO" --out "$out" --pool crux
  [ "$status" -eq 2 ]
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" rank --lists "$out/lists" --repo "$REPO" --out "$out" --tier code
  [ "$status" -eq 2 ]
}

@test "tags-cache: missing arguments is a usage error, exit 1" {
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" tags-cache --repo-root "$REPO"
  [ "$status" -eq 1 ]
}
