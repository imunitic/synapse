#!/usr/bin/env bats
# Tests `synapse graph-wipe` -- the delete half of /synapse-rebuild-full,
# and the second destructive tool in Synapse (after `graph-clean`). Arg
# parsing and the wipe logic itself moved to native coverage --
# `src/apps/synapse/graph_cmd.zig`'s own `test` blocks, via the `wipe()`
# entry point `runWipe()` delegates to. What's left is the one thing native
# coverage can't reach: a real multi-subcommand composition proving the
# destructive operation and a fresh rebuild actually work together end to
# end.

load 'test_helper'


setup() {
  common_setup
  WORK="$TEST_HOME/work"
  mkdir -p "$WORK"
}

teardown() { common_teardown; }

run_wipe() {
  bash -c 'cd "$1" && shift && exec "$@"' _ "$REPO" "$SYNAPSE_BIN" graph-wipe "$@"
}

in_repo() {
  PATH="$FAKE_BIN:$PATH" \
    SYNAPSE_WORK_DIR="$WORK" \
    SYNAPSE_CONTENT_ROOT="$SCHEMA_CONTENT_ROOT" \
    bash -c 'cd "$1" && shift && exec "$@"' _ "$REPO" "$@"
}

ns_dir() { echo "$VAULT/synapse/$(repo_name)"; }
staging_note() { echo "$VAULT/scratchpad/$(repo_name) — preserved notes before full rebuild.md"; }

# A minimal two-node namespace: one node with hand-written ## Notes content
# (at risk), one with the section present but empty (not at risk) -- the exact
# shape synapse-write-node.sh produces, not a simplified stand-in, since the
# extraction logic depends on the literal generated-fence markers.
make_namespace() {
  local dir; dir="$(ns_dir)"
  mkdir -p "$dir"
  cat > "$dir/Index.md" <<EOF
---
title: "$(repo_name) — Synapse index"
node_type: synapse-index
project: $(ns_repo)
branch: $(ns_branch)
remote: "$(repo_remote_or_path)"
built_at: "test"
---
- [[Node A]]
- [[Node B]]
EOF
  cat > "$dir/Node A.md" <<'EOF'
---
title: "Node A"
summary: "Node A in one line."
node_type: synapse-node
---

# Node A
<!-- synapse:generated:start -->

## Summary
Generated stuff about Node A.

## Sources
- `src` (1)
<!-- synapse:generated:end -->

## Notes

Hand-written finding worth keeping: the retry logic here is load-bearing for the batch job, do not simplify it away.
EOF
  cat > "$dir/Node B.md" <<'EOF'
---
title: "Node B"
summary: "Node B in one line."
node_type: synapse-node
---

# Node B
<!-- synapse:generated:start -->

## Summary
Generated stuff about Node B.

## Sources
- `src` (1)
<!-- synapse:generated:end -->

## Notes

EOF
  printf 'Node A\t^a\t\nNode B\t^b\t\n' > "$dir/_manifest.tsv"
}

# --- Composes with a real /synapse-init-style rebuild -------------------------
# The mechanical half of what /synapse-rebuild-full actually does end to end: a
# namespace exists, gets wiped (with preservation), and a fresh build over the
# same repo produces a working namespace again -- drift silent, notes-preserving
# staging note still sitting in scratchpad for the (untestable, LLM-driven)
# merge step to pick up later. What is not testable here is that merge step
# itself, same boundary synapse-rebuild-diff-scenario.bats draws around prose.

@test "wipe then rebuild: a fresh /synapse-init-style build over the wiped repo is drift-clean, and the preserved-notes staging note survives" {
  make_repo
  mkdir -p "$REPO/src"
  printf 'let x = 1\n' > "$REPO/src/a.aa"
  printf 'let y = 2\n' > "$REPO/src/b.aa"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m more

  make_namespace
  run run_wipe
  [ "$status" -eq 0 ]
  [ ! -d "$(ns_dir)" ]
  [ -f "$(staging_note)" ]

  printf 'Src — the source module\t^src/\t\n' > "$WORK/manifest.tsv"
  in_repo "$SYNAPSE_BIN" build-lists >/dev/null
  printf -- '---\nsummary: Src in one line.\n---\n\n## Summary\nProse for src.\n' > "$WORK/b-001.md"
  in_repo "$SYNAPSE_BIN" push-nodes >/dev/null
  in_repo "$SYNAPSE_BIN" build-index >/dev/null
  in_repo "$SYNAPSE_BIN" build-project-index >/dev/null

  run in_repo "$SYNAPSE_BIN" query drift
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  # The rebuild does not touch scratchpad -- that staging note is the merge
  # step's input, and only the merge step (not this mechanical rebuild) may
  # consume or delete it.
  [ -f "$(staging_note)" ]
}
