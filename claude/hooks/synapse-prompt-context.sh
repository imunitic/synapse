#!/bin/bash
# UserPromptSubmit hook: on every turn in a repo that has a Synapse namespace,
# state that the namespace exists and name the tools that read it. One short
# standing line -- no search, no node list, no network. Set
# SYNAPSE_DISABLE_PROMPT_INJECTION (any value) to disable entirely.
#
# TWO TOOLS, NOT ONE. The line names the Graph (nodes, _index.json) and the Code
# Cache (_refs.tsv) as separate things, because they are: the Code Cache is an
# acceleration layer that stands alone, and `callers` answers in a repo where
# clustering has never run. Collapsing both into "read the graph" is what the
# earlier wording did, and it cost a real session -- the reader skimmed node
# titles, saw nothing matching the subject, concluded Synapse did not cover the
# area, and fell back to grep. Every file was indexed; the titles were simply
# misleading about ownership. Hence naming _index.json as the coverage check.
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
# precise on demand: `_index.json` answers path -> owning node for ~15 tokens
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

[ -n "${SYNAPSE_DISABLE_PROMPT_INJECTION:-}" ] && exit 0

# synapse.conf, falling back to the name this file had before the project was
# renamed, so scripts updated ahead of setup.sh still find an existing config
# rather than reporting "no vault".
CONF="$HOME/.claude/synapse.conf"
[ -f "$CONF" ] || CONF="$HOME/.claude/second-brain.conf"
[ -f "$CONF" ] && source "$CONF"

VAULT="${OBSIDIAN_VAULT_DIR:-}"
[ -n "$VAULT" ] && [ -d "$VAULT" ] || exit 0
command -v jq >/dev/null || exit 0

INPUT="$(cat)"

# `prompt` matches Claude Code's documented convention for this hook event, the
# same way `session_id` (verified, see synapse-stop-nudge.sh) and
# `tool_input`/`tool_response` (verified, see synapse-staleness.sh) are named for
# theirs. Verified live: the hook fires with this field populated. An empty
# PROMPT still exits silently, so a payload change degrades to "does nothing".
PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // empty')"
[ -n "$PROMPT" ] || exit 0

CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty')"
[ -n "$CWD" ] || CWD="$PWD"

REPO_ROOT="$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || exit 0

# One shared resolution of repo, branch and remote, so this hook cannot drift
# from synapse-staleness.sh / synapse-session-start.sh / synapse-query.sh.
# shellcheck source=/dev/null
. "${SYNAPSE_LIB_DIR:-$HOME/.claude/lib/synapse}/synapse-identity.sh" 2>/dev/null || exit 0
REMOTE="$(synapse_remote "$REPO_ROOT")"
# Detached HEAD: no branch, so no namespace to point at.
REPO_NAME="$(synapse_namespace "$REPO_ROOT" 2>/dev/null)" || exit 0

NS_DIR="$VAULT/synapse/$REPO_NAME"
NS_INDEX="$NS_DIR/Index.md"
[ -f "$NS_INDEX" ] || exit 0

# The same remote check every other component makes before trusting a namespace:
# two repos can share a key, and pointing at another project's graph is worse
# than saying nothing.
NS_REMOTE="$(grep -m1 '^remote:' "$NS_INDEX" 2>/dev/null \
  | sed -e 's/^remote: *//' -e 's/^"//' -e 's/"$//' || true)"
[ -n "$NS_REMOTE" ] && [ "$NS_REMOTE" = "$REMOTE" ] || exit 0

# Node count, so the line says how much is actually there rather than asserting
# a graph exists in the abstract. Index.md is excluded: it is the map, not a node.
NODES="$(find "$NS_DIR" -maxdepth 1 -name '*.md' ! -name 'Index.md' 2>/dev/null | wc -l | tr -d ' ')"
[ "$NODES" -gt 0 ] || exit 0

# THE CODE CACHE IS A SEPARATE TOOL, NOT PART OF THE GRAPH. `callers` reads
# _refs.tsv and needs no nodes, no _index.json and no vault, so listing it as a
# graph reader (as this line used to) actively misleads: it implies the answer
# depends on clustering that may not exist, and it hides the one Synapse tool
# that works in an unclustered repo. `symbol` is the same Code Cache lookup
# scoped by a node, which is why it takes two arguments -- a one-arg call prints
# usage and reads as "unimplemented" to anyone who does not know the signature.
#
# Announced only when _refs.tsv is actually present, for the same reason the
# node count is computed rather than asserted above: name what is there, never a
# capability in the abstract. A missing index would otherwise send the reader to
# a tool that exits with "no reference index".
WORK="${SYNAPSE_WORK_DIR:-$HOME/.claude/synapse-work/$REPO_NAME}"
CACHE=""
[ -f "$WORK/_refs.tsv" ] && CACHE="$(printf '%s' \
  ' Separately, and independent of the graph, a Code Cache indexes exact names:' \
  ' `synapse.sh callers <name>` gives repo-wide call sites (no graph needed),' \
  ' `synapse-query.sh symbol <name> <node>` scopes that lookup to one node.' \
  ' Prefer either over grep for "where is X defined/used"; their line numbers' \
  ' come from the index and can lag the working tree, so re-check a range before' \
  ' relying on it.')"

jq -n --arg ns "$REPO_NAME" --arg n "$NODES" --arg cache "$CACHE" '
  {
    hookSpecificOutput: {
      hookEventName: "UserPromptSubmit",
      additionalContext: (
        "Synapse: this repo has a code graph at synapse/" + $ns + "/ (" + $n + " nodes). " +
        "If this turn needs to know how the codebase works, consult Synapse before grepping or " +
        "opening files -- synapse-query.sh (body/sources/field/links), _index.json " +
        "for path -> owning node (the authoritative coverage check: never infer from node titles)." +
        $cache +
        " The synapse-query and synapse-node skills have the procedure."
      )
    }
  }'
