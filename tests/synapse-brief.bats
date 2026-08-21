#!/usr/bin/env bats
# Tests `synapse brief` -- one self-contained data file per node, bundling
# rank's pools and link-graph's edges (sb-011, stage 3's precondition).
# Everything but arg-parsing usage errors is covered natively in
# brief_cmd.zig; this file just confirms the CLI-layer contract.

load 'test_helper'

setup() {
  common_setup
}

teardown() {
  common_teardown
}

@test "usage and environment errors" {
  run "$SYNAPSE_BIN" brief
  [ "$status" -eq 2 ]
  run "$SYNAPSE_BIN" brief --nope
  [ "$status" -eq 2 ]
}
