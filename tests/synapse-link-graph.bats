#!/usr/bin/env bats
# Tests `synapse link-graph`'s CLI argument handling. The rule itself
# (edge weighting, rarity filtering, --top capping, file I/O, error
# messages) moved to native coverage -- `src/apps/synapse/links_cmd.zig`'s
# own `test` blocks, via the `write()` entry point `run()` delegates to.
# `write()` needs no vault or git either, so those tests use a plain temp
# dir, not a fixture. What's left here is what native coverage can't
# reach without a real subprocess: argument parsing exit codes.

load 'test_helper'

setup() {
  common_setup
  REFS="$TEST_HOME/_refs.tsv"
  LISTS="$TEST_HOME/lists"
  mkdir -p "$LISTS"
  : > "$REFS"
}

teardown() {
  common_teardown
}

@test "usage and environment errors" {
  run "$SYNAPSE_BIN" link-graph
  [ "$status" -eq 2 ]
  run "$SYNAPSE_BIN" link-graph --lists "$LISTS" --top bogus
  [ "$status" -eq 2 ]
  run "$SYNAPSE_BIN" link-graph --nope
  [ "$status" -eq 2 ]
}
