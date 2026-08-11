#!/bin/bash
# Transitional shim. The implementation is `synapse tags` in the Zig binary;
# this file exists so the four scripts that still invoke it by path --
# synapse-vocab.sh, synapse-rank.sh, synapse-tags-cache.sh,
# synapse-write-node.sh -- keep working unchanged while they are ported in
# turn. It goes away with the last of them.
#
# Usage is unchanged, and so is every byte of the output:
#        synapse-tags.sh <file-path>
#        synapse-tags.sh --paths <file-list>
#        synapse-tags.sh --list-extensions
#   Grammar cache dir: $SYNAPSE_GRAMMARS_DIR, default ~/.cache/synapse/grammars/.
#   First-clone lock wait: $SYNAPSE_GRAMMAR_LOCK_TRIES, default 300 (~60s at
#   0.2s/try).
#
# $SYNAPSE_REPO_GRAMMAR_CACHE is gone, and callers that still set it are
# harmlessly ignored. It existed for exactly one reason, stated in the old
# script's own header: each registry resolution cost several `jq` spawns, and
# the cache removed the repeats. Resolution is in-process now and costs
# nothing, so the knob has nothing left to buy.
#
# `exec` rather than a call: no reason to keep a shell alive around the
# binary, and the exit code passes through untouched, which matters because
# callers distinguish 1 (unusable, nothing to try) from 2 (no registry entry,
# run grammar discovery and retry).
exec "${SYNAPSE_BIN:-$HOME/.claude/bin/synapse}" tags "$@"
