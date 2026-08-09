#!/bin/bash
# Porcelain over the Synapse plumbing scripts in $SYNAPSE_LIB_DIR: one command
# with subcommands, without collapsing the plumbing into it -- each one stays
# a separate, individually tested script; this only adds a shorter, memorable
# name for it and a shared way to find it.
#
# Usage: synapse.sh <subcommand> [args...]
#
#   build-index           -> synapse-build-index.sh
#   build-lists           -> synapse-build-lists.sh
#   build-project-index   -> synapse-build-project-index.sh
#   build-refs            -> synapse-build-refs.sh
#   callers                -> synapse-callers.sh
#   enumerate              -> synapse-enumerate.sh
#   gate                   -> synapse-gate.sh
#   graph-clean            -> synapse-graph-clean.sh
#   graph-wipe             -> synapse-graph-wipe.sh
#   push-nodes             -> synapse-push-nodes.sh
#   query                  -> synapse-query.sh
#   rank                   -> synapse-rank.sh
#   tags                   -> synapse-tags.sh
#   tags-cache             -> synapse-tags-cache.sh
#   tokenizer               -> synapse-tokenizer.sh
#   vocab                  -> synapse-vocab.sh
#   write-node              -> synapse-write-node.sh
#
# Not listed: synapse-identity.sh, which is sourced by the others and never
# executed on its own -- there is no standalone behavior to dispatch to.
#
# Every subcommand documents its own usage, arguments and exit codes; run
# `synapse.sh <subcommand> --help` for that. This porcelain adds no flags or
# behavior of its own beyond dispatch, and every argument after the
# subcommand is passed through unchanged.
#
# Exit codes: whatever the dispatched script exits with; 2 for no subcommand,
# an unknown one, or --help/-h (which prints this and exits 0).
set -euo pipefail

usage() { # usage [exit-code]
  awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
  exit "${1:-2}"
}

SUB="${1:-}"
case "$SUB" in
  -h|--help) usage 0 ;;
  "") usage ;;
esac
shift

# synapse.conf, falling back to the name this file had before the project was
# renamed, so scripts updated ahead of setup.sh still find an existing config
# rather than reporting "no vault". Sourced here, once, rather than in every
# plumbing script individually: this is the one place every invocation passes
# through, so a SYNAPSE_LIB_DIR set in synapse.conf takes effect here and
# then propagates by export -- including into scripts a dispatched target
# shells out to itself (synapse-build-lists.sh calling synapse-enumerate.sh,
# synapse-query.sh calling synapse-callers.sh), without each of those needing
# to source conf on their own.
CONF="$HOME/.claude/synapse.conf"
[ -f "$CONF" ] || CONF="$HOME/.claude/second-brain.conf"
[ -f "$CONF" ] && source "$CONF"
export SYNAPSE_LIB_DIR="${SYNAPSE_LIB_DIR:-$HOME/.claude/lib/synapse}"

# A case statement, not an associative array: the shebang above resolves to
# macOS's shipped /bin/bash (3.2) whenever a newer bash isn't first on PATH,
# and 3.2 has no associative arrays. Nothing else in this codebase assumes
# bash 4+, and this porcelain shouldn't be the first thing that does.
target=""
case "$SUB" in
  build-index)          target=synapse-build-index.sh ;;
  build-lists)          target=synapse-build-lists.sh ;;
  build-project-index)  target=synapse-build-project-index.sh ;;
  build-refs)           target=synapse-build-refs.sh ;;
  callers)              target=synapse-callers.sh ;;
  enumerate)            target=synapse-enumerate.sh ;;
  gate)                 target=synapse-gate.sh ;;
  graph-clean)          target=synapse-graph-clean.sh ;;
  graph-wipe)           target=synapse-graph-wipe.sh ;;
  push-nodes)           target=synapse-push-nodes.sh ;;
  query)                target=synapse-query.sh ;;
  rank)                 target=synapse-rank.sh ;;
  tags)                 target=synapse-tags.sh ;;
  tags-cache)           target=synapse-tags-cache.sh ;;
  tokenizer)            target=synapse-tokenizer.sh ;;
  vocab)                target=synapse-vocab.sh ;;
  write-node)           target=synapse-write-node.sh ;;
  *)
    echo "synapse: unknown subcommand '$SUB'" >&2
    usage
    ;;
esac

script="$SYNAPSE_LIB_DIR/$target"
[ -x "$script" ] || {
  echo "synapse: $target not found at $script (run setup.sh)" >&2
  exit 1
}

exec "$script" "$@"
