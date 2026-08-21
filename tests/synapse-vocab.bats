#!/usr/bin/env bats
# Tests claude/lib/synapse/synapse-vocab.sh -- the pass that reduces a whole repo to
# `group <TAB> word <TAB> count` so the clustering step of /synapse-init can
# decide what a subsystem is about from symbol names instead of source lines.
#
# The reduction itself (word splitting, stopwording, the six output tables,
# --lists mode, the tags cache, namespaces.tsv) is covered by
# `src/apps/synapse/vocab_cmd.zig`'s own native tests, calling `build()`
# directly with `fake_grammar.FakeExtractor` against a real git repo. What's
# left here is the CLI layer: usage errors `run()`'s own pre-validation
# rejects before `build()` is ever called, the work-dir default, and running
# outside a git repo.

load 'test_helper'

setup() {
  common_setup
  printf '%s' '{"java": {"repo": "https://example.invalid/tree-sitter-java", "scope": "source.java"},
                "py": {"repo": "https://example.invalid/tree-sitter-python", "scope": "source.python"},
                "ml": {"repo": "https://example.invalid/tree-sitter-ocaml", "scope": "source.ocaml"}}' \
    > "$HOME/.claude/synapse-grammars.conf"
  OUT="$TEST_HOME/out"
}

teardown() {
  common_teardown
}

# A file with the given symbols, one `symbol:` line each. The body is otherwise
# irrelevant: the fake reads only those lines.
src() { # src <repo-relative path> <symbol>...
  local path="$REPO/$1"; shift
  mkdir -p "$(dirname "$path")"
  : > "$path"
  local s
  for s in "$@"; do printf 'symbol:%s\n' "$s" >> "$path"; done
}

# Two modules with deliberately disjoint domain vocabulary, plus one term
# ("Shared") every module uses -- the corpus-common case the quality gate later
# has to be able to see.
make_two_module_repo() {
  git init -q "$REPO"
  src billing/src/InvoiceCalculator.java InvoiceCalculator SharedRegistry
  src billing/src/DunningSchedule.java   DunningSchedule    SharedRegistry
  src shipping/src/ParcelRouter.java     ParcelRouter       SharedRegistry
  src shipping/src/CarrierManifest.java  CarrierManifest    SharedRegistry
  git -C "$REPO" add -A
  git -C "$REPO" -c user.email=test@test -c user.name=test commit -q -m init
}

@test "defaults to the work dir when --out is omitted" {
  make_two_module_repo

  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" vocab --repo "$REPO"
  [ "$status" -eq 0 ]
  [ -s "$HOME/.claude/synapse-work/$(repo_name)/groupwords.tsv" ]
  [ -s "$HOME/.claude/synapse-work/$(repo_name)/counts.tsv" ]
}

@test "outside a git repo: exits 1 with a message, writes nothing" {
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" vocab --repo "$TEST_HOME" --out "$OUT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not inside a git repo"* ]]
  [ ! -f "$OUT/groupwords.tsv" ]
}

@test "a bad flag or a non-numeric depth is a usage error, exit 2" {
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" vocab --nope
  [ "$status" -eq 2 ]
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" vocab --depth two
  [ "$status" -eq 2 ]
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" vocab --depth 0
  [ "$status" -eq 2 ]
}

@test "a bad --distinctive-top or --distinctive-k is a usage error, exit 2" {
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" vocab --distinctive-top zero
  [ "$status" -eq 2 ]
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" vocab --distinctive-top 0
  [ "$status" -eq 2 ]
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" vocab --distinctive-k zero
  [ "$status" -eq 2 ]
  run env PATH="$FAKE_BIN:$PATH" "$SYNAPSE_BIN" vocab --distinctive-k 0
  [ "$status" -eq 2 ]
}
