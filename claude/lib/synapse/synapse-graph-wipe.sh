#!/bin/bash
# Wipes the current checkout's Synapse namespace, preserving any hand-written
# `## Notes` content first, ahead of a full /synapse-rebuild-full rebuild. The
# second destructive tool in Synapse (after synapse-graph-clean.sh), so it follows
# the same discipline: --dry-run support, and rm -rf gated behind a belt-and-braces
# path check that only ever removes a directory whose name was just matched inside
# the vault's own synapse/ directory.
#
# Usage: synapse-graph-wipe.sh [--dry-run]
#        synapse-graph-wipe.sh --help
#
#   --dry-run  report node count and which nodes have `## Notes` content at risk,
#              delete nothing, preserve nothing.
#
# Operates on {repo}@{branch} resolved from $PWD via synapse-identity.sh -- the
# same resolution /synapse-init and /synapse-rebuild-diff use. Never takes a
# namespace on the command line: this wipes the current checkout's own namespace,
# nothing else's.
#
# `## Notes` is the one thing in a node file that is human-authored and lives
# outside every generated fence -- no script regenerates it. Before deleting
# anything, every node's `## Notes` section is scanned; non-empty ones are dumped
# into a staging note at scratchpad/{repo}@{branch} -- preserved notes before full
# rebuild.md, so nothing is silently lost even though the namespace directory that
# held them is about to be removed. /synapse-rebuild-full reads that staging note
# back after rebuilding and merges what it can into the new nodes.
#
# Exit codes:
#   0 - ran (removed the namespace, or --dry-run reported cleanly)
#   1 - could not run (no vault, not in a git repo, missing dependency, namespace absent)
#   2 - usage error
set -uo pipefail

usage() { # usage [exit-code]
    awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
    exit "${1:-2}"
}

DRY_RUN=false
case "${1:-}" in
    "")        ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage 0 ;;
    *)         usage ;;
esac

CONF="$HOME/.claude/synapse.conf"
[ -f "$CONF" ] || CONF="$HOME/.claude/second-brain.conf"
# shellcheck source=/dev/null
[ -f "$CONF" ] && source "$CONF"
VAULT="${OBSIDIAN_VAULT_DIR:-}"
[ -n "$VAULT" ] && [ -d "$VAULT" ] || { echo "synapse-graph-wipe: no vault" >&2; exit 1; }

command -v git >/dev/null || { echo "synapse-graph-wipe: git required" >&2; exit 1; }

REPO_ROOT="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || { echo "synapse-graph-wipe: not inside a git repo" >&2; exit 1; }

# shellcheck source=/dev/null
. "${SYNAPSE_LIB_DIR:-$HOME/.claude/lib/synapse}/synapse-identity.sh" 2>/dev/null || {
    echo "synapse-graph-wipe: synapse-identity.sh not installed (run setup.sh)" >&2; exit 1; }

NS="$(synapse_namespace "$REPO_ROOT")" || exit 1
ns_dir="$VAULT/synapse/$NS"

[ -d "$ns_dir" ] || {
    echo "synapse-graph-wipe: no namespace at synapse/$NS -- nothing to wipe (first build? use /synapse-init)" >&2
    exit 1
}

# --- scan every node for at-risk ## Notes content -----------------------------
# A node file is any *.md directly under the namespace dir except Index.md;
# _manifest.tsv/_profile.txt are internal and machine-only, same distinction
# synapse-graph-clean.sh's neighbours draw. The reverse index and the tags cache
# used to need naming here too -- they live in the work dir now, so a wipe of the
# namespace does not have to reason about them at all.
shopt -s nullglob
node_count=0
notes_at_risk=0
preserved=""
for node_file in "$ns_dir"/*.md; do
    base="$(basename "$node_file")"
    [ "$base" = "Index.md" ] && continue
    node_count=$((node_count + 1))

    # `## Notes` is whatever follows the generated-end marker, minus its own
    # heading line and leading/trailing blank lines -- the same region
    # synapse-write-node.sh preserves verbatim as `node_tail` on every rewrite.
    # Single awk pass (no sed block syntax -- BSD sed on macOS rejects
    # `1{/pat/d}` and GNU sed accepts it, one more place this codebase has
    # already hit a portability gap between the two).
    notes_body="$(awk '
        /<!-- synapse:generated:end -->/ { f = 1; next }
        f { a[++n] = $0 }
        END {
            i = 1
            while (i <= n && a[i] ~ /^[[:space:]]*$/) i++
            if (i <= n && a[i] == "## Notes") i++
            while (i <= n && a[i] ~ /^[[:space:]]*$/) i++
            last = n
            while (last >= i && a[last] ~ /^[[:space:]]*$/) last--
            for (k = i; k <= last; k++) print a[k]
        }
    ' "$node_file")"
    if [ -n "$notes_body" ]; then
        notes_at_risk=$((notes_at_risk + 1))
        title="${base%.md}"
        printf 'at-risk\t%s\thas hand-written ## Notes content\n' "$title"
        preserved="${preserved}## ${title}

${notes_body}

"
    fi
done

echo "namespace: synapse/$NS ($node_count nodes, $notes_at_risk with ## Notes content)"

if [ "$DRY_RUN" = true ]; then
    echo "would-remove synapse/$NS"
    exit 0
fi

# --- preserve before deleting --------------------------------------------------
if [ -n "$preserved" ]; then
    staging_name="$NS — preserved notes before full rebuild.md"
    staging_path="scratchpad/$staging_name"
    mkdir -p "$VAULT/scratchpad"
    {
        printf -- '---\ntitle: "%s — preserved notes before full rebuild"\ncreated: "%s"\n---\n\n' \
            "$NS" "$(date '+%Y-%m-%d %H:%M')"
        printf '# %s — preserved notes before full rebuild\n\n' "$NS"
        printf 'Hand-written `## Notes` content recovered from `synapse/%s` before it was wiped for a full rebuild. `/synapse-rebuild-full` merges what it can back into the new nodes once the rebuild completes; whatever is still here after that needs a manual look.\n\n' "$NS"
        printf '%s' "$preserved"
    } > "$VAULT/$staging_path"
    echo "preserved -> $staging_path"
fi

# --- delete ---------------------------------------------------------------------
# Belt and braces before an rm -rf: only ever inside the vault's synapse/
# directory, and only a directory whose name we just matched.
case "$ns_dir" in
    "$VAULT/synapse/"*) rm -rf "$ns_dir" ;;
    *) echo "synapse-graph-wipe: refusing to remove $ns_dir" >&2; exit 1 ;;
esac

echo "removed synapse/$NS"
