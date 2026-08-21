#!/usr/bin/env bats
# Tests `synapse build-refs`'s CLI argument handling. The projection itself
# (name trimming, sort order, tab-safety, unsupported-file counting, error
# messages) moved to native coverage -- `src/apps/synapse/refs_cmd.zig`'s
# own `test` blocks, via the `buildRefs()` entry point `runBuild()`
# delegates to, building the fixture cache directly through
# `core.tags_cache.Cache.commit` rather than round-tripping through
# `tags-cache --load`. What's left here is what native coverage can't
# reach without a real subprocess: argument parsing exit codes.

load 'test_helper'

setup() {
  common_setup
  CACHE="$TEST_HOME/_tags_cache.bin"
  OUT="$TEST_HOME/_refs.tsv"
}

teardown() {
  common_teardown
}

@test "build-refs: --help is exit 0, a bad flag is exit 2" {
  run "$SYNAPSE_BIN" build-refs --help
  [ "$status" -eq 0 ]
  run "$SYNAPSE_BIN" build-refs --nonsense
  [ "$status" -eq 2 ]
}
