#!/usr/bin/env bats
# Tests claude/lib/synapse/synapse-tags.sh -- now a one-line shim over
# `synapse tags` in the Zig binary. The contract it asserts is unchanged: an
# extension is looked up in the Synapse grammar registry and, if usable, its
# grammar is cloned on first use and the file's tags are printed.
#
# What changed underneath is what the fakes are. tree-sitter is linked rather
# than spawned, so `tests/fixtures/fake-bin/tree-sitter` no longer intercepts
# anything and is not on the path these tests take at all; the binary under
# test is `synapse-fake`, which is the same app with only the grammar
# compile-and-load step stubbed (see src/apps/synapse/main_fake.zig). Registry
# resolution, the exit-code contract, warnings, negative caching, and the
# clone with its lock are all real code here. `fake-bin/git` still intercepts
# the clone, because a compiled binary spawns `git` exactly as the shell script
# did.
#
# Not covered here, deliberately: compiling a cloned grammar and running its
# `tags.scm`. That needs a C toolchain and a real grammar repository, which is
# what `ci/differential-tags.sh` provides -- it checks the real tagger against
# the `tree-sitter` CLI over real repositories, which bats could not do.

load 'test_helper'

SCRIPT="$REPO_ROOT/claude/lib/synapse/synapse-tags.sh"

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
    "$SCRIPT" "$@"
}

# bats merges stderr into $output, and every per-extension warning this script
# prints goes there. A test asserting on *tags* has to drop those first, or a
# warning counts as output.
without_warnings() { grep -v '^synapse-tags:' <<< "$1" || true; }

@test "file with no extension: exits 1" {
  printf 'no extension here\n' > "$TEST_HOME/noext"
  write_registry '{}'

  run run_synapse_tags "$TEST_HOME/noext"
  [ "$status" -eq 1 ]
}

@test "extension has no registry entry at all: exits 2 (needs discovery), no clone attempted" {
  printf 'let x = 1\n' > "$TEST_HOME/sample.ml"
  write_registry '{}'

  run run_synapse_tags "$TEST_HOME/sample.ml"
  [ "$status" -eq 2 ]
  [ ! -s "$FAKE_GIT_LOG" ]
}

@test "extension marked unsupported: exits 1, no clone attempted" {
  printf 'fn main() {}\n' > "$TEST_HOME/sample.rs"
  write_registry '{"rs": {"unsupported": true}}'

  run run_synapse_tags "$TEST_HOME/sample.rs"
  [ "$status" -eq 1 ]
  [ ! -s "$FAKE_GIT_LOG" ]
}

@test "known, never-cloned extension: clones the grammar, prints tags, exit 0" {
  printf 'let x = 1\n' > "$TEST_HOME/sample.ml"
  write_registry '{"ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}'

  run run_synapse_tags "$TEST_HOME/sample.ml"
  [ "$status" -eq 0 ]
  [[ "$output" == *"FAKE_NAME"* ]]

  grep -q "clone" "$FAKE_GIT_LOG"
  [ -d "$GRAMMARS_DIR/repos/tree-sitter-ocaml" ]
}

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
    SYNAPSE_GRAMMAR_LOCK_TRIES=3 "$SCRIPT" "$TEST_HOME/sample.ml"
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

@test "grammar already cloned: does not clone again" {
  printf 'let x = 1\n' > "$TEST_HOME/sample.ml"
  write_registry '{"ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}'
  mkdir -p "$GRAMMARS_DIR/repos/tree-sitter-ocaml"

  run run_synapse_tags "$TEST_HOME/sample.ml"
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_GIT_LOG" ]
}

@test "a second file of the same extension resolves the grammar once, not twice" {
  # Replaces the deleted "the extension scan forks nothing per file", which
  # asserted the absence of a `basename` call in a script that no longer
  # exists. The property that mattered survives the port and is now assertable
  # directly rather than by grepping the implementation: per-extension work
  # happens once per extension, however many files carry it.
  printf 'let a = 1\n' > "$TEST_HOME/a.ml"
  printf 'let b = 2\n' > "$TEST_HOME/b.ml"
  printf '%s\n' "$TEST_HOME/a.ml" "$TEST_HOME/b.ml" > "$TEST_HOME/list.txt"
  write_registry '{"ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}'

  run run_synapse_tags --paths "$TEST_HOME/list.txt"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^clone ' "$FAKE_GIT_LOG")" -eq 1 ]
}

@test "--paths: one tagging pass for the whole list, output attributable" {
  # The point of batch mode: per-file setup dominated the old CLI's cost, so N
  # files must cost ONE pass. The binary spawns nothing to count, so the fake
  # backend records what it was asked instead -- one `tags` line per
  # invocation, one `path` line per file.
  printf 'let a = 1\n' > "$TEST_HOME/a.ml"
  printf 'let b = 2\n' > "$TEST_HOME/b.ml"
  printf 'let c = 3\n' > "$TEST_HOME/c.ml"
  printf '%s\n' "$TEST_HOME/a.ml" "$TEST_HOME/b.ml" "$TEST_HOME/c.ml" > "$TEST_HOME/list.txt"
  write_registry '{"ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}'

  run run_synapse_tags --paths "$TEST_HOME/list.txt"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^tags ' "$FAKE_TS_LOG")" -eq 1 ]
  [ "$(grep -c '^path ' "$FAKE_TS_LOG")" -eq 3 ]
  # Attributable: a path line, then that path's tab-indented tags.
  [ "$(grep -c '^/' <<< "$output")" -eq 3 ]
  [ "$(grep -c '^	' <<< "$output")" -eq 3 ]
}

