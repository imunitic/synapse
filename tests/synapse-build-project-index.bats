#!/usr/bin/env bats
# Tests `synapse build-project-index`'s real git remote resolution: the
# fallback chain (origin -> first configured remote -> git-resolved repo
# root) that `core.identity.resolve` walks when `$SYNAPSE_REMOTE` isn't
# set. Everything else -- frontmatter shape, bullet content/sorting,
# summary escaping, filename-linking, the repo-specific-prose guard, the
# all.txt file count, and the error cases -- moved to native coverage,
# `src/apps/synapse/project_index_cmd.zig`'s own `test` blocks, via the
# `write()` entry point `run()` delegates to, using `$SYNAPSE_REMOTE`
# directly instead of real git remotes wherever the remote value itself
# wasn't what the test was about.

load 'test_helper'


setup() {
  common_setup
  setup_fake_obsidian_plugin
  CURL_LOG="$TEST_HOME/curl.log"
  : > "$CURL_LOG"
  WORK="$TEST_HOME/work"
  mkdir -p "$WORK/lists"
}

teardown() {
  common_teardown
}

run_pindex() {
  PATH="$FAKE_BIN:$PATH" \
    FAKE_CURL_LOG="$CURL_LOG" \
    FAKE_CURL_VAULT_DIR="$VAULT" \
    FAKE_CURL_PUT_STATUS="${PUT_STATUS:-200}" \
    SYNAPSE_WORK_DIR="$WORK" \
    bash -c 'cd "$1" && shift && exec "$@"' _ "$REPO" "$SYNAPSE_BIN" build-project-index "$@"
}

stage_list() {
  local nn="$1" title="$2"; shift 2
  printf '%s\n' "$title" > "$WORK/lists/$nn.title"
  printf '%s\n' "$@" > "$WORK/lists/$nn.txt"
}

stage_node() {
  local title="$1" raw="$2"
  local summary="${raw//\\/\\\\}"
  summary="${summary//\"/\\\"}"
  local link; link="$(printf '%s' "$title" | tr '/:*?"<>|' '_')"
  mkdir -p "$VAULT/synapse/$(repo_name)"
  cat > "$VAULT/synapse/$(repo_name)/$link.md" <<EOF
---
title: "$title"
summary: "$summary"
node_type: synapse-node
project: $(repo_name)
sources:
  - path: x
    hash: y
sources_digest: deadbeef
stale: false
built_at: "2026-01-01 00:00"
---

# $title
<!-- synapse:generated:start -->
body
<!-- synapse:generated:end -->

## Notes
EOF
}

index_file() { echo "$VAULT/synapse/$(repo_name)/Index.md"; }

@test "remote falls back to the first configured remote when there is no origin" {
  make_repo
  git -C "$REPO" remote add upstream "ssh://git@example.com/x/up.git"
  stage_list 01 "Mod A" mod-a/a.txt
  stage_node "Mod A" "Only node."

  run run_pindex
  [ "$status" -eq 0 ]
  grep -q '^remote: "ssh://git@example.com/x/up.git"$' "$(index_file)"
}

@test "remote falls back to the git-resolved repo root when there is no remote at all" {
  make_repo
  stage_list 01 "Mod A" mod-a/a.txt
  stage_node "Mod A" "Only node."

  run run_pindex
  [ "$status" -eq 0 ]
  # The git-resolved path, not the raw $REPO variable: rev-parse resolves symlinks
  # (macOS /tmp -> /private/tmp) and that is what the other components compare.
  grep -q "^remote: \"$(git -C "$REPO" rev-parse --show-toplevel)\"\$" "$(index_file)"
}
