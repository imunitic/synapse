#!/usr/bin/env bats
# Tests the one CLI concern native coverage can't reach: that the real
# binary's dispatch skips the shared vault/namespace preamble entirely for
# this subcommand. The lookup itself (exact-match filtering, call-vs-
# reference, sort agreement) moved to native coverage --
# `src/apps/synapse/refs_cmd.zig`'s own `test` blocks, via the `callers()`
# entry point `runCallers()` delegates to.

load 'test_helper'


setup() {
  common_setup
  make_repo "ssh://git@example.invalid/x/repo.git"
  WORK_DIR="$TEST_HOME/work"
  mkdir -p "$WORK_DIR"
  CACHE="$WORK_DIR/_tags_cache.bin"
  INDEX="$WORK_DIR/_refs.tsv"
}

teardown() {
  common_teardown
}

tagline() { # tagline <padded-name> <kind> <def|ref> <row> <expression>
  printf '%s\t | %s\t%s (%s, 13) - (%s, 39) `%s`' "$1" "$2" "$3" "$4" "$4" "$5"
}

write_cache() { # write_cache <dump-format lines on stdin>
  "$SYNAPSE_BIN" tags-cache --load "$CACHE"
}

cache_entry() { # cache_entry <path> <hash40> <tags>
  printf 'H\t%s\t%s\n' "$1" "$2"
  printf 'P\t%s\n' "$1"
  [ -z "$3" ] || printf '%s\n' "$3" | while IFS= read -r l; do printf 'T\t%s\t%s\n' "$1" "$l"; done
}

H1="1111111111111111111111111111111111111111"

seed_index() {
  local d
  d="$(tagline 'doThing   ' 'method ' 'def' 10 'public void doThing() {')"
  cache_entry "src/A.bb" "$H1" "$d" | write_cache
  "$SYNAPSE_BIN" build-refs --cache "$CACHE" --out "$INDEX" 2>/dev/null
}

run_callers() {
  cd "$REPO" || return 1
  PATH="$FAKE_BIN:$PATH" SYNAPSE_WORK_DIR="$WORK_DIR" "$SYNAPSE_BIN" callers "$@"
}

# The whole point of dispatching before the preamble. If this regresses, callers
# starts failing in exactly the repos it is most useful in.
@test "callers: needs no vault, no namespace and no nodes" {
  seed_index
  rm -f "$HOME/.claude/synapse.conf"
  rm -rf "$VAULT"
  run run_callers doThing
  [ "$status" -eq 0 ]
}
