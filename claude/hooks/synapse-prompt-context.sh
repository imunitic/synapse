#!/bin/bash
# UserPromptSubmit hook: on every turn in a repo that has a Synapse namespace,
# state that the namespace exists and name the tools that read it. One short
# standing line -- no search, no node list, no network. Set
# SYNAPSE_DISABLE_PROMPT_INJECTION (any value) to disable entirely.
#
# TWO TOOLS, NOT ONE. The line names the Graph (nodes, the reverse index) and the Code
# Cache (_refs.tsv) as separate things, because they are: the Code Cache is an
# acceleration layer that stands alone, and `callers` answers in a repo where
# clustering has never run. Collapsing both into "read the graph" is what the
# earlier wording did, and it cost a real session -- the reader skimmed node
# titles, saw nothing matching the subject, concluded Synapse did not cover the
# area, and fell back to grep. Every file was indexed; the titles were simply
# misleading about ownership. Hence naming the reverse index as the coverage check.
#
# WHY A NUDGE AND NOT A SEARCH. This hook used to run the prompt through
# synapse-tokenizer.sh, build a regexp OR-pattern, POST it to the vault's search
# endpoint, and inject the matching node paths. Measured against a real
# 52-node namespace, the prompt "can you explain how BatchRunner dispatches work
# items" returned 50 of 52 nodes -- for ~1057 tokens, on every single turn.
#
# The cause was not a tunable: `[Ww]ork` matched 50 nodes because it matched the
# substring inside `framework`, which appears 1392 times across the namespace's
# `sources` lists. Word boundaries only brought the union from 50 to 25. One weak
# term OR'd into the pattern destroys the whole query, and an ordinary sentence
# nearly always contains one.
#
# It was also solving a problem that no longer exists. Discovery is now cheap and
# precise on demand: `synapse index lookup` answers path -> owning node for ~15 tokens
# with nothing entering context, the tags cache answers symbol questions without
# opening a file, and `synapse-query.sh` projects exactly the field asked for.
# Those are pull, precise, and paid only when the question is about the codebase.
# The search was push, imprecise, and paid on every turn -- including on "commit
# and push". Reading the entire node map costs ~2500 tokens once, so the old hook
# overtook that after 2.4 turns and kept charging.
#
# What could not be replaced by pulling is the reminder itself. A SessionStart
# injection ages out of a long session once context is compacted; a per-turn line
# does not. So this keeps the habit-defeating half -- reach for Synapse before
# grep -- and drops the half that tried to guess which nodes mattered. The skills
# already say what to do with them.
#
# No network, no jq-over-REST, no tokenizer: filesystem and git only. Every exit
# path is a genuine no-op -- disabled, no prompt, not a git repo, no namespace
# for this repo, or a namespace belonging to a different remote.
set -uo pipefail

# WHAT IS LEFT HERE. Config, identity and dispatch. The hook itself is
# `synapse-hook prompt-context` -- see src/apps/hook/prompt_context.zig. Identity stays here
# because synapse-identity.sh is still bash and this was one of its sourcers; the
# wrapper collapses when that lands.
#
# Every failure to resolve anything exits 0. A hook that errors is worse than one
# that quietly does nothing: it interrupts a turn to report a condition the user
# did not ask about and usually cannot act on.

CONF="$HOME/.claude/synapse.conf"
[ -f "$CONF" ] || CONF="$HOME/.claude/second-brain.conf"
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"
[ -n "${OBSIDIAN_VAULT_DIR:-}" ] && export OBSIDIAN_VAULT_DIR

HOOK_BIN="${SYNAPSE_HOOK_BIN:-$HOME/.claude/bin/synapse-hook}"
[ -x "$HOOK_BIN" ] || exit 0
export SYNAPSE_HOOK_BIN="$HOOK_BIN"

command -v jq >/dev/null || exit 0
INPUT="$(cat)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty')"
[ -n "$CWD" ] || CWD="$PWD"

# The namespace, resolved once and exported -- the same arrangement every ported
# script uses, so a hook cannot disagree with a command about which graph a
# checkout belongs to.
if command -v git >/dev/null; then
  REPO_ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -n "$REPO_ROOT" ]; then
    # shellcheck source=/dev/null
    if . "${SYNAPSE_LIB_DIR:-$HOME/.claude/lib/synapse}/synapse-identity.sh" 2>/dev/null; then
      # A detached HEAD has no branch and so no namespace. Not an error: the hook
      # simply has nothing to say, and every consumer treats an absent
      # SYNAPSE_NAMESPACE as exactly that.
      if REPO_NAME="$(synapse_namespace "$REPO_ROOT" 2>/dev/null)"; then
        export SYNAPSE_NAMESPACE="$REPO_NAME"
        export SYNAPSE_REPO_ROOT="$REPO_ROOT"
        export SYNAPSE_BRANCH; SYNAPSE_BRANCH="$(synapse_branch "$REPO_ROOT")"
        export SYNAPSE_REMOTE; SYNAPSE_REMOTE="$(synapse_remote "$REPO_ROOT")"
        export SYNAPSE_WORK_DIR="${SYNAPSE_WORK_DIR:-$HOME/.claude/synapse-work/$REPO_NAME}"
      fi
    fi
  fi
fi

printf '%s' "$INPUT" | exec "$HOOK_BIN" prompt-context
