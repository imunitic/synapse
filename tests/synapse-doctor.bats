#!/usr/bin/env bats
# Tests `synapse doctor` -- the one command that speaks where the rest of the system
# deliberately stays silent.
#
# The tests below are shaped by that: each one breaks a precondition some other
# component tolerates without a word, and asserts that this command names it. A test
# here that did not correspond to a silent failure elsewhere would be testing a check
# nobody needed.

load 'test_helper'

setup() {
  common_setup
  setup_fake_obsidian_plugin
  CURL_LOG="$TEST_HOME/curl.log"
  : > "$CURL_LOG"
}

teardown() {
  common_teardown
}

run_doctor() {
  # The fake curl stands in for Obsidian, so the reachability check has something to
  # answer it. Without it the check is a genuine failure rather than a test artefact.
  PATH="$FAKE_BIN:$PATH" FAKE_CURL_LOG="$CURL_LOG" FAKE_CURL_VAULT_DIR="$VAULT" \
    bash -c 'cd "$1" && shift && exec "$@"' _ "$REPO" "$SYNAPSE_BIN" doctor
}

@test "a configured machine reports the vault, the namespace and the API" {
  make_repo
  run run_doctor
  [[ "$output" == *"ok"*"config"* ]]
  [[ "$output" == *"$VAULT"* ]]
  [[ "$output" == *"$(repo_name)"* ]]
  [[ "$output" == *"127.0.0.1:"* ]]
}

@test "config resolves at tier 1 (XDG), not just tier 2 -- the config check used to hardcode ~/.claude" {
  make_repo
  mkdir -p "$HOME/.config/synapse"
  mv "$HOME/.claude/synapse.conf" "$HOME/.config/synapse/synapse.conf"
  run env -u XDG_CONFIG_HOME bash -c 'cd "$1" && shift && exec "$@"' _ "$REPO" "$SYNAPSE_BIN" doctor
  [[ "$output" == *"ok    config"*".config/synapse/synapse.conf"* ]]
  [[ "$output" != *"FAIL"*"config"* ]]
}

@test "no vault configured is a failure, and says where to set it" {
  make_repo
  rm -f "$HOME/.claude/synapse.conf"
  # The state every hook treats as silence and every command as a bare "no vault".
  run env -u OBSIDIAN_VAULT_DIR bash -c 'cd "$1" && shift && exec "$@"' _ "$REPO" "$SYNAPSE_BIN" doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL"*"config"* ]]
  [[ "$output" == *"synapse.conf"* ]]
}

@test "a vault path that does not exist is named as such, not reported as absent" {
  make_repo
  printf 'OBSIDIAN_VAULT_DIR="%s/nope"\n' "$TEST_HOME" > "$HOME/.claude/synapse.conf"
  run run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not exist"* ]]
}

@test "an absent namespace is a warning, not a failure" {
  # The distinction the whole three-level scheme exists for: a branch nobody has
  # clustered is an ordinary state, so this must not fail a scripted check.
  make_repo
  run run_doctor
  [[ "$output" == *"warn"*"graph"* ]]
  [[ "$output" == *"/synapse-init"* ]]
}

@test "a namespace whose remote disagrees is a failure that names the remedy" {
  make_repo
  write_synapse_index "$(repo_name)" "ssh://git@elsewhere.invalid/other.git"
  # The exact case the SessionStart hook skips a pointer for and the staleness hook
  # refuses to write on -- both without a word.
  run run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"remote mismatch"* ]]
  [[ "$output" == *"/synapse-rebuild-full"* ]]
}

@test "a namespace whose branch field disagrees is a failure" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  sed_i 's/^branch: .*/branch: some-other-branch/' "$VAULT/synapse/$(repo_name)/Index.md"
  run run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"branch mismatch"* ]]
}

@test "an absent reverse index says what stops working without it" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  run run_doctor
  [[ "$output" == *"warn"*"reverse index"* ]]
  [[ "$output" == *"staleness hook does nothing"* ]]
}

@test "a staged reverse index is reported with its counts" {
  make_repo
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  printf 'src/foo.ml\tFoo.md\n' | write_index_bin "$(default_work_dir)"
  run run_doctor
  [[ "$output" == *"ok"*"reverse index"* ]]
  [[ "$output" == *"1 paths"* ]]
}

