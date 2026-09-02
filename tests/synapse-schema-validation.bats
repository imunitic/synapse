#!/usr/bin/env bats
# The rest of the mandatory Vault-note schema boundary's coverage migrated
# to native Zig tests in src/apps/synapse/vault_cmd.zig ("Real shipped v1
# schema coverage" section) -- each still points SYNAPSE_CONTENT_ROOT at
# the real packages/synapse/schema/ directory, so this remaining test is
# the one thing here with no Zig code behind it at all: the npm package's
# own file manifest.

load 'test_helper'

setup() {
  common_setup
}

teardown() {
  common_teardown
}

@test "the npm package includes all shipped schema documents" {
  run npm pack --dry-run --json "$REPO_ROOT/packages/synapse"
  [ "$status" -eq 0 ]
  [[ "$output" == *"schema/vault-note/v1.yaml"* ]]
  [[ "$output" == *"schema/vault-design-note/v1.yaml"* ]]
  [[ "$output" == *"schema/vault-task-note/v1.yaml"* ]]
}
