#!/usr/bin/env bats
# Tests docs/synapse/generate-cli-reference.sh, and asserts the committed
# docs/synapse/cli.md is current. That second assertion is the point: it turns a
# stale reference into a failing test rather than a document that quietly
# describes a command as it used to be. synapse-bard has its own generator
# (docs/synapse-bard/generate-cli-reference.sh) but no test file of its own yet.
#
# This replaced tests/scripts-reference.bats, whose subject was a generator that
# read the header comment of every claude/lib/synapse/*.sh. Those scripts are gone.
# Several of its tests were about the *extraction* -- a `# Usage` marker, a
# parenthetical after it, an empty fenced block -- and none of that survives:
# there is no comment to extract from, only `--help` itself. What does survive is
# every test about the guarantee, and one that is new and stronger.

load 'test_helper'

GEN="$REPO_ROOT/docs/synapse/generate-cli-reference.sh"

setup() {
  common_setup
}

teardown() {
  common_teardown
}

@test "the committed docs/synapse/cli.md is up to date" {
  run bash "$GEN" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"up to date"* ]]
}

@test "--check fails when a subcommand's help has moved on" {
  # Simulated by editing the committed document rather than the binary: rebuilding
  # a mutated binary inside a test would need a Zig toolchain, which the container
  # deliberately does not have.
  local scratch="$BATS_TEST_TMPDIR/docs"
  mkdir -p "$scratch"
  cp "$REPO_ROOT/docs/synapse/cli.md" "$scratch/cli.md"
  cp "$GEN" "$scratch/generate-cli-reference.sh"

  # The generator finds its output beside itself, so a copy checks the copy.
  run bash -c 'cd "$1" && SYNAPSE_BIN="$2" SYNAPSE_HOOK_BIN="$3" bash ./generate-cli-reference.sh --check' \
    _ "$scratch" "$SYNAPSE_BIN" "$SYNAPSE_HOOK_BIN"
  [ "$status" -eq 0 ]

  printf 'a line the binaries never print\n' >> "$scratch/cli.md"
  run bash -c 'cd "$1" && SYNAPSE_BIN="$2" SYNAPSE_HOOK_BIN="$3" bash ./generate-cli-reference.sh --check' \
    _ "$scratch" "$SYNAPSE_BIN" "$SYNAPSE_HOOK_BIN"
  [ "$status" -eq 1 ]
  [[ "$output" == *"out of date"* ]]
}

@test "every subcommand contributes a section, and no fenced block is empty" {
  local doc="$REPO_ROOT/docs/synapse/cli.md"
  # The listing in `synapse --help` is the authority on what exists, so the two
  # cannot disagree without this failing.
  local subs
  subs="$("$SYNAPSE_BIN" --help 2>&1 | sed -n 's/^  \([a-z][a-z-]*\) .*/\1/p' | awk '!seen[$0]++')"
  [ -n "$subs" ]

  local sub
  while read -r sub; do
    [ -n "$sub" ] || continue
    grep -qxF "### synapse $sub" "$doc"
  done <<< "$subs"

  grep -qxF "## synapse-hook" "$doc"

  # An opening fence followed immediately by its closing fence: the failure mode the
  # old generator actually produced when its marker did not match, and it rendered as
  # perfectly plausible markdown.
  run awk '/^```$/ { if (prev == "```") { print "empty fence at line " NR; exit 1 } } { prev = $0 }' "$doc"
  [ "$status" -eq 0 ]
}

@test "every fence stands on its own line, so no help text escapes its block" {
  # THE FAILURE THIS EXISTS FOR, and the reason it is a separate property from
  # `--check`. `$(...)` strips trailing newlines, so a closing fence printed
  # directly after the help text landed on its last line and closed nothing. Every
  # block from there on opened where it should have closed -- and `write-node`'s
  # own usage line, `--summary <s>`, then reached the renderer as an HTML <s> tag
  # with no `</s>` after it, striking through the rest of the page.
  #
  # `--check` passed throughout: the committed document matched the generator byte
  # for byte. Both were wrong together, which is exactly what a test comparing them
  # to each other cannot see. This one asserts a property of the document itself.
  local doc="$REPO_ROOT/docs/synapse/cli.md"

  run grep -nE '.```|```.' "$doc"
  [ "$status" -eq 1 ]

  local fences
  fences="$(grep -c '^```$' "$doc")"
  [ "$(( fences % 2 ))" -eq 0 ]

  # Nothing that a renderer reads as a tag survives outside a block. The angle
  # brackets in `<file>`, `<node>` and `<s>` are only safe while fenced.
  run awk '/^```$/ { f = !f; next } !f && /<[a-zA-Z\/]/ { print NR ": " $0; bad = 1 } END { exit bad }' "$doc"
  [ "$status" -eq 0 ]
}

@test "the generated help is what the binary actually prints" {
  # The guarantee, checked end to end rather than trusted: one subcommand's block in
  # the document, byte for byte against a live `--help`.
  local from_binary
  from_binary="$("$SYNAPSE_BIN" query --help 2>&1)"
  local last_line
  last_line="$(printf '%s' "$from_binary" | grep -v '^[[:space:]]*$' | tail -1)"
  [ -n "$last_line" ]
  grep -qF "$last_line" "$REPO_ROOT/docs/synapse/cli.md"
}

@test "a --help that needs an environment fails the generator" {
  # The property that keeps one machine's paths out of a committed document. Proved
  # by giving the generator a 'binary' that only answers when a variable is set --
  # which is what a subcommand resolving a namespace before printing usage does.
  local scratch="$BATS_TEST_TMPDIR/env"
  mkdir -p "$scratch"
  cp "$GEN" "$scratch/generate-cli-reference.sh"
  cat > "$scratch/needy" <<'EOF'
#!/bin/bash
[ -n "${SOME_REQUIRED_VAR:-}" ] || exit 1
echo "usage: needy"
EOF
  chmod +x "$scratch/needy"

  run bash -c 'cd "$1" && SYNAPSE_BIN="$1/needy" SYNAPSE_HOOK_BIN="$1/needy" bash ./generate-cli-reference.sh' \
    _ "$scratch"
  [ "$status" -eq 1 ]
  [[ "$output" == *"without an environment"* ]]
}

@test "a bad flag exits 2 with usage" {
  run bash "$GEN" --nonsense
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
}
