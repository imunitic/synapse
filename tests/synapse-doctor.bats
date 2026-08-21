#!/usr/bin/env bats
# Tests `synapse doctor` -- the one command that speaks where the rest of the system
# deliberately stays silent. Everything but the CLI-layer environment-robustness
# check moved to native coverage -- src/apps/synapse/doctor_cmd.zig's own `test`
# blocks, via the `diagnose()` entry point `run()` delegates to after arg parsing.

load 'test_helper'

setup() {
  common_setup
  setup_fake_obsidian_plugin
  CURL_LOG="$TEST_HOME/curl.log"
  : > "$CURL_LOG"
}

teardown() {
  common_teardown
}

@test "--help works outside a repo and with no environment at all" {
  # Asserted here as well as in the generator, because this is the command a broken
  # machine reaches for first.
  run env -i PATH="$PATH" "$SYNAPSE_BIN" doctor --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: synapse doctor"* ]]
}
