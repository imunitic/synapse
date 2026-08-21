#!/usr/bin/env bats
# Tests `synapse build-index`'s two genuinely process-level concerns: that
# it runs with no vault or curl configured at all (a real environment
# check), and the exact wording of its three distinct error messages
# (real stderr, not capturable from a native test). The index-building
# logic itself (path-to-node mapping, unassigned tracking, sanitized
# filenames, key/byte counts) moved to native coverage --
# `src/apps/synapse/index_cmd.zig`'s own `test` blocks, via the
# `buildIndexAt()` entry point `runBuildIndex()` delegates to.

load 'test_helper'

setup() {
  common_setup
  WORK="$TEST_HOME/work"
  mkdir -p "$WORK/lists"
  : > "$WORK/unassigned.txt"
  make_repo
}

teardown() {
  common_teardown
}

run_build_index() {
  SYNAPSE_WORK_DIR="$WORK" \
    bash -c 'cd "$1" && shift && exec "$@"' _ "$REPO" "$SYNAPSE_BIN" build-index "$@"
}

stage_list() {
  local nn="$1" title="$2"; shift 2
  printf '%s\n' "$title" > "$WORK/lists/$nn.title"
  printf '%s\n' "$@" > "$WORK/lists/$nn.txt"
}

@test "no vault, no curl: the index is written with neither configured" {
  # This replaces the old failed-PUT test, whose machinery stopped existing. The
  # index is derived, gitignored in the vault and never travelled, so it is
  # written locally now -- which means this script no longer reads the plugin's
  # API key or certificate, and no longer needs the agent sandbox disabled.
  stage_list 01 "Mod A" mod-a/a.txt

  run env -u OBSIDIAN_VAULT_DIR PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    SYNAPSE_BIN="$SYNAPSE_BIN" SYNAPSE_WORK_DIR="$WORK" HOME="$TEST_HOME" \
    bash -c 'cd "$1" && shift && exec "$@"' _ "$REPO" "$SYNAPSE_BIN" build-index
  [ "$status" -eq 0 ]
  [ -s "$WORK/_index.bin" ]
}

@test "missing lists, missing unassigned.txt and an empty lists dir each exit 1" {
  run run_build_index
  [ "$status" -eq 1 ]
  [[ "$output" == *"no (path, node) pairs"* ]]

  stage_list 01 "Mod A" mod-a/a.txt
  rm -f "$WORK/unassigned.txt"
  run run_build_index
  [ "$status" -eq 1 ]
  [[ "$output" == *"no unassigned.txt"* ]]

  : > "$WORK/unassigned.txt"
  rm -rf "$WORK/lists"
  run run_build_index
  [ "$status" -eq 1 ]
  [[ "$output" == *"no lists/"* ]]
}
