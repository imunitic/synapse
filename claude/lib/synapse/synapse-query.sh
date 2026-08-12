#!/bin/bash
# Read-only queries against a repo's Synapse graph. Reads the expensive parts
# internally and prints only what was asked for.
#
# Usage: synapse-query.sh <subcommand> [args]   (operates on the repo containing $PWD)
#
#   body    <node>                     fenced prose only, no frontmatter
#   sources <node>                     every path the node covers
#   sources <node> --count             just the number
#   sources <node> --modules           module<TAB>count, LC_ALL=C sorted
#   sources <node> --filter <pattern>  matching paths only (substring)
#   field   <node> <key>               one top-level frontmatter scalar
#   stale                              nodes whose files no longer match, with a reason
#   drift                              what changed since each node's recorded commit
#   grounding                          nodes whose recorded evidence no longer matches
#   grounding <node> --list            that node's groundings, as path<TAB>lines
#   links   <node>                     outbound relations, as relation<TAB>target
#   links   <node> --inbound           what points here, as relation<TAB>source
#   links   <node> --closure           every node reachable outbound, depth<TAB>node
#   links   --check                    link targets that resolve to no node
#   symbol  <name> <node>              exact-name def/ref hits across the node's
#                                      sources, as path<TAB>tag-line
#   callers <name>                     repo-wide call sites of an exact name, as
#                                      path:line<TAB>calling expression
#   callers <name> --all               every def and ref, not only calls, as
#                                      def|ref<TAB>kind<TAB>path:line<TAB>expression
#
# <node> may be given with or without the trailing `.md`.
#
# `callers` is a one-line dispatch into claude/lib/synapse/synapse-callers.sh, ahead of
# this script's namespace preamble -- see that file's header for why, and for the
# rest of its usage and rationale.
#
# `symbol` and `callers` differ in scope, not technique. `symbol` is scoped to
# one node's sources and re-hashes them on every call, so it answers "within this
# subsystem" and costs O(node sources); `callers` is repo-wide over a precomputed
# index, so it answers "anywhere" and costs one pass over a text file.
#
# `symbol` is a name-based, not type-resolved, lookup backed by a per-project
# tags cache ($SYNAPSE_WORK_DIR/_tags_cache.bin, default
# ~/.claude/synapse-work/{repo}@{branch}/) kept current as a byproduct of node
# build/regeneration, with any file the cache is missing tagged lazily on the
# spot. Set SYNAPSE_DISABLE_SYMBOL_CACHE (any value) to disable entirely --
# see docs/synapse-graph.md's "Exact-symbol lookup" section for the full design.
#
# `stale` re-hashes what a node claims; `drift` diffs its recorded `commit` against
# HEAD, so only `drift` sees added, deleted and renamed paths. Neither pulls.
# When to use which, and why any of this is a script: docs/synapse-graph.md.
#
# Exit codes:
#   0 - ran successfully. Empty output means clean for every reporting subcommand:
#       `stale`, `drift`, `grounding` and `links --check`. `drift` prints context
#       (commits behind, commits since baseline) only alongside a finding, so its
#       silence means the graph matches the worktree rather than that it gave up.
#   1 - could not run (missing dependency, no vault, no namespace, remote
#       mismatch, unknown node). Treat as "no information", never as "clean".
#   2 - usage error (unknown subcommand, bad flag, unsupported field)
#
# WHAT IS LEFT HERE. Namespace resolution and dispatch, and nothing else. Every
# subcommand moved into `synapse query`, which is where the vault reads, the
# frontmatter parsing, the digest arithmetic, the link graph and the tags-cache
# lookup now live -- and where `jq`, `sed`, `awk`, `comm`, `paste`, `wc` and every
# `curl` on the read path went with them. What the binary still spawns is `git`
# and, for a user-authored ERE out of `_manifest.tsv`, `grep -E`.
#
# Identity stays here because `synapse-identity.sh` is still bash and is sourced
# by hooks this rewrite has not reached yet. It is resolved once and exported, so
# the binary cannot disagree with the hooks about which namespace a checkout
# belongs to -- the same arrangement synapse-enumerate.sh already uses for
# $SYNAPSE_WORK_DIR.
set -uo pipefail

usage() { # usage [exit-code]
  awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
  exit "${1:-2}"
}

SUB="${1:-}"
[ -n "$SUB" ] || usage
shift

# Validate the subcommand *before* the preamble below. A usage error is a
# property of the arguments, not of the environment -- reporting "could not
# run" (exit 1) for a typo'd subcommand just because Obsidian happens to be
# down would send the caller looking in the wrong place entirely.
case "$SUB" in
  body|sources|field|stale|drift|grounding|links|symbol|callers) ;;
  -h|--help) usage 0 ;;
  *) usage ;;
esac

# `callers` needs no graph -- see claude/lib/synapse/synapse-callers.sh's
# header for why this dispatches ahead of the preamble below rather than after
# it. A one-line exec, not a sourced call, so "needs no graph" is a fact about
# the file rather than about dispatch order.
if [ "$SUB" = "callers" ]; then
  exec "${SYNAPSE_LIB_DIR:-$HOME/.claude/lib/synapse}/synapse-callers.sh" "$@"
fi

# synapse.conf, falling back to the name this file had before the project was
# renamed, so scripts updated ahead of setup.sh still find an existing config
# rather than reporting "no vault".
CONF="$HOME/.claude/synapse.conf"
[ -f "$CONF" ] || CONF="$HOME/.claude/second-brain.conf"
# shellcheck source=/dev/null
[ -f "$CONF" ] && . "$CONF"

VAULT="${OBSIDIAN_VAULT_DIR:-}"
[ -n "$VAULT" ] && [ -d "$VAULT" ] || exit 1

command -v git >/dev/null || exit 1
REPO_ROOT="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || exit 1

# One shared resolution of repo, branch and remote, so this cannot disagree with
# the hooks about which namespace a checkout belongs to -- a repo without an
# `origin`, or on a branch with no namespace, must compare the same way here as
# it does there.
# shellcheck source=/dev/null
. "${SYNAPSE_LIB_DIR:-$HOME/.claude/lib/synapse}/synapse-identity.sh" 2>/dev/null || {
  echo "synapse-query: synapse-identity.sh not installed (run setup.sh)" >&2; exit 1; }
# Exit 1, not 0: this is "could not run", never "clean". A detached HEAD has no
# namespace, and reporting silence would read as a graph that matches.
REPO_NAME="$(synapse_namespace "$REPO_ROOT")" || exit 1

# Required, not optional: the binary is the only implementation of this now.
SYNAPSE_BIN_PATH="${SYNAPSE_BIN:-$HOME/.claude/bin/synapse}"
[ -x "$SYNAPSE_BIN_PATH" ] || {
  echo "synapse-query: no synapse binary at $SYNAPSE_BIN_PATH (run setup.sh)" >&2; exit 1; }

export OBSIDIAN_VAULT_DIR="$VAULT"
export SYNAPSE_NAMESPACE="$REPO_NAME"
export SYNAPSE_REPO_ROOT="$REPO_ROOT"
export SYNAPSE_WORK_DIR="${SYNAPSE_WORK_DIR:-$HOME/.claude/synapse-work/$REPO_NAME}"
export SYNAPSE_BRANCH; SYNAPSE_BRANCH="$(synapse_branch "$REPO_ROOT")"
export SYNAPSE_REMOTE; SYNAPSE_REMOTE="$(synapse_remote "$REPO_ROOT")"

exec "$SYNAPSE_BIN_PATH" query "$SUB" "$@"
