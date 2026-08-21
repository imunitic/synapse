#!/usr/bin/env bats
# Tests `synapse gate`'s CLI argument handling. The rule itself (rarity
# arithmetic, --top/--parseable semantics, tie-breaking) moved to native
# coverage -- `src/apps/synapse/gate_cmd.zig`'s own `test` blocks, via the
# `write()` entry point `run()` delegates to, using the same fake fixture
# vocab tables this file used to write directly. What's left here is the
# one thing native coverage can't reach without a real subprocess: argument
# parsing exit codes off the actual compiled binary.

load 'test_helper'

setup() {
  common_setup
  VOCAB="$TEST_HOME/groupwords.tsv"
  : > "$VOCAB"
}

teardown() {
  common_teardown
}

@test "usage errors exit 2" {
  run "$SYNAPSE_BIN" gate
  [ "$status" -eq 2 ]
  run "$SYNAPSE_BIN" gate --vocab "$VOCAB" --top zero
  [ "$status" -eq 2 ]
  run "$SYNAPSE_BIN" gate --nope
  [ "$status" -eq 2 ]
}
