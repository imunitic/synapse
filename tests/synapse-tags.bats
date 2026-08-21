#!/usr/bin/env bats
# Tests `synapse tags`. It replaced claude/lib/synapse/synapse-tags.sh, which is
# deleted, and the contract is unchanged: an extension is looked up in the
# Synapse grammar registry and, if usable, its grammar is cloned on first use
# and the file's tags are printed.
#
# Registry lookup, tagging, and the CLI's own exit-code contract are covered
# by `src/apps/synapse/tags.zig`'s own native tests, using
# `fake_grammar.FakeExtractor` (compile-and-load stubbed, everything else
# real, including the real `git clone` -- intercepted by
# `tests/fixtures/fake-bin/git`'s own `clone`-only stub). What's left here is
# the grammar lock's real concurrency behavior: a lock is coordination
# between genuinely separate OS processes, which only a real second process
# (this file backgrounds one with `&`) actually exercises -- an in-process
# simulation would test cooperative scheduling within one address space, not
# the real crash/signal semantics the lock exists for.
#
# Not covered here, deliberately: compiling a cloned grammar and running its
# `tags.scm`. That needs a C toolchain and a real grammar repository, which is
# what `ci/differential-tags.sh` provides -- it checks the real tagger against
# the `tree-sitter` CLI over real repositories, which bats could not do.

load 'test_helper'


setup() {
  common_setup
  GRAMMARS_DIR="$TEST_HOME/grammars"
  REGISTRY="$HOME/.claude/synapse-grammars.conf"
  FAKE_TS_LOG="$TEST_HOME/ts.log"
  FAKE_GIT_LOG="$TEST_HOME/git.log"
  : > "$FAKE_TS_LOG"
  : > "$FAKE_GIT_LOG"
}

teardown() {
  common_teardown
}

write_registry() {
  printf '%s' "$1" > "$REGISTRY"
}

# Forwards every argument, not just the first: batch mode is invoked as
# `--paths <list>`, and dropping the second word silently turns that into the
# no-list form, which exits 1 -- a green-looking helper bug that reads as a
# script bug.
run_synapse_tags() {
  PATH="$FAKE_BIN:$PATH" \
    SYNAPSE_GRAMMARS_DIR="$GRAMMARS_DIR" \
    FAKE_TS_LOG="$FAKE_TS_LOG" \
    FAKE_GIT_LOG="$FAKE_GIT_LOG" \
    "$SYNAPSE_BIN" tags "$@"
}

# bats merges stderr into $output, and every per-extension warning this script
# prints goes there. A test asserting on *tags* has to drop those first, or a
# warning counts as output.
# Both prefixes: the extractor says `synapse-tags:`, the grammar layer underneath it
# says `synapse:` (the C++ scanner refusal, the grammar-lock timeout). Either is a
# warning on stderr, and what these assertions are about is that stdout carries no
# tag lines.
without_warnings() { grep -vE '^synapse(-tags)?:' <<< "$1" || true; }

@test "concurrent first clone: a waiter picks up another worker's finished clone instead of racing it" {
  # Simulates two parallel synapse-vocab.sh/-rank.sh chunk workers hitting the
  # same never-before-cloned extension at once. The lock directory existing
  # with no repo directory yet is exactly what a worker mid-clone leaves
  # behind, whether that worker is real or (as here) simulated directly.
  printf 'let x = 1\n' > "$TEST_HOME/sample.ml"
  write_registry '{"ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}'
  mkdir -p "$GRAMMARS_DIR/repos/tree-sitter-ocaml.lock"

  out="$TEST_HOME/waiter.out"
  run_synapse_tags "$TEST_HOME/sample.ml" > "$out" 2>&1 &
  waiter_pid=$!

  # Long enough that a waiter which raced the lock instead of honouring it
  # would already have finished (and logged a clone) by this point.
  sleep 0.5
  kill -0 "$waiter_pid" 2>/dev/null   # still running -- it is waiting, not racing
  [ ! -s "$FAKE_GIT_LOG" ]            # and has made no clone attempt of its own

  # The other worker finishes: repo appears, then its lock is released --
  # the same order ensureCloned's own clone-then-unlock path uses.
  mkdir -p "$GRAMMARS_DIR/repos/tree-sitter-ocaml"
  rmdir "$GRAMMARS_DIR/repos/tree-sitter-ocaml.lock"

  wait "$waiter_pid"
  status=$?
  [ "$status" -eq 0 ]
  [[ "$(cat "$out")" == *"FAKE_NAME"* ]]
  [ ! -s "$FAKE_GIT_LOG" ]   # picked up the finished clone, never cloned itself
}

@test "concurrent first clone: a lock released with no repo means the holder failed -- the waiter clones instead" {
  printf 'let x = 1\n' > "$TEST_HOME/sample.ml"
  write_registry '{"ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}'
  mkdir -p "$GRAMMARS_DIR/repos/tree-sitter-ocaml.lock"

  out="$TEST_HOME/waiter.out"
  run_synapse_tags "$TEST_HOME/sample.ml" > "$out" 2>&1 &
  waiter_pid=$!
  sleep 0.5
  kill -0 "$waiter_pid" 2>/dev/null

  # The other worker's clone failed: lock released, repo never appeared --
  # the waiter must not conclude "someone else has it" forever.
  rmdir "$GRAMMARS_DIR/repos/tree-sitter-ocaml.lock"

  wait "$waiter_pid"
  status=$?
  [ "$status" -eq 0 ]
  [[ "$(cat "$out")" == *"FAKE_NAME"* ]]
  grep -q "clone" "$FAKE_GIT_LOG"   # it had to become the new leader and clone
  [ -d "$GRAMMARS_DIR/repos/tree-sitter-ocaml" ]
}

@test "a wedged lock times out rather than waiting forever, and is left for its actual owner" {
  printf 'let x = 1\n' > "$TEST_HOME/sample.ml"
  write_registry '{"ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}'
  mkdir -p "$GRAMMARS_DIR/repos/tree-sitter-ocaml.lock"

  run env PATH="$FAKE_BIN:$PATH" SYNAPSE_GRAMMARS_DIR="$GRAMMARS_DIR" \
    SYNAPSE_GRAMMAR_LOCK_TRIES=3 "$SYNAPSE_BIN" tags "$TEST_HOME/sample.ml"
  [ "$status" -eq 1 ]
  # A timeout now says so on stderr, where the shell script was silent. That is
  # the one behavioural difference in this file and it is an improvement: the
  # extension is skipped either way, and a run that skips every file for sixty
  # seconds of nothing was previously indistinguishable from a repo with no
  # symbols. Stdout is still empty, which is the part callers parse.
  [ -z "$(without_warnings "$output")" ]
  # A timed-out waiter does not own the lock and must not delete it -- doing
  # so could let a second waiter start cloning while the real (just slow)
  # holder is still working.
  [ -d "$GRAMMARS_DIR/repos/tree-sitter-ocaml.lock" ]
  [ ! -d "$GRAMMARS_DIR/repos/tree-sitter-ocaml" ]
}
