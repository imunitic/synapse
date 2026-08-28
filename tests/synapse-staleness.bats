#!/usr/bin/env bats
# Tests `synapse-hook staleness` (Tier 1 PostToolUse staleness flagging).
# Everything but the real stdin-payload round trip moved to
# native coverage -- src/apps/hook/staleness.zig's own `test` blocks, via
# the `build()` entry point `run()` delegates to after reading `tool_input.
# file_path`/`tool_response.filePath` and `session_id` off stdin. This is
# the one case that genuinely needs a real stdin payload and the compiled
# binary: proving that wiring, end to end, actually works.

load 'test_helper'


# Writes a Synapse node whose frontmatter contains every shape the old
# `PATCH -H "Target-Type: frontmatter"` call used to mangle: a title long
# enough to be line-folded, quoted values, and an all-digit `hash` that
# YAML happily coerces to a float.
write_synapse_node() {
  local project="$1" node="$2" stale="${3:-false}"
  mkdir -p "$VAULT/synapse/$project"
  cat > "$VAULT/synapse/$project/$node" <<EOF
---
title: "A deliberately long node title that a re-serialising writer would fold across two lines"
node_type: synapse-node
project: $project
sources:
  - path: src/foo.aa
    hash: 1111111111111111111111111111111111111111
sources_digest: "2222222222222222222222222222222222222222222222222222222222222222"
stale: $stale
built_at: "2026-08-03 16:15"
---

# A node

Body text, including a decoy: stale: false
EOF
}

setup() {
  common_setup
  WORK="$TEST_HOME/work"
  mkdir -p "$WORK"
}

teardown() {
  common_teardown
}

# Runs the hook against $1 (the edited file path), with the index staged from
# $2 -- `<node.md> <path>...`, or nothing for "no namespace exists".
run_staleness_hook() {
  local file="$1"; shift
  if [ "$#" -gt 0 ]; then
    local node="$1" p; shift
    for p in "$@"; do printf '%s\t%s\n' "$p" "$node"; done | write_index_bin "$WORK"
  else
    rm -f "$WORK/_index.bin"
  fi
  PATH="$FAKE_BIN:$PATH" \
    SYNAPSE_WORK_DIR="$WORK" \
    bash -c "printf '%s' \"\$2\" | jq -Rn '{tool_input:{file_path: input}}' | \"\$0\" \"\$1\"" "$SYNAPSE_HOOK_BIN" staleness "$file"
}

@test "file mapped to a node: rewrites that node's stale line, never PATCHes frontmatter" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  write_synapse_node "$(repo_name)" "Foo Node.md" false

  run run_staleness_hook "$REPO/src/foo.aa" 'Foo Node.md' src/foo.aa
  [ "$status" -eq 0 ]
  grep -q "stale: true" "$VAULT/synapse/$(repo_name)/Foo Node.md"
}
