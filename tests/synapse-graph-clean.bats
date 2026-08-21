#!/usr/bin/env bats
# Tests `synapse graph-clean` -- the only destructive tool in Synapse other
# than graph-wipe. Everything but the CLI-layer usage errors moved to
# native coverage -- src/apps/synapse/graph_cmd.zig's own `test` blocks, via
# the `clean()` entry point `runClean()` delegates to after arg parsing.
# `context.resolve` always resolves identity from "." (the real process
# cwd), not a caller-supplied path, so "outside a git repo" can't be driven
# in-process without mutating the whole shared test binary's cwd -- that one
# case, and the unknown-flag exit code, are what remain here.

load 'test_helper'


setup() {
  common_setup
  REMOTE_REPO="$TEST_HOME/remote.git"
}

teardown() { common_teardown; }

run_clean() {
  bash -c 'cd "$1" && shift && exec "$@"' _ "$REPO" "$SYNAPSE_BIN" graph-clean "$@"
}

@test "outside a git repo it exits 1, and an unknown flag exits 2" {
  run bash -c 'cd "$1" && exec "$2" "$3"' _ "$TEST_HOME" "$SYNAPSE_BIN" graph-clean
  [ "$status" -eq 1 ]

  make_repo
  run run_clean --bogus
  [ "$status" -eq 2 ]
}