# The silent failure these mirror: a grammar lock nobody holds costs every later run
# the full ~60s wait before skipping that extension, and the only symptom is tagging
# that quietly stopped covering one language.
run_doctor_with_grammars() {
  PATH="$FAKE_BIN:$PATH" FAKE_CURL_LOG="$CURL_LOG" FAKE_CURL_VAULT_DIR="$VAULT" \
    SYNAPSE_GRAMMARS_DIR="$1" \
    bash -c 'cd "$1" && shift && exec "$@"' _ "$REPO" "$SYNAPSE_BIN" doctor
}

@test "a recent grammar lock warns and names the directory to delete" {
  make_repo
  mkdir -p "$TEST_HOME/grammars/repos/tree-sitter-ocaml.lock"

  run run_doctor_with_grammars "$TEST_HOME/grammars"
  [[ "$output" == *"warn"*"grammar locks"* ]]
  [[ "$output" == *"tree-sitter-ocaml.lock"* ]]
  # Naming the path is the whole point: the condition is a directory to remove, and
  # the failure it causes elsewhere reads as a network problem.
  [[ "$output" == *"delete it if nothing is running"* ]]
}

@test "a grammar lock past the staleness window is reported as self-healing" {
  make_repo
  mkdir -p "$TEST_HOME/grammars/repos/tree-sitter-ocaml.lock"
  touch -t 202601010000 "$TEST_HOME/grammars/repos/tree-sitter-ocaml.lock"

  run run_doctor_with_grammars "$TEST_HOME/grammars"
  [[ "$output" == *"ok"*"grammar locks"* ]]
  [[ "$output" == *"takes it over"* ]]
}

@test "no grammar lock says nothing at all" {
  make_repo
  mkdir -p "$TEST_HOME/grammars/repos/tree-sitter-ocaml"

  run run_doctor_with_grammars "$TEST_HOME/grammars"
  [[ "$output" != *"grammar locks"* ]]
}

@test "hooks wired to a wrapper are a failure, because the wrapper would still run" {
  make_repo
  mkdir -p "$HOME/.claude"
  cat > "$HOME/.claude/settings.json" <<'EOF'
{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"bash ~/.claude/hooks/synapse-staleness.sh"}]}]}}
EOF
  run run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"still names a hooks/"* ]]
}

@test "a hook registered twice is a failure that says it fires twice" {
  make_repo
  mkdir -p "$HOME/.claude/bin"
  touch "$HOME/.claude/bin/synapse-hook"
  chmod +x "$HOME/.claude/bin/synapse-hook"
  cat > "$HOME/.claude/settings.json" <<'EOF'
{"hooks":{"PostToolUse":[
  {"hooks":[{"type":"command","command":"~/.claude/bin/synapse-hook staleness"}]},
  {"hooks":[{"type":"command","command":"~/.claude/bin/synapse-hook staleness"}]}],
 "SessionStart":[{"hooks":[{"type":"command","command":"~/.claude/bin/synapse-hook session-start"}]}],
 "UserPromptSubmit":[{"hooks":[{"type":"command","command":"~/.claude/bin/synapse-hook prompt-context"}]}],
 "Stop":[{"hooks":[{"type":"command","command":"~/.claude/bin/synapse-hook stop-nudge"}]}]}}
EOF
  # db-sync is deliberately absent as well, but the duplicate is the louder problem and
  # is what the message must name -- a hook firing twice produces duplicated context
  # nobody attributes to settings.json.
  run run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"more than once"* ]]
}

@test "a plugin install with hooks.json present reports ok, not the legacy-shape failures" {
  # A healthy plugin install has neither ~/.claude/bin/synapse-hook nor a
  # settings.json hook merge -- hooks.json is loaded straight from the
  # plugin cache instead. Before hookChecks learned to tell the two install
  # shapes apart, this exact state reported three false failures.
  make_repo
  version_dir="$HOME/.claude/plugins/cache/synapse/synapse/2026-08-1"
  mkdir -p "$version_dir/hooks"
  touch "$version_dir/hooks/hooks.json"

  run run_doctor
  [[ "$output" == *"ok    hooks"*"plugin install"* ]]
  [[ "$output" != *"hook binary"* ]]
}

