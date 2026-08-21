#!/usr/bin/env bats
# Tests `synapse tags-cache` -- the mechanical helper that keeps a per-project
# tags cache current for a set of path:hash pairs, re-tagging only what changed
# and never touching a file that is already current. The mechanical/attribution
# behavior (batching, caching, unsupported vs parsed-empty, re-tagging only
# what's changed) is covered by tags_cache_cmd.zig's own native tests, using
# `fake_grammar.FakeExtractor` in place of a real or shelled-out tree-sitter;
# this file keeps only the CLI-arg-parsing usage error that `run()`'s own
# pre-validation rejects before `update()` is ever called.

load 'test_helper'

setup() {
  common_setup
}

teardown() {
  common_teardown
}

@test "missing arguments: usage error, exit 1" {
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" tags-cache --repo-root "$REPO"
  [ "$status" -eq 1 ]
}
