#!/usr/bin/env bats
# Black-box coverage for the mandatory Vault-note schema boundary and the
# vault-write/vault-patch timestamp lifecycle.

load 'test_helper'

setup() {
  common_setup
  export SYNAPSE_CONTENT_ROOT="$REPO_ROOT/packages/synapse"
  printf 'synapse=sb\n' > "$HOME/.claude/synapse-projects.conf"
  printf 'synapse\narchitecture\nvault-infra\n' > "$HOME/.claude/synapse-tag-vocabulary.conf"
  export -f bare_note task_note
}

teardown() {
  common_teardown
}

bare_note() {
  local title="$1" id="$2"
  printf '%s\n' \
    '---' \
    'schema: vault-note/v1' \
    "title: \"$title\"" \
    "note_id: $id" \
    'created: "2026-08-30 01:00:00 CEST"' \
    'updated: "2026-08-30 01:00:00 CEST"' \
    'tags: [synapse, architecture]' \
    '---' '' \
    "# $title" '' \
    '## Summary' '' \
    'A useful summary.'
}

task_note() {
  local title="$1" id="$2"
  printf '%s\n' \
    '---' \
    'schema: vault-task-note/v1' \
    "title: \"$title\"" \
    'project: sb' \
    "task_id: $id" \
    'created: "2026-08-30 01:00:00 CEST"' \
    'updated: "2026-08-30 01:00:00 CEST"' \
    'tags:' \
    '  - synapse' \
    '  - architecture' \
    'status: TODO' \
    '---' '' \
    "# $title" '' \
    'Implement the requested change.' '' \
    '## Checklist' '' \
    '- [ ] First implementation step' '' \
    '## Notes' '' \
    'Design context.'
}

@test "all three shipped v1 note schemas validate through vault-write" {
  run bash -c 'bare_note "$1" "$2" | "$3" vault-write "research/$1.md"' _ \
    "Bare example" sb-901 "$SYNAPSE_BIN"
  [ "$status" -eq 0 ]

  run bash -c 'task_note "$1" "$2" | "$3" vault-write "tasks/synapse/$1.md"' _ \
    "Task example" sb-902 "$SYNAPSE_BIN"
  [ "$status" -eq 0 ]

  run bash -c 'printf "%s\n" \
    "---" \
    "schema: vault-design-note/v1" \
    "title: \"sb — Design example\"" \
    "project: sb" \
    "note_id: sb-903" \
    "created: \"2026-08-30 01:00:00 CEST\"" \
    "updated: \"2026-08-30 01:00:00 CEST\"" \
    "tags: [synapse, architecture]" \
    "---" "" \
    "# sb — Design example" "" \
    "## Status" "Discussing" "" \
    "## Problem" "A concrete problem." "" \
    "## Approach" "A concrete approach." "" \
    "## Constraints" "A concrete constraint." | \
    "$1" vault-write "designs/synapse/sb — Design example.md"' _ "$SYNAPSE_BIN"
  [ "$status" -eq 0 ]
}

@test "invalid schema-declaring notes fail with a field diagnostic and no partial file" {
  local body
  body="$(bare_note "Wrong title" sb-904)"
  run bash -c 'printf "%s\n" "$1" | "$2" vault-write "research/Right title.md"' _ "$body" "$SYNAPSE_BIN"
  [ "$status" -eq 1 ]
  [[ "$output" == *"filename.stem"* ]]
  [ ! -e "$VAULT/research/Right title.md" ]
}

@test "unknown and unsafe schema identifiers fail closed" {
  run bash -c 'printf "%s\n" "---" "schema: vault-missing/v1" "---" | "$1" vault-write missing.md' _ "$SYNAPSE_BIN"
  [ "$status" -eq 1 ]
  [[ "$output" == *"schema:"* ]]
  [ ! -e "$VAULT/missing.md" ]

  run bash -c 'printf "%s\n" "---" "schema: ../secret" "---" | "$1" vault-write unsafe.md' _ "$SYNAPSE_BIN"
  [ "$status" -eq 1 ]
  [[ "$output" == *"unsafe identifier"* ]]
  [ ! -e "$VAULT/unsafe.md" ]
}

@test "note_id and task_id share one creation-time uniqueness namespace" {
  task_note "Identity owner" sb-905 | "$SYNAPSE_BIN" vault-write "tasks/synapse/Identity owner.md"

  run bash -c 'bare_note "$1" "$2" | "$3" vault-write "research/$1.md"' _ \
    "Duplicate identity" sb-905 "$SYNAPSE_BIN"
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]]
  [ ! -e "$VAULT/research/Duplicate identity.md" ]
}

