#!/usr/bin/env bats
# Tests claude/lib/synapse/synapse-rank.sh -- the tiered ranking that decides what is
# worth READING when authoring a node's prose. The ranking algorithm itself
# (code/dsl tiers, the two pools, --lists) is covered by rank_cmd.zig's own
# native tests; this file keeps only the CLI-layer usage-error checks that
# `run()` itself rejects before any ranking work begins.

load 'test_helper'

setup() {
  common_setup
  SRC="$TEST_HOME/sources.txt"
  : > "$SRC"
  OUT="$TEST_HOME/out"
}

teardown() {
  common_teardown
}

@test "usage errors" {
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" rank
  [ "$status" -eq 2 ]
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" rank --sources "$SRC" --tier bogus
  [ "$status" -eq 2 ]
  # --lists and --sources pick two different input modes; giving both is a
  # usage error, not a silent pick of one.
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" rank --sources "$SRC" --lists "$OUT/lists" --repo "$REPO" --out "$OUT"
  [ "$status" -eq 2 ]
  # --pool and --tier select one pool/tier for a single stream; --lists always
  # writes both pools per node, so combining them is a usage error too.
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" rank --lists "$OUT/lists" --repo "$REPO" --out "$OUT" --pool crux
  [ "$status" -eq 2 ]
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" rank --lists "$OUT/lists" --repo "$REPO" --out "$OUT" --tier code
  [ "$status" -eq 2 ]
}