@test "--paths: an extension with no grammar is warned ONCE, and the rest still tag" {
  # One line per extension, not tree-sitter's eight lines per file, which is
  # unreadable at repo scale. And a missing grammar must not fail the batch: a
  # mixed repo nearly always has some language that works.
  printf 'let a = 1\n' > "$TEST_HOME/a.ml"
  printf 'x\n' > "$TEST_HOME/one.zzz"
  printf 'y\n' > "$TEST_HOME/two.zzz"
  printf '%s\n' "$TEST_HOME/a.ml" "$TEST_HOME/one.zzz" "$TEST_HOME/two.zzz" > "$TEST_HOME/list.txt"
  write_registry '{"ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}'

  run run_synapse_tags --paths "$TEST_HOME/list.txt"
  [ "$status" -eq 0 ]
  [ "$(grep -c 'no grammar registered for .zzz' <<< "$output")" -eq 1 ]
  [ "$(grep -c '^/' <<< "$output")" -eq 1 ]
}

@test "--paths: a ONE-path list still gets a path line and indented tags" {
  # The real CLI changed shape here: two or more paths got path lines and
  # indentation, exactly one got neither -- bare tags, identical to single-file
  # form. A chunk of one is the common case rather than a corner (one source
  # changed, re-tag it), and left un-normalised an attributing caller reads the
  # first tag line as a path, finds the real path missing, and concludes the
  # file could not be parsed. That shipped once already: it cached a perfectly
  # readable file as `unsupported: true` with no tags. The Zig implementation
  # has no such shape change to normalise away, and this pins that it never
  # grows one.
  printf 'let a = 1\n' > "$TEST_HOME/a.ml"
  printf '%s\n' "$TEST_HOME/a.ml" > "$TEST_HOME/list.txt"
  write_registry '{"ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}'

  run run_synapse_tags --paths "$TEST_HOME/list.txt"
  [ "$status" -eq 0 ]
  [ "$(head -1 <<< "$output")" = "$TEST_HOME/a.ml" ]
  [ "$(grep -c '^	' <<< "$output")" -eq 1 ]
  [[ "$output" == *"FAKE_NAME"* ]]
}

@test "--paths: one path and many paths produce the same shape per file" {
  # Asserted as an equivalence rather than two separate expectations, so the
  # normalisation cannot drift in only one direction.
  printf 'let a = 1\n' > "$TEST_HOME/a.ml"
  printf 'let b = 2\n' > "$TEST_HOME/b.ml"
  write_registry '{"ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}'

  printf '%s\n' "$TEST_HOME/a.ml" > "$TEST_HOME/one.txt"
  run run_synapse_tags --paths "$TEST_HOME/one.txt"
  [ "$status" -eq 0 ]
  local alone="$output"

  printf '%s\n%s\n' "$TEST_HOME/a.ml" "$TEST_HOME/b.ml" > "$TEST_HOME/two.txt"
  run run_synapse_tags --paths "$TEST_HOME/two.txt"
  [ "$status" -eq 0 ]
  # a.ml's slice of the two-path output: its path line plus the indented lines
  # up to the next unindented one.
  local together
  together="$(awk -v p="$TEST_HOME/a.ml" '
    $0 == p { on = 1; print; next }
    on && /^\t/ { print; next }
    on { exit }' <<< "$output")"
  [ "$alone" = "$together" ]
}

@test "--paths: a one-path list whose extension has no grammar still exits 1" {
  # The normalisation must not manufacture a path line for a file that was
  # never parseable -- that would turn "no grammar" into "parsed, no tags",
  # which is exactly the distinction `unsupported` rests on.
  printf 'x\n' > "$TEST_HOME/one.zzz"
  printf '%s\n' "$TEST_HOME/one.zzz" > "$TEST_HOME/list.txt"
  write_registry '{}'

  run run_synapse_tags --paths "$TEST_HOME/list.txt"
  [ "$status" -eq 1 ]
  [ -z "$(without_warnings "$output")" ]
}

@test "--paths: no usable grammar for anything in the list exits 1" {
  printf 'x\n' > "$TEST_HOME/one.zzz"
  printf '%s\n' "$TEST_HOME/one.zzz" > "$TEST_HOME/list.txt"
  write_registry '{}'

  run run_synapse_tags --paths "$TEST_HOME/list.txt"
  [ "$status" -eq 1 ]
}

@test "--paths: a missing list file exits 1 rather than tagging nothing quietly" {
  write_registry '{"ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}'
  run run_synapse_tags --paths "$TEST_HOME/nope.txt"
  [ "$status" -eq 1 ]
  [ ! -s "$FAKE_TS_LOG" ]
}

@test "--list-extensions: the registry's usable entries, one per line, sorted" {
  # The allowlist synapse-vocab.sh and synapse-rank.sh pre-filter with. An
  # entry marked unsupported, or missing repo or scope, is not usable and must
  # not appear -- a caller that tags on the strength of this list would then
  # get a warning per file for a language it was told was available.
  write_registry '{"py": {"repo": "https://example.invalid/tree-sitter-python", "scope": "source.python"},
                   "java": {"repo": "https://example.invalid/tree-sitter-java", "scope": "source.java"},
                   "rs": {"unsupported": true},
                   "go": {"repo": "https://example.invalid/tree-sitter-go"}}'

  run run_synapse_tags --list-extensions
  [ "$status" -eq 0 ]
  [ "$output" = "java
py" ]
}
