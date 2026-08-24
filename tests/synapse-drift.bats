#!/usr/bin/env bats
# Tests `synapse query drift`'s one genuinely process-level case: a real
# branch switch landing on a namespace that doesn't describe it. The diff
# logic itself (modified/deleted/renamed/added classification,
# baseline resolution, divergence, upstream context, manifest classification)
# moved to native coverage -- `src/apps/synapse/query_cmd.zig`'s own `test`
# blocks, calling `cmdDrift` directly against a real git repo built through
# `cmd_test_support.zig`'s `Fixture.gitCommit`/`Fixture.git`.
#
# Fixing that native coverage in caught a real leak along the way: `cmdDrift`
# owns each baseline's diff through `ownDiff` (individually-allocated path
# strings), but freed it through `Diff.deinit`, which only frees the four
# outer slices -- correct for `parseNameStatus`'s own borrowed-string result,
# not for `ownDiff`'s owned one. Fixed with a dedicated `freeOwnedDiff`.

load 'test_helper'


setup() {
  common_setup
  setup_fake_obsidian_plugin
  CURL_LOG="$TEST_HOME/curl.log"
  : > "$CURL_LOG"
  WORK="$TEST_HOME/work"
  mkdir -p "$WORK"
}

teardown() {
  common_teardown
}

run_drift() {
  PATH="$FAKE_BIN:$PATH" \
    FAKE_CURL_LOG="$CURL_LOG" \
    FAKE_CURL_VAULT_DIR="$VAULT" \
    SYNAPSE_WORK_DIR="$WORK" \
    bash -c 'cd "$1" && shift && exec "$@"' _ "$REPO" "$SYNAPSE_BIN" query drift "$@"
}

make_two_area_repo() {
  make_repo
  mkdir -p "$REPO/mod-a" "$REPO/docs"
  printf 'class A {}\n' > "$REPO/mod-a/a.bb"
  printf 'class B {}\n' > "$REPO/mod-a/b.bb"
  printf '# guide\n' > "$REPO/docs/guide.md"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m two-areas
}

git_head() { git -C "$REPO" rev-parse HEAD; }

stage_node() { # stage_node <title> <commit> <path>...
  local title="$1" commit="$2"; shift 2
  mkdir -p "$VAULT/synapse/$(repo_name)"
  {
    echo '---'
    echo "title: \"$title\""
    echo 'summary: "One line."'
    echo 'node_type: synapse-node'
    echo "project: $(repo_name)"
    echo 'sources:'
    local p
    for p in "$@"; do
      echo "  - path: $p"
      echo "    hash: $(git -C "$REPO" hash-object "$p" 2>/dev/null || echo deadbeef)"
    done
    echo 'sources_digest: notchecked'
    echo 'stale: false'
    echo 'built_at: "2026-01-01 00:00"'
    [ -n "$commit" ] && echo "commit: $commit"
    echo '---'
    echo
    echo "# $title"
    echo '<!-- synapse:generated:start -->'
    echo 'body'
    echo '<!-- synapse:generated:end -->'
    echo
    echo '## Notes'
  } > "$VAULT/synapse/$(repo_name)/$title.md"
}

stage_index() { # stage_index <node.md> <path>...
  local node="$1" p; shift
  for p in "$@"; do printf '%s\t%s\n' "$p" "$node"; done \
    | write_index_bin "$WORK"
}

@test "on a branch with no namespace, drift says so rather than reporting clean" {
  # The other half of the per-branch model, and the one that must not be silent:
  # a namespace describes one branch, so another branch has none. Exit 1 is
  # "could not run", never "clean" -- silence here would read as a graph that
  # matches, which is the conflation the keying exists to remove.
  make_two_area_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  local base; base="$(git_head)"
  stage_node "Mod A" "$base" mod-a/a.bb
  stage_index "Mod A.md" mod-a/a.bb

  run run_drift
  [ "$status" -eq 0 ]

  git -C "$REPO" checkout -q -b some-other-branch
  run run_drift
  [ "$status" -eq 1 ]
  [[ "$output" != *"is not an ancestor of HEAD"* ]]
}
