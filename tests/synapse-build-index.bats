#!/usr/bin/env bats
# Tests claude/lib/synapse/synapse-build-index.sh -- the reverse index the PostToolUse
# staleness hook reads. Its two load-bearing properties are that it covers every
# enumerated path (an unlisted path silently flags nothing stale) and that its
# values are usable as vault paths verbatim, i.e. carry the `.md` extension.
#
# The index is now $SYNAPSE_WORK_DIR/_index.bin, so these assertions read it back
# through `synapse index lookup` and `synapse index unassigned` rather than with
# `jq` over a captured PUT body. That is a round trip rather than an inspection,
# which is the point: the only thing that has to hold is that what a reader finds
# matches what the lists said, and a reader is exactly what these two forms are.
# The previous curl capture is gone along with the PUT -- see the "no vault, no
# curl" test for what replaced the failed-PUT case.

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

# The nodes claiming one path, comma-joined, read back out of the written index.
claimants() {
  SYNAPSE_WORK_DIR="$WORK" "$SYNAPSE_BIN" index lookup "$1" | paste -sd, -
}

unassigned_paths() {
  SYNAPSE_WORK_DIR="$WORK" "$SYNAPSE_BIN" index unassigned
}

@test "maps each path to its owning node, with the .md extension" {
  stage_list 01 "Mod A" mod-a/a.txt mod-a/b.txt
  stage_list 02 "Docs" docs/d.md

  run run_build_index
  [ "$status" -eq 0 ]

  # The hook and the read-time procedure use this value directly as a vault path
  # with no extension handling of their own.
  [ "$(claimants mod-a/a.txt)" = "Mod A.md" ]
  [ "$(claimants mod-a/b.txt)" = "Mod A.md" ]
  [ "$(claimants docs/d.md)" = "Docs.md" ]
}

@test "a file load-bearing for two concepts lists both nodes, sorted" {
  # Many-to-many is intentional in the design, not an oversight.
  stage_list 01 "Zeta" shared/thing.java
  stage_list 02 "Alpha" shared/thing.java

  run run_build_index
  [ "$status" -eq 0 ]
  [ "$(claimants shared/thing.java)" = "Alpha.md,Zeta.md" ]
}

@test "the unassigned list carries what no node claimed, in the order given" {
  stage_list 01 "Mod A" mod-a/a.txt
  printf 'stray.txt\n.claude/settings.json\n' > "$WORK/unassigned.txt"

  run run_build_index
  [ "$status" -eq 0 ]
  [[ "$output" == *"unassigned=2"* ]]
  [ "$(unassigned_paths | paste -sd, -)" = "stray.txt,.claude/settings.json" ]
}

@test "an unassigned path is not also a claimed one" {
  # "Claimed by nobody" and "never enumerated" are different answers, and the
  # index has to keep them apart: the first is in the unassigned list, the
  # second is in neither place. `lookup` says nothing for both, by design.
  stage_list 01 "Mod A" mod-a/a.txt
  printf 'stray.txt\n' > "$WORK/unassigned.txt"

  run run_build_index
  [ "$status" -eq 0 ]

  run bash -c "SYNAPSE_WORK_DIR='$WORK' '$SYNAPSE_BIN' index lookup stray.txt"
  [ "$status" -eq 1 ]
  [ -z "$output" ]

  run bash -c "SYNAPSE_WORK_DIR='$WORK' '$SYNAPSE_BIN' index lookup never/enumerated.txt"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "an empty unassigned.txt yields no entries, not one blank one" {
  stage_list 01 "Mod A" mod-a/a.txt
  : > "$WORK/unassigned.txt"

  run run_build_index
  [ "$status" -eq 0 ]
  [[ "$output" == *"unassigned=0"* ]]
  [ -z "$(unassigned_paths)" ]
}

@test "node values are sanitized to the filenames that actually exist on disk" {
  # The value has to match the file the writer produced, which is the sanitized
  # title -- an unsanitized value would point the hook at a nonexistent note.
  stage_list 01 "Bad — import/export" mod-a/a.txt

  run run_build_index
  [ "$status" -eq 0 ]
  [ "$(claimants mod-a/a.txt)" = "Bad — import_export.md" ]
}

@test "blank lines in a list do not become empty keys" {
  printf 'Mod A\n' > "$WORK/lists/01.title"
  printf 'mod-a/a.txt\n\nmod-a/b.txt\n\n' > "$WORK/lists/01.txt"

  run run_build_index
  [ "$status" -eq 0 ]
  # Two paths, and `keys` now counts only paths. The JSON index reported 3 here,
  # because `_unassigned` was a sibling key of every path in the same object and
  # `jq 'keys | length'` counted it. It is a separate region now, counted
  # separately, so the honest number for two paths is 2.
  [[ "$output" == *"keys=2"* ]]
  run bash -c "SYNAPSE_WORK_DIR='$WORK' '$SYNAPSE_BIN' index lookup ''"
  [ "$status" -ne 0 ]
}

@test "a list with no matching .title file is skipped rather than keyed to '.md'" {
  stage_list 01 "Mod A" mod-a/a.txt
  printf 'orphan/path.txt\n' > "$WORK/lists/99.txt"

  run run_build_index
  [ "$status" -eq 0 ]
  run bash -c "SYNAPSE_WORK_DIR='$WORK' '$SYNAPSE_BIN' index lookup orphan/path.txt"
  [ "$status" -eq 1 ]
}

@test "reports key count and byte size so a truncated index is visible" {
  stage_list 01 "Mod A" mod-a/a.txt mod-a/b.txt
  run run_build_index
  [ "$status" -eq 0 ]
  [[ "$output" == *"keys=2"* ]]
  [[ "$output" == *"bytes="* ]]
  [ -s "$WORK/_index.bin" ]
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
