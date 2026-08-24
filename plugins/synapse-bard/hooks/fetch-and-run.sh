#!/bin/bash
# Every hook in synapse-bard's own hooks.json routes through this rather
# than invoking synapse-bard-hook directly: the compiled binary isn't
# shipped inside the plugin, it's downloaded once from the `dist` branch's
# latest committed tarball and cached -- same idea synapse's own
# claude/hooks/fetch-and-run.sh uses, forked rather than shared for the same
# reason the skill/command layer was forked (see synapse-bard-001's own
# notes): this is audience-independent protocol code, but it caches under
# its own ~/.cache/synapse-bard/bin, distinct from synapse's
# ~/.cache/synapse/bin, so the two plugins never fight over one binary slot
# on a machine that has both installed.
#
# Fetched via raw.githubusercontent.com, not a GitHub Release download URL:
# `synapse-bard`'s primary audience is an Android-app cloud session, and in
# an Anthropic-hosted cloud sandbox, release-asset downloads route through a
# repo-scoped GitHub proxy that 403s any repo other than the one the session
# is attached to (rarely this one, since synapse-bard's primary audience
# isn't developing this plugin itself), per Claude Code's own
# cloud-environments docs. Raw file
# content from a public repo routes through the general security proxy
# instead, unscoped, so this URL shape actually reaches the session.
#
#   fetch-and-run.sh <hook-subcommand> [args passed through to synapse-bard-hook]
#
# Never blocks a turn on a network hiccup: any failure here exits 0 with no
# output, same "every missing precondition is silence" contract
# synapse-bard-hook itself already follows.
#
# Same os/arch detection as the coding side's script, not narrowed to her
# own session's architecture: synapse-bard ships the same platform set
# synapse does (x86_64-linux, aarch64-linux, aarch64-macos), so this
# resolves whichever one the machine actually is rather than assuming.
#
# Re-checks for a newer binary once per plugin update, not every session and
# not never -- same mechanism as the coding side: plugin.json's `version`
# field changes exactly when Claude Code decides the plugin updated, so
# comparing it locally (a file read, not a network call) costs nothing and
# stays correctly in sync with zero polling logic here.

set -euo pipefail

hook="${1:-}"
[ -n "$hook" ] || exit 0
shift

# sha256sum (Linux) or shasum -a 256 (macOS has no sha256sum by default) --
# whichever's present, one or the other always is on the target platforms
# this ships for.
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/synapse-bard"
bin_dir="$cache_dir/bin"
bin_path="$bin_dir/synapse-bard-hook"
version_file="$bin_dir/.plugin-version"

# grep/sed, not jq -- same dependency-free reasoning as the coding side's
# script: this runs on every synapse-bard event.
current_version=""
plugin_json="${CLAUDE_PLUGIN_ROOT:-}/.claude-plugin/plugin.json"
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$plugin_json" ]; then
    current_version="$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$plugin_json" 2>/dev/null \
        | sed -E 's/.*"([^"]+)"$/\1/' || true)"
fi

cached_version=""
[ -f "$version_file" ] && cached_version="$(cat "$version_file" 2>/dev/null || true)"

stale=0
if [ -n "$current_version" ] && [ "$current_version" != "$cached_version" ]; then
    stale=1
fi

if [ ! -x "$bin_path" ] || [ "$stale" -eq 1 ]; then
    os=$(uname -s)
    arch=$(uname -m)
    target=""
    case "$os-$arch" in
        Darwin-arm64|Darwin-aarch64) target="aarch64-macos" ;;
        Linux-x86_64)                target="x86_64-linux"  ;;
        Linux-aarch64|Linux-arm64)   target="aarch64-linux" ;;
    esac

    if [ -n "$target" ]; then
        mkdir -p "$bin_dir" 2>/dev/null || true
        tmp="$(mktemp -d 2>/dev/null || true)"
        if [ -n "$tmp" ]; then
            trap 'rm -rf "$tmp"' EXIT
            archive="synapse-bard-$target.tar.gz"
            url="https://raw.githubusercontent.com/imunitic/synapse/dist/$archive"
            sums_url="https://raw.githubusercontent.com/imunitic/synapse/dist/SHA256SUMS"
            # Best-effort, not `|| exit 0`: a failed re-fetch of a *newer*
            # version must fall through to running the still-perfectly-good
            # binary already cached below, not exit silently and skip the
            # hook entirely for this turn.
            #
            # SHA256SUMS is fetched fresh alongside the archive every time
            # (not cached) and checked against it before extracting: this is
            # the only thing standing between "raw.githubusercontent.com
            # served bytes" and "these are the bytes release.yml actually
            # published" -- a mismatch here is treated exactly like a failed
            # curl, silently keeping the last-known-good cached binary.
            if curl -fsSL -o "$tmp/$archive" "$url" 2>/dev/null \
                && curl -fsSL -o "$tmp/SHA256SUMS" "$sums_url" 2>/dev/null \
                && [ "$(awk -v f="$archive" '$2 == f { print $1 }' "$tmp/SHA256SUMS")" = "$(sha256_of "$tmp/$archive")" ] \
                && tar -xzf "$tmp/$archive" -C "$tmp" 2>/dev/null \
                && [ -x "$tmp/synapse-bard-hook" ]; then
                mv "$tmp/synapse-bard" "$bin_dir/synapse-bard" 2>/dev/null || true
                mv "$tmp/synapse-bard-hook" "$bin_path"
                [ -n "$current_version" ] && printf '%s' "$current_version" > "$version_file"
            fi
        fi
    fi
fi

[ -x "$bin_path" ] || exit 0
exec "$bin_path" "$hook" "$@"
