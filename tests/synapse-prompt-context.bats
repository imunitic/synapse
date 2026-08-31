#!/usr/bin/env bats
# Tests `synapse-hook prompt-context` -- the UserPromptSubmit nudge.
#
# The nudge text itself is covered natively, in
# `src/apps/hook/prompt_context.zig`'s own `test` blocks, against the
# `build()` entry point. What stays here is the half `build()` never sees:
# `run()`'s stdin payload handling, which needs a real process with a real
# JSON payload on stdin to exercise at all.
#
# This file used to hold one test, for a `SYNAPSE_DISABLE_PROMPT_INJECTION`
# short-circuit that ran before the payload was parsed. That flag gated the
# tokenize-and-search version of this hook and was removed with it, so the
# coverage here became the payload path instead.

load 'test_helper'

setup() {
  common_setup
}

teardown() {
  common_teardown
}

# Enough of a namespace for the hook to have something to announce: an
# Index.md whose `remote` matches this repo, plus one node so the count is
# non-zero (the hook stays silent at zero nodes).
make_namespace() {
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  cat > "$VAULT/synapse/$(repo_name)/Foo Node.md" <<'EOF'
---
title: "Foo Node"
node_type: synapse-node
stale: false
---
# Foo Node
EOF
}

run_hook() {
  local prompt="$1" cwd="$2"
  export PATH="$FAKE_BIN:$PATH"
  # A temp file, not a pipe: if the hook exits before draining stdin, jq
  # racing the exit surfaces as "writing output failed: Broken pipe", which
  # bats' `run` merges into $output and which then fails an output assertion
  # for a reason that has nothing to do with the hook.
  local input="$BATS_TEST_TMPDIR/hook-input.json"
  jq -n --arg prompt "$prompt" --arg cwd "$cwd" '{prompt: $prompt, cwd: $cwd}' > "$input"
  "$SYNAPSE_HOOK_BIN" prompt-context < "$input"
}

@test "a real stdin payload in a repo with a namespace emits the nudge" {
  make_repo
  make_namespace

  run run_hook "how does Cached_backend invalidate results" "$REPO"
  [ "$status" -eq 0 ]

  local ctx
  ctx="$(printf '%s' "$output" | jq -r '.hookSpecificOutput.additionalContext')"
  [[ "$ctx" == *"synapse/$(repo_name)/"* ]]
  [[ "$ctx" == *"1 nodes"* ]]
  # The instruction, not a suggestion -- the wording is the feature here.
  [[ "$ctx" == *"Query it FIRST"* ]]
  [[ "$ctx" == *"Do not grep or open source files"* ]]
}

@test "an empty prompt exits silently, before anything is announced" {
  make_repo
  make_namespace

  run run_hook "" "$REPO"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
