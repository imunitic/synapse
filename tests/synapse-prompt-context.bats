#!/usr/bin/env bats
# Tests claude/hooks/synapse-prompt-context.sh -- the UserPromptSubmit nudge.
#
# Everything but the disable-via-env-var short-circuit moved to native
# coverage -- `src/apps/hook/prompt_context.zig`'s own `test` blocks, via the
# `build()` entry point `run()` delegates to after reading the stdin payload.
# This is the one case that genuinely needs a real stdin payload: proving the
# env var check happens before the payload is ever parsed, so no API call is
# made and nothing is printed even with a well-formed prompt on stdin.

load 'test_helper'


setup() {
  common_setup
  setup_fake_obsidian_plugin
  cp "$REPO_ROOT/plugins/synapse/synapse-prompt-stopwords.conf.template" \
    "$HOME/.claude/synapse-prompt-stopwords.conf"
  CURL_LOG="$TEST_HOME/curl.log"
  : > "$CURL_LOG"
}

teardown() {
  common_teardown
}

run_hook() {
  local prompt="$1" cwd="$2"
  export PATH="$FAKE_BIN:$PATH"
  export FAKE_CURL_LOG="$CURL_LOG"
  export FAKE_CURL_VAULT_DIR="$VAULT"
  # A temp file, not a pipe: the hook's disable check is its literal first
  # line, so a disabled run exits before ever reading stdin. Piping jq's
  # output straight in races the hook's exit against jq's write -- confirmed
  # on CI (both runners) as "jq: error: writing output failed: Broken pipe",
  # merged into $output by bats' run and failing the "no output" assertion.
  # Writing to a file first and redirecting it as stdin has no such race.
  local input="$BATS_TEST_TMPDIR/hook-input.json"
  jq -n --arg prompt "$prompt" --arg cwd "$cwd" '{prompt: $prompt, cwd: $cwd}' > "$input"
  "$SYNAPSE_HOOK_BIN" prompt-context < "$input"
}

@test "disabled via env var: no output, no API call at all" {
  make_repo
  # Exported directly rather than as a `VAR=1 run ...` prefix -- prefix
  # assignment before invoking a function is not reliably propagated through
  # bats' own `run` wrapper across bats/bash versions.
  export SYNAPSE_DISABLE_PROMPT_INJECTION=1
  run run_hook "how does Cached_backend invalidate results" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -s "$CURL_LOG" ]
}
