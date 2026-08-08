#!/usr/bin/env bats
# Tests claude/bin/synapse.sh -- the porcelain over the claude/lib/synapse/
# plumbing scripts. This is dispatch only: it adds no behavior of its own
# beyond finding the right script and passing arguments through, so these
# tests are about the dispatch mechanism itself, not re-testing what each
# plumbing script does (that's covered in its own file).

load 'test_helper'

SYNAPSE_SH="$REPO_ROOT/claude/bin/synapse.sh"

setup() {
  common_setup
  make_repo
}

teardown() {
  common_teardown
}

run_synapse() {
  cd "$REPO" || return 1
  "$SYNAPSE_SH" "$@"
}

@test "no subcommand: usage error, exit 2" {
  run run_synapse
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage: synapse.sh"* ]]
}

@test "--help and -h: print usage and exit 0" {
  run run_synapse --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: synapse.sh"* ]]

  run run_synapse -h
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: synapse.sh"* ]]
}

@test "an unknown subcommand names itself and exits 2" {
  run run_synapse nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown subcommand 'nope'"* ]]
  [[ "$output" == *"Usage: synapse.sh"* ]]
}

@test "synapse-identity.sh is not a reachable subcommand -- it is sourced, never executed" {
  run run_synapse identity
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown subcommand 'identity'"* ]]
}

@test "dispatches to the real installed script, not the repo copy" {
  mkdir -p "$HOME/.claude/lib/synapse"
  cp "$REPO_ROOT/claude/lib/synapse/synapse-identity.sh" "$HOME/.claude/lib/synapse/synapse-identity.sh"
  # A sentinel copy of build-index standing in for "the installed one" --
  # different output from the real script proves dispatch used this path,
  # not $REPO_ROOT/claude/lib/synapse/synapse-build-index.sh directly.
  cat > "$HOME/.claude/lib/synapse/synapse-build-index.sh" <<'EOF'
#!/bin/bash
echo "SENTINEL: installed copy ran"
EOF
  chmod +x "$HOME/.claude/lib/synapse/synapse-build-index.sh"

  run run_synapse build-index
  [ "$status" -eq 0 ]
  [[ "$output" == *"SENTINEL: installed copy ran"* ]]
}

@test "a missing target script is exit 1, naming the fix" {
  # $HOME/.claude/lib/synapse deliberately left empty -- nothing installed.
  run run_synapse vocab
  [ "$status" -eq 1 ]
  [[ "$output" == *"synapse-vocab.sh not found"* ]]
  [[ "$output" == *"run setup.sh"* ]]
}

@test "arguments after the subcommand pass through unchanged" {
  mkdir -p "$HOME/.claude/lib/synapse"
  cat > "$HOME/.claude/lib/synapse/synapse-query.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$@"
EOF
  chmod +x "$HOME/.claude/lib/synapse/synapse-query.sh"

  run run_synapse query stale --foo "bar baz"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "stale" ]
  [ "${lines[1]}" = "--foo" ]
  [ "${lines[2]}" = "bar baz" ]
}

@test "SYNAPSE_LIB_DIR set in synapse.conf is honoured, not just the exported env var" {
  local custom="$TEST_HOME/custom-lib"
  mkdir -p "$custom"
  cat > "$custom/synapse-gate.sh" <<'EOF'
#!/bin/bash
echo "SENTINEL: custom SYNAPSE_LIB_DIR"
EOF
  chmod +x "$custom/synapse-gate.sh"

  cat >> "$HOME/.claude/synapse.conf" <<EOF
SYNAPSE_LIB_DIR="$custom"
EOF

  run run_synapse gate
  [ "$status" -eq 0 ]
  [[ "$output" == *"SENTINEL: custom SYNAPSE_LIB_DIR"* ]]
}

@test "an explicitly exported SYNAPSE_LIB_DIR overrides the default without needing synapse.conf" {
  local custom="$TEST_HOME/custom-lib2"
  mkdir -p "$custom"
  cat > "$custom/synapse-rank.sh" <<'EOF'
#!/bin/bash
echo "SENTINEL: exported override"
EOF
  chmod +x "$custom/synapse-rank.sh"

  run env SYNAPSE_LIB_DIR="$custom" bash -c 'cd "$1" && shift && "$@"' _ "$REPO" "$SYNAPSE_SH" rank
  [ "$status" -eq 0 ]
  [[ "$output" == *"SENTINEL: exported override"* ]]
}
