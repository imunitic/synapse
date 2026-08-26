#!/usr/bin/env bats
# THE MIGRATION GUARD: nothing this project ships to a model, or emits into one's
# context, may name a command that does not exist.
#
# Written after the Zig rewrite left residue that every other test was blind to. The
# UserPromptSubmit hook injected `synapse-query.sh (body/sources/field/links)` and
# `synapse.sh callers <name>` into every turn in an initialised repo, months after
# both wrappers were deleted -- and tests/synapse-prompt-context.bats asserted the
# string `synapse-query.sh` was present, so the suite was protecting the stale
# instruction rather than catching it. A skill's table named `synapse query callers`,
# which has never been a command in either implementation.
#
# The lesson generalises past those instances: a rename is only finished when it is
# checked mechanically, and the check has to look at the *class*, not the instances.
# There are three places a command name can be wrong, so there are three tests:
# shipped instruction files, the text the hooks inject, and the documents the
# binaries generate.
#
# Two rules, and both of them apply to all three places. The first is a text search
# for a deleted shell entry point; the second is the half a text search cannot do --
# resolving `synapse <sub>` against the binary's own `--help`, which is what catches
# a name spelled entirely in current vocabulary that has never been a command. For a
# while only the first rule reached the hook text and the generated index, while the
# README claimed both did. `synapse query callers` in an injected nudge would have
# shipped green.

load 'test_helper'

setup() {
  common_setup
  setup_fake_obsidian_plugin
  CURL_LOG="$TEST_HOME/curl.log"
  : > "$CURL_LOG"
  WORK="$TEST_HOME/work"
  mkdir -p "$WORK/lists"
}

teardown() {
  common_teardown
}

# A node, as the writer would leave it: enough frontmatter for the index builder to
# read a summary back off it.
stage_node() {
  local title="$1" summary="$2"
  mkdir -p "$VAULT/synapse/$(repo_name)"
  cat > "$VAULT/synapse/$(repo_name)/$title.md" <<EOF
---
title: "$title"
summary: "$summary"
node_type: synapse-node
project: $(repo_name)
sources:
  - path: src/foo.aa
    hash: y
sources_digest: deadbeef
stale: false
built_at: "2026-01-01 00:00"
---

# $title
<!-- synapse:generated:start -->
body
<!-- synapse:generated:end -->

## Notes
EOF
}

# Every file installed into ~/.claude that a model reads as instructions.
# synapse's own shipped instructions only -- plugins/synapse-bard/ has its
# own commands/skills now but this check's unknown_commands() below is
# hardcoded to $SYNAPSE_BIN's own subcommand vocabulary, so scanning bard's
# docs here would need that generalized first, not just this path updated.
shipped_instructions() {
  find "$REPO_ROOT/packages/synapse" -name '*.md' -type f
}

# The shell entry points the rewrite deleted. Matched with a trailing `.sh` so this
# never fires on the binary's own subcommands, and so a source comment recording
# provenance ("the port of synapse-tags-cache.sh") stays legal -- comments are
# history and belong in the code, but nothing a model or a user is told to run may
# name one.
readonly LEGACY='(synapse|second-brain)[a-z-]*\.sh'

# Every `synapse <sub>` and `synapse query <sub>` in the text on stdin that the
# binary does not actually have, one per line. Empty output means clean.
#
# Only backticked mentions count. Prose runs the two words together often enough
# ("consult synapse query before grepping") that matching bare text would flag
# sentences rather than commands.
unknown_commands() {
  local text subs qsubs bad="" cmd
  text="$(cat)"
  subs="$("$SYNAPSE_BIN" --help 2>&1 | sed -n 's/^  \([a-z][a-z-]*\) .*/\1/p' | sort -u)"
  qsubs="$("$SYNAPSE_BIN" query --help 2>&1 | sed -n 's/^  \([a-z][a-z-]*\) .*/\1/p' | sort -u)"
  # A --help that parsed to nothing would make every check below vacuously pass,
  # which is the one way this guard could fail silently.
  [ -n "$subs" ] || { echo "  (synapse --help listed no subcommands)"; return; }
  [ -n "$qsubs" ] || { echo "  (synapse query --help listed no subcommands)"; return; }

  while read -r cmd; do
    [ -n "$cmd" ] || continue
    grep -qx "$cmd" <<< "$qsubs" || bad="$bad  synapse query $cmd"$'\n'
  done <<< "$(grep -hoE '`synapse query [a-z][a-z-]+' <<< "$text" | sed 's/.*query //' | sort -u)"

  while read -r cmd; do
    [ -n "$cmd" ] || continue
    grep -qx "$cmd" <<< "$subs" || bad="$bad  synapse $cmd"$'\n'
  done <<< "$(grep -hoE '`synapse [a-z][a-z-]+' <<< "$text" | sed 's/.*`synapse //' | sort -u)"

  printf '%s' "$bad"
}

@test "no shipped instruction names a deleted shell entry point" {
  local hits
  hits="$(shipped_instructions | xargs grep -nE "$LEGACY" || true)"
  [ -z "$hits" ] || {
    echo "shipped instructions naming a deleted script:" >&2
    echo "$hits" >&2
    false
  }
}