@test "vault-patch refreshes updated before validation and preserves all other frontmatter" {
  bare_note "Timestamp example" sb-906 | "$SYNAPSE_BIN" vault-write "research/Timestamp example.md"

  run bash -c 'printf "More detail.\n" | "$1" vault-patch "research/Timestamp example.md" --heading "Timestamp example::Summary" --append' _ "$SYNAPSE_BIN"
  [ "$status" -eq 0 ]

  run "$SYNAPSE_BIN" frontmatter get "research/Timestamp example.md" updated
  [ "$status" -eq 0 ]
  [[ "$output" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}\ [A-Za-z+-]+$ ]]
  [ "$output" != "2026-08-30 01:00:00 CEST" ]

  run "$SYNAPSE_BIN" frontmatter get "research/Timestamp example.md" note_id
  [ "$output" = "sb-906" ]
}

@test "vault-write refreshes updated on an existing schema note" {
  bare_note "Write timestamp" sb-908 | "$SYNAPSE_BIN" vault-write "research/Write timestamp.md"

  run bash -c 'bare_note "$1" "$2" | sed "s/A useful summary./A replacement summary./" | "$3" vault-write "research/$1.md"' _ \
    "Write timestamp" sb-908 "$SYNAPSE_BIN"
  [ "$status" -eq 0 ]

  run "$SYNAPSE_BIN" frontmatter get "research/Write timestamp.md" updated
  [ "$status" -eq 0 ]
  [ "$output" != "2026-08-30 01:00:00 CEST" ]
  grep -q 'A replacement summary.' "$VAULT/research/Write timestamp.md"
}

@test "a rejected write has no Git integration side effect" {
  local body
  body="$(bare_note "Wrong title" sb-907)"
  SYNAPSE_VAULT_INTEGRATIONS=git run bash -c \
    'printf "%s\n" "$1" | "$2" vault-write "research/Right title.md"' _ "$body" "$SYNAPSE_BIN"
  [ "$status" -eq 1 ]
  [ ! -d "$VAULT/.git" ]
}

@test "vault-patch on H1::Checklist replaces the checklist without touching Notes" {
  task_note "Checklist scoping" sb-910 | "$SYNAPSE_BIN" vault-write "tasks/synapse/Checklist scoping.md"

  run bash -c 'printf "%s\n" "- [x] Done first" "- [ ] Next step" | "$1" vault-patch "tasks/synapse/Checklist scoping.md" --heading "Checklist scoping::Checklist" --replace' _ "$SYNAPSE_BIN"
  [ "$status" -eq 0 ]

  run "$SYNAPSE_BIN" vault-read "tasks/synapse/Checklist scoping.md"
  [[ "$output" == *"## Checklist"* ]]
  [[ "$output" == *"- [x] Done first"* ]]
  [[ "$output" == *"## Notes"* ]]
  [[ "$output" == *"Design context."* ]]
}

@test "vault-rename syncs title/H1 to the new filename, rewrites referrers, and stays vault-check clean" {
  bare_note "Old title" sb-909 | "$SYNAPSE_BIN" vault-write "research/Old title.md"
  bare_note "Referrer" sb-911 | "$SYNAPSE_BIN" vault-write "research/Referrer.md"
  run bash -c 'printf "See [[Old title]] for background.\n" | "$1" vault-patch "research/Referrer.md" --heading "Referrer::Summary" --append' _ "$SYNAPSE_BIN"
  [ "$status" -eq 0 ]

  run "$SYNAPSE_BIN" vault-rename "research/Old title.md" "research/New title.md"
  [ "$status" -eq 0 ]
  [ ! -e "$VAULT/research/Old title.md" ]
  [ -e "$VAULT/research/New title.md" ]

  run "$SYNAPSE_BIN" frontmatter get "research/New title.md" title
  [ "$output" = "New title" ]

  run "$SYNAPSE_BIN" vault-read "research/New title.md"
  [[ "$output" == *"# New title"* ]]

  run "$SYNAPSE_BIN" vault-read "research/Referrer.md"
  [[ "$output" == *"[[New title]]"* ]]

  run "$SYNAPSE_BIN" vault-check
  [ "$status" -eq 0 ]
}

@test "the npm package includes all shipped schema documents" {
  run npm pack --dry-run --json "$REPO_ROOT/packages/synapse"
  [ "$status" -eq 0 ]
  [[ "$output" == *"schema/vault-note/v1.yaml"* ]]
  [[ "$output" == *"schema/vault-design-note/v1.yaml"* ]]
  [[ "$output" == *"schema/vault-task-note/v1.yaml"* ]]
}
