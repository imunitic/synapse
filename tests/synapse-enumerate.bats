#!/usr/bin/env bats
# Tests `synapse enumerate`'s CLI concerns that native coverage can't
# reach: the "wrong location" guard and unknown-flag exit code. The
# enumeration logic itself (tracked-file listing, all.txt caching,
# --reenumerate, the size cap, the not-a-repo message) moved to native
# coverage -- `src/apps/synapse/enumerate_cmd.zig`'s own `test` blocks, via
# the `runEnumerate()` entry point `run()` delegates to, driven against a
# real git repo built through `cmd_test_support.zig`'s `Fixture.gitCommit`.

load 'test_helper'


setup() {
  common_setup
  WORK="$TEST_HOME/work"
  mkdir -p "$WORK"
}

teardown() {
  common_teardown
}

run_enumerate() {
  SYNAPSE_WORK_DIR="$WORK" \
    bash -c 'cd "$1" && shift && exec "$@"' _ "$REPO" "$SYNAPSE_BIN" enumerate "$@"
}

make_mixed_repo() {
  make_repo
  mkdir -p "$REPO/mod-a/src/main/java" "$REPO/docs" "$REPO/assets"
  printf 'class A {}\n' > "$REPO/mod-a/src/main/java/A.java"
  printf '# guide\n' > "$REPO/docs/guide.md"
  printf 'stray\n' > "$REPO/stray.txt"
  printf 'PNGDATA\n' > "$REPO/assets/logo.png"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m mixed
}

@test "work dir comes from \$SYNAPSE_WORK_DIR, not from the script's own location" {
  make_mixed_repo
  run run_enumerate
  [ "$status" -eq 0 ]
  [ ! -e "$(dirname "$SYNAPSE_BIN")/all.txt" ]
}

@test "an unknown flag exits 2" {
  make_mixed_repo
  run run_enumerate --nope
  [ "$status" -eq 2 ]
}