@test "every 'synapse <sub>' a shipped instruction names is a real subcommand" {
  # The half a text search cannot do: `synapse query callers` is spelled entirely in
  # current vocabulary and is still not a command.
  local bad
  bad="$(shipped_instructions | xargs cat | unknown_commands)"
  [ -z "$bad" ] || {
    echo "shipped instructions naming a command the binary does not have:" >&2
    printf '%s' "$bad" >&2
    false
  }
}

@test "no context a hook injects names a script or command that does not exist" {
  # The instance that shipped: this is the only one of the three checks that would
  # have caught it, because the string was in a Zig source and not in any document.
  make_repo "git@github.com:example/repo.git"
  write_synapse_index "$(repo_name)" "$(repo_remote_or_path)"
  stage_node "Query API" "Conditions and validation."
  printf 'src/foo.aa\tQuery API.md\n' | write_index_bin "$(default_work_dir)"

  # A filled reference index as well, so the branch of the nudge that only appears
  # with a Code Cache is exercised rather than skipped -- that branch is where
  # `synapse.sh callers` was.
  printf 'foo\tdef\tfunction\tsrc/foo.aa\t1\tlet foo x =\n' > "$(default_work_dir)/_refs.tsv"

  local input="$BATS_TEST_TMPDIR/in.json"
  local emitted=""

  jq -n --arg cwd "$REPO" '{prompt: "how does Query API validate", cwd: $cwd}' > "$input"
  emitted="$emitted$(PATH="$FAKE_BIN:$PATH" FAKE_CURL_VAULT_DIR="$VAULT" \
    "$SYNAPSE_HOOK_BIN" prompt-context < "$input" 2>&1 || true)"

  jq -n --arg cwd "$REPO" '{cwd: $cwd}' > "$input"
  emitted="$emitted$(PATH="$FAKE_BIN:$PATH" FAKE_CURL_VAULT_DIR="$VAULT" \
    "$SYNAPSE_HOOK_BIN" session-start < "$input" 2>&1 || true)"

  jq -n --arg p "$REPO/src/foo.aa" '{tool_input: {file_path: $p}}' > "$input"
  emitted="$emitted$(cd "$REPO" && PATH="$FAKE_BIN:$PATH" FAKE_CURL_VAULT_DIR="$VAULT" \
    "$SYNAPSE_HOOK_BIN" staleness < "$input" 2>&1 || true)"

  [ -n "$emitted" ]
  ! grep -qE "$LEGACY" <<< "$emitted" || {
    echo "a hook injected a deleted script name:" >&2
    grep -oE "[^ ]*$LEGACY" <<< "$emitted" | sort -u >&2
    false
  }

  # And the rule a text search cannot express. The nudge names commands in
  # backticks -- `synapse query symbol`, `synapse callers`, `synapse index lookup`
  # -- so a renamed or never-existing one is exactly as reachable here as it is in
  # a skill, and reaches the model on every turn rather than when a skill is read.
  local bad
  bad="$(unknown_commands <<< "$emitted")"
  [ -z "$bad" ] || {
    echo "a hook injected a command the binary does not have:" >&2
    printf '%s' "$bad" >&2
    false
  }
}

@test "no generated document names a script or command that does not exist" {
  # A real `Index.md`, built by the builder rather than staged as a fixture -- the
  # advice paragraph it emits told every reader to run `synapse-query.sh body <node>`,
  # and it is written into the vault and read back by an agent every session, so it is
  # as model-facing as a skill.
  make_repo "ssh://git@example.com/x/proj.git"
  printf '%s\n' "Query API" > "$WORK/lists/01.title"
  printf '%s\n' src/foo.aa > "$WORK/lists/01.txt"
  stage_node "Query API" "Conditions and validation."

  run env PATH="$FAKE_BIN:$PATH" FAKE_CURL_LOG="$CURL_LOG" FAKE_CURL_VAULT_DIR="$VAULT" \
    FAKE_CURL_PUT_STATUS=200 SYNAPSE_WORK_DIR="$WORK" \
    bash -c 'cd "$1" && shift && exec "$@"' _ "$REPO" "$SYNAPSE_BIN" build-project-index
  [ "$status" -eq 0 ]

  local generated
  generated="$(cat "$VAULT/synapse/$(repo_name)/Index.md")"
  [[ "$generated" == *"Reading a node"* ]]

  ! grep -qE "$LEGACY" <<< "$generated" || {
    echo "a generated document names a deleted script:" >&2
    grep -oE "[^ ]*$LEGACY" <<< "$generated" | sort -u >&2
    false
  }

  # The advice paragraph names four commands in backticks and is read back by an
  # agent every session, so it carries the same risk a skill does -- and unlike a
  # skill, it is written from a Zig string that no documentation review would open.
  local bad
  bad="$(unknown_commands <<< "$generated")"
  [ -z "$bad" ] || {
    echo "a generated document names a command the binary does not have:" >&2
    printf '%s' "$bad" >&2
    false
  }
}
