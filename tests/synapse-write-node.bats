#!/usr/bin/env bats
# Tests `synapse write-node` -- the writer that keeps a node's
# exhaustive `sources` out of a context window in both directions.
#
# The Obsidian Local REST API is stubbed by tests/fixtures/fake-bin/curl, which
# writes PUT payloads as real files under $FAKE_CURL_VAULT_DIR, so these tests
# assert on the actual bytes the vault would receive.
#
# Node-assembly logic, the real-git baseline-commit/dirty-sources fields and
# the tags-cache wiring all moved to native `zig build test` coverage --
# `src/apps/synapse/write_node_cmd.zig`'s own `test` blocks, calling `write()`
# directly against `cmd_test_support.zig`'s fixture (real git, fake curl, a
# fake extractor). What's left here are two warning pairs that only ever
# reach real stderr via `std.debug.print`, which no in-process fixture
# captures.

load 'test_helper'

setup() {
  common_setup
  setup_fake_obsidian_plugin
  CURL_LOG="$TEST_HOME/curl.log"
  : > "$CURL_LOG"
  BODY="$TEST_HOME/body.md"
  PATHS="$TEST_HOME/paths.txt"
  printf '## Summary\nA node.\n\n## Links\n- part_of [[Other]]\n' > "$BODY"
  # For the tags-cache wiring: tagging is `synapse tags-cache` in the binary,
  # and common_setup points $SYNAPSE_BIN at the stubbed-grammar build.
  GRAMMARS_DIR="$TEST_HOME/grammars"
  FAKE_TS_LOG="$TEST_HOME/ts.log"
  FAKE_GIT_LOG="$TEST_HOME/git.log"
  : > "$FAKE_TS_LOG"
  : > "$FAKE_GIT_LOG"
  printf '{"ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}' \
    > "$HOME/.claude/synapse-grammars.conf"
}

teardown() {
  common_teardown
}

# The script resolves the repo from $PWD, so run it from inside $REPO. A --summary is
# supplied by default so the tests that are not about summaries stay readable;
# $SUMMARY overrides it and run_writer_raw skips it entirely.
run_write() {
  run_writer_raw --summary "${SUMMARY:-A one-line summary.}" "$@"
}

run_writer_raw() {
  # SYNAPSE_DISABLE_SYMBOL_CACHE, if a test `export`ed it, is inherited by the
  # `bash -c` child below automatically -- no need to re-list it here.
  PATH="$FAKE_BIN:$PATH" \
    FAKE_CURL_LOG="$CURL_LOG" \
    FAKE_CURL_VAULT_DIR="$VAULT" \
    FAKE_CURL_PUT_STATUS="${PUT_STATUS:-200}" \
    SYNAPSE_GRAMMARS_DIR="$GRAMMARS_DIR" \
    FAKE_TS_LOG="$FAKE_TS_LOG" \
    FAKE_GIT_LOG="$FAKE_GIT_LOG" \
    bash -c 'cd "$1" && shift && exec "$@"' _ "$REPO" "$SYNAPSE_BIN" write-node "$@"
}

# A repo with files at three shapes that the `## Sources` module rule treats
# differently: under a module's src/, under a top-level dir, and at the root.
make_layered_repo() {
  make_repo "${1:-}"
  mkdir -p "$REPO/mod-a/src/main/java/com/example" "$REPO/mod-b/src/main/java" "$REPO/docs"
  printf 'class A {}\n' > "$REPO/mod-a/src/main/java/com/example/A.java"
  printf 'class B {}\n' > "$REPO/mod-a/src/main/java/com/example/B.java"
  printf 'class C {}\n' > "$REPO/mod-b/src/main/java/C.java"
  printf '# doc\n' > "$REPO/docs/guide.md"
  printf 'root\n' > "$REPO/rootfile.txt"
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m layered
}

@test "uncommitted changes in this node's own sources are called out" {
  make_layered_repo
  printf 'mod-a/src/main/java/com/example/A.java\n' > "$PATHS"
  printf 'class A { int changed; }\n' > "$REPO/mod-a/src/main/java/com/example/A.java"

  run run_write --title "Dirty" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 0 ]
  # git hash-object fingerprints the worktree, so the recorded commit is "what was
  # checked out" rather than a faithful baseline -- worth saying, since a later diff
  # would otherwise compare against content that was never committed.
  [[ "$output" == *"uncommitted changes in this node's sources"* ]]
  [[ "$output" == *"A.java"* ]]
}

@test "a dirty file outside the node's sources stays quiet" {
  make_layered_repo
  printf 'docs/guide.md\n' > "$PATHS"
  printf 'class A { int changed; }\n' > "$REPO/mod-a/src/main/java/com/example/A.java"

  run run_write --title "Quiet" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 0 ]
  # Narrow on purpose: a developer mid-work elsewhere in the repo should not be
  # warned on every node write.
  [[ "$output" != *"uncommitted changes"* ]]
}

@test "a title needing sanitizing warns that inbound wikilinks will not resolve" {
  # The filename-vs-frontmatter-title split this warns about is covered
  # natively ("a sanitised title keeps the original in frontmatter, only the
  # filename changes"); the warning text itself needs a real stderr, which
  # the native fixture doesn't capture, so that half stays here.
  make_repo
  printf 'src/foo.ml\n' > "$PATHS"

  run run_write --title "Bad — import/export" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING"* ]]
  [[ "$output" == *"will not resolve"* ]]
}

@test "a clean title writes silently" {
  make_repo
  printf 'src/foo.ml\n' > "$PATHS"

  run run_write --title "Bad — import and export" --paths "$PATHS" --body "$BODY"
  [ "$status" -eq 0 ]
  [[ "$output" != *"WARNING"* ]]
}