@test "a stray file in the plugin cache dir (macOS .DS_Store, seen live) is never mistaken for the version dir" {
  # Caught live on a real machine: Finder had been opened to this exact
  # path, dropping a .DS_Store file there, and pluginVersionDir() took
  # whatever directory-iteration order handed it first -- the file, not
  # the real version directory -- reporting a false "hooks.json is
  # missing" failure against a perfectly healthy install.
  make_repo
  cache_dir="$HOME/.claude/plugins/cache/synapse/synapse"
  mkdir -p "$cache_dir"
  touch "$cache_dir/.DS_Store"
  version_dir="$cache_dir/2026-08_9"
  mkdir -p "$version_dir/hooks"
  touch "$version_dir/hooks/hooks.json"

  run run_doctor
  [[ "$output" == *"ok    hooks"*"2026-08_9"* ]]
  [[ "$output" != *"FAIL  hooks"* ]]
}

@test "the newest of several coexisting version dirs wins by number, not lexicographically" {
  # Caught live: a real install had 2026-08_9, 2026-08_12 and 2026-08_13
  # coexisting (releases accumulate; nothing prunes old ones), and
  # pluginVersionDir()'s plain lexicographic max picked 2026-08_9 as
  # "newest" -- '9' outranks '1' at the first differing byte, even though
  # 9 < 12 < 13 numerically. Only the numerically-newest dir gets a real
  # hooks.json here, so a lexicographic pick would report FAIL, not the ok
  # this test actually asserts.
  make_repo
  cache_dir="$HOME/.claude/plugins/cache/synapse/synapse"
  mkdir -p "$cache_dir/2026-08_9/hooks" "$cache_dir/2026-08_12/hooks"
  touch "$cache_dir/2026-08_9/hooks/hooks.json" "$cache_dir/2026-08_12/hooks/hooks.json"
  version_dir="$cache_dir/2026-08_13"
  mkdir -p "$version_dir/hooks"
  touch "$version_dir/hooks/hooks.json"

  run run_doctor
  [[ "$output" == *"ok    hooks"*"2026-08_13"* ]]
  [[ "$output" != *"2026-08_9/hooks"* ]]
  [[ "$output" != *"2026-08_12/hooks"* ]]
}

@test "a plugin install missing hooks.json is a failure that names the version dir" {
  make_repo
  version_dir="$HOME/.claude/plugins/cache/synapse/synapse/2026-08-1"
  mkdir -p "$version_dir"

  run run_doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL"*"hooks"*"hooks/hooks.json is missing"* ]]
}

@test "outside a git repo it warns rather than failing" {
  # `doctor` is the one command someone runs when they do not know what is wrong, so it
  # has to answer everywhere -- including from a directory that is not a checkout.
  mkdir -p "$TEST_HOME/plain"
  run bash -c 'cd "$1" && shift && exec "$@"' _ "$TEST_HOME/plain" "$SYNAPSE_BIN" doctor
  [[ "$output" == *"warn"*"repository"* ]]
  [[ "$output" == *"not inside a git repo"* ]]
}

@test "every line carries a status, and the tally matches the lines" {
  make_repo
  run run_doctor
  local lines statuses
  lines="$(printf '%s\n' "$output" | grep -cE '^(ok|warn|FAIL) ')"
  statuses="$(printf '%s\n' "$output" | sed -n 's/^\([0-9]*\) ok, \([0-9]*\) warning(s), \([0-9]*\) failure(s)$/\1 \2 \3/p')"
  [ -n "$statuses" ]
  # shellcheck disable=SC2086
  set -- $statuses
  [ "$(( $1 + $2 + $3 ))" -eq "$lines" ]
}

@test "--help works outside a repo and with no environment at all" {
  # Asserted here as well as in the generator, because this is the command a broken
  # machine reaches for first.
  run env -i PATH="$PATH" "$SYNAPSE_BIN" doctor --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"usage: synapse doctor"* ]]
}
