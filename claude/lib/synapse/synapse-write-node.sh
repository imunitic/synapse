#!/bin/bash
# Writes one Synapse node into the vault: hashes every source path, computes
# sources_digest, records the baseline `commit`, builds the aggregated `## Sources`
# mirror, and PUTs the note via the Obsidian Local REST API.
#
# Usage: synapse-write-node.sh --title <t> --summary <s> --paths <file> --body <file>
#        synapse-write-node.sh --help
#
#   --title    node title. Used verbatim as the H1, and sanitized for the filename.
#   --summary  one line for the index bullet, stored as the `summary` frontmatter
#              field. Written for the index, not as the node's opening sentence.
#   --paths    file of repo-relative paths, one per line: every file the node covers.
#   --body     file holding the authored prose (## Summary / ## Crux / ## Links).
#              `## Sources` and the generated fences are added by the writer.
#
# The body must not contain crux code. It points instead:
#
#   <!-- crux: crates/matcher/src/lib.rs 412-419 -->     slice these lines
#   <!-- crux: none -->                                  no single span carries it
#
# The writer cuts the text out of the file, fences it with a language guessed
# from the extension, appends a `path:start-end` provenance line, and records
# `crux_path`/`crux_lines` in frontmatter. The path must be one the node claims
# and the range must be under 20 lines, or the write is refused.
#
# The body may also carry any number of grounding pointers — the evidence a
# summary rests on, typically a doc comment or a test:
#
#   <!-- grounded_in: src/main/java/Foo.java 10-14 -->
#
# These are recorded in the `grounded_in` frontmatter list as path + lines +
# sha256 of the sliced text, then stripped from the body: provenance, not
# display. Same path and range checks as the crux, with a 40-line cap.
#
# Writes to the vault over the Obsidian Local REST API on 127.0.0.1. Agent callers
# need the network sandbox disabled, or curl fails with exit 7 and no message.
#
# As a byproduct it refreshes $SYNAPSE_WORK_DIR/_tags_cache.bin (default
# ~/.claude/synapse-work/{repo}@{branch}/) for the node's sources, so
# `synapse-query.sh symbol` is a cache read. That file is derived and
# disposable, which is why it lives beside the work dir rather than in the
# version-controlled vault. Never fatal; SYNAPSE_DISABLE_SYMBOL_CACHE skips it.
#
# Exit codes:
#   0 - node written; prints "<file>\t<n> files\t<digest>"
#   1 - could not run (missing dependency, no vault, remote mismatch, PUT failed)
#   2 - usage error
#
# Design rationale lives in docs/synapse-graph.md, not here.
#
# WHAT IS LEFT HERE. Namespace resolution and dispatch. The writer moved into
# `synapse write-node`: the path hashing (in process now -- a git blob hash is
# sha1 over an object header git has not changed since 2005, so `git hash-object
# --stdin-paths` is gone), the digest, the crux slicing, the grounding digests,
# the `## Sources` mirror, the frontmatter and the PUT. With them went `jq`, the
# four `awk` programs, `paste`, `sed`, `wc` and both API *reads* -- the namespace
# index and the existing node are read from disk, which is where they are. The PUT
# still goes through the API, because that is what keeps Obsidian's own view and
# the vault's git history correct.
#
# Identity stays here because `synapse-identity.sh` is still bash and is sourced
# by hooks this rewrite has not reached yet. It is resolved once and exported so
# the binary cannot disagree with the hooks about which namespace a checkout
# belongs to.
set -euo pipefail

# synapse.conf, falling back to the name this file had before the project was
# renamed, so scripts updated ahead of setup.sh still find an existing config
# rather than reporting "no vault".
CONF="$HOME/.claude/synapse.conf"
[ -f "$CONF" ] || CONF="$HOME/.claude/second-brain.conf"
readonly CONF
readonly CERT="$HOME/.claude/obsidian-local-rest-api-ca.pem"

# Prints the header block, so help and the generated reference cannot disagree.
usage() { # usage [exit-code]
    awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
    exit "${1:-2}"
}

case "${1:-}" in
    -h|--help) usage 0 ;;
esac

# shellcheck source=/dev/null
[[ -f "$CONF" ]] && source "$CONF"
VAULT="${OBSIDIAN_VAULT_DIR:-}"
[[ -n "$VAULT" && -d "$VAULT" ]] || { echo "synapse-write-node: no vault" >&2; exit 1; }

readonly PLUGIN_DATA="$VAULT/.obsidian/plugins/obsidian-local-rest-api/data.json"
[[ -f "$PLUGIN_DATA" && -f "$CERT" ]] || { echo "synapse-write-node: REST API not configured" >&2; exit 1; }

command -v git >/dev/null || { echo "synapse-write-node: git required" >&2; exit 1; }
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_ROOT" ]] || { echo "synapse-write-node: not inside a git repo" >&2; exit 1; }

# "{repo}@{branch}", not a bare repo name -- see synapse-identity.sh.
# shellcheck source=/dev/null
. "${SYNAPSE_LIB_DIR:-$HOME/.claude/lib/synapse}/synapse-identity.sh" 2>/dev/null || {
    echo "synapse-write-node: synapse-identity.sh not installed (run setup.sh)" >&2; exit 1; }
REPO_NAME="$(synapse_namespace "$REPO_ROOT")" || exit 1

# Required, not optional: the binary is the only implementation of this now.
readonly SYNAPSE_BIN_PATH="${SYNAPSE_BIN:-$HOME/.claude/bin/synapse}"
[[ -x "$SYNAPSE_BIN_PATH" ]] || {
    echo "synapse-write-node: no synapse binary at $SYNAPSE_BIN_PATH (run setup.sh)" >&2; exit 1; }

export OBSIDIAN_VAULT_DIR="$VAULT"
export SYNAPSE_NAMESPACE="$REPO_NAME"
export SYNAPSE_REPO_ROOT="$REPO_ROOT"
export SYNAPSE_WORK_DIR="${SYNAPSE_WORK_DIR:-$HOME/.claude/synapse-work/$REPO_NAME}"
export SYNAPSE_BRANCH; SYNAPSE_BRANCH="$(synapse_branch "$REPO_ROOT")"
export SYNAPSE_REMOTE; SYNAPSE_REMOTE="$(synapse_remote "$REPO_ROOT")"

exec "$SYNAPSE_BIN_PATH" write-node "$@"
