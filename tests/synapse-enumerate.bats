#!/usr/bin/env bats
# Tests claude/lib/synapse/synapse-enumerate.sh -- the enumeration half extracted out of
# synapse-build-lists.sh, standalone and vault-free.
#
# The property this file exists to guard: enumeration has no real dependency on
# manifest.tsv, so it must keep working with no manifest anywhere -- that was
# the whole reason it was pulled out of synapse-build-lists.sh, which used to
# gate it behind one.

load 'test_helper'

ENUMERATE="$REPO_ROOT/claude/lib/synapse/synapse-enumerate.sh"

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
    bash -c 'cd "$1" && shift && bash "$@"' _ "$REPO" "$ENUMERATE" "$@"
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

@test "enumerates tracked files with no manifest.tsv anywhere -- the whole point of the split" {
  make_mixed_repo
  [ ! -f "$WORK/manifest.tsv" ]

  run run_enumerate
  [ "$status" -eq 0 ]
  [ ! -f "$WORK/manifest.tsv" ]
  grep -q '^mod-a/src/main/java/A.java$' "$WORK/all.txt"
  grep -q '^docs/guide.md$' "$WORK/all.txt"
  ! grep -q 'logo.png' "$WORK/all.txt"
}

@test "prints the enumerated count" {
  make_mixed_repo
  run run_enumerate
  [ "$status" -eq 0 ]
  local enumerated; enumerated="$(wc -l < "$WORK/all.txt" | tr -d ' ')"
  [[ "$output" == *"enumerated: $enumerated"* ]]
}

@test "an existing all.txt is reused, and --reenumerate rebuilds it" {
  make_mixed_repo
  run run_enumerate
  [ "$status" -eq 0 ]

  printf 'sentinel-only\n' > "$WORK/all.txt"
  run run_enumerate
  [ "$status" -eq 0 ]
  [[ "$output" != *"enumerating"* ]]
  [ "$(cat "$WORK/all.txt")" = "sentinel-only" ]

  run run_enumerate --reenumerate
  [ "$status" -eq 0 ]
  [[ "$output" == *"enumerating"* ]]
  ! grep -q 'sentinel-only' "$WORK/all.txt"
}

@test "files over the size cap are skipped AND reported, never dropped silently" {
  make_repo
  mkdir -p "$REPO/src"
  printf 'small\n' > "$REPO/src/small.java"
  head -c 3000 /dev/zero | tr '\0' 'x' > "$REPO/src/huge.java"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m files

  run env SYNAPSE_MAX_FILE_BYTES=1000 SYNAPSE_WORK_DIR="$WORK" \
    bash -c 'cd "$1" && shift && bash "$@"' _ "$REPO" "$ENUMERATE"
  [ "$status" -eq 0 ]
  grep -qx 'src/small.java' "$WORK/all.txt"
  ! grep -qx 'src/huge.java' "$WORK/all.txt"
  [[ "$output" == *"skipped 1 file(s) over 1000 bytes"* ]]
  [[ "$output" == *"src/huge.java"* ]]
}

@test "a non-repo directory exits 1" {
  mkdir -p "$TEST_HOME/notarepo"
  run env SYNAPSE_WORK_DIR="$WORK" \
    bash -c 'cd "$1" && shift && bash "$@"' _ "$TEST_HOME/notarepo" "$ENUMERATE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not inside a git repo"* ]]
}

@test "work dir comes from \$SYNAPSE_WORK_DIR, not from the script's own location" {
  make_mixed_repo
  run run_enumerate
  [ "$status" -eq 0 ]
  [ ! -e "$(dirname "$ENUMERATE")/all.txt" ]
}

@test "an unknown flag exits 2" {
  make_mixed_repo
  run run_enumerate --nope
  [ "$status" -eq 2 ]
}
