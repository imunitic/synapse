#!/usr/bin/env bats
# Tests `synapse build-lists`'s CLI concerns that native coverage can't
# reach: unknown-flag exit code. Everything else moved to native coverage --
# `build_lists_cmd.zig`'s own `test` blocks for manifest parsing, per-node
# selection and coverage arithmetic, and `enumerate_cmd.zig`'s own `test`
# blocks (shared via `ensure()`) for enumeration itself: tracked-file
# listing, binary/noise extension filtering, `$SYNAPSE_EXTRA_EXCLUDE_RE`,
# `synapse-ignore-files.conf`, submodule gitlinks, the size cap.

load 'test_helper'


setup() {
  common_setup
  WORK="$TEST_HOME/work"
  mkdir -p "$WORK"
}

teardown() {
  common_teardown
}

# Runs from inside $REPO (the repo is resolved from $PWD) with an explicit work
# dir, which is the arrangement an installed copy in ~/.claude/lib/synapse always has.
run_build() {
  SYNAPSE_WORK_DIR="$WORK" \
    bash -c 'cd "$1" && shift && exec "$@"' _ "$REPO" "$SYNAPSE_BIN" build-lists "$@"
}

write_manifest() {
  printf '%b' "$1" > "$WORK/manifest.tsv"
}

@test "an unknown flag exits 2" {
  make_repo
  write_manifest 'Java\t^mod-a/\t\n'

  run run_build --nope
  [ "$status" -eq 2 ]
}
