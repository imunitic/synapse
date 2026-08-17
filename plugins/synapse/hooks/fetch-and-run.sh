#!/bin/bash
# Every hook in hooks.json routes through this rather than invoking
# synapse-hook directly: the compiled binary isn't shipped inside the plugin
# (which would bloat every install with a platform-specific artifact and
# require rebuilding the marketplace source per push) -- it's downloaded
# once from the latest GitHub Release and cached, same idea as
# SYNAPSE_GRAMMARS_DIR already caching cloned grammars at
# ~/.cache/synapse/grammars.
#
#   fetch-and-run.sh <hook-subcommand> [args passed through to synapse-hook]
#
# Never blocks a turn on a network hiccup: any failure here exits 0 with no
# output, same "every missing precondition is silence" contract synapse-hook
# itself already follows.
#
# Nothing here resolves synapse-claude.md or the plugin root at all --
# CLAUDE_PLUGIN_ROOT is a real exported environment variable on the spawned
# process ("regardless of how it was launched", per Claude Code's own hooks
# reference), which `exec` below preserves automatically. synapse-hook reads
# it directly.
#
# Re-checks for a newer binary once per plugin update, not every session and
# not never (the two extremes the design originally left open). Confirmed
# live: with only a fresh-cache check, a machine's cached binary silently
# never updates again, ever, however many releases ship after it. Rather
# than polling the network for a version marker every session, this
# piggybacks on Claude Code's own plugin-update detection: plugin.json's
# `version` field already changes exactly when Claude Code decides the
# plugin updated, so comparing it locally (a file read, not a network call)
# costs nothing and stays correctly in sync with zero polling logic here.

set -euo pipefail

hook="${1:-}"
[ -n "$hook" ] || exit 0
shift

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/synapse"
bin_dir="$cache_dir/bin"
bin_path="$bin_dir/synapse-hook"
version_file="$bin_dir/.plugin-version"

# grep/sed, not jq -- this hook runs on every single Synapse event, so it
# stays dependency-free the way it always has rather than making jq a hard
# requirement for basic functionality (obsidian-mcp-refresh.sh, a single
# once-per-session hook, is the one place that tradeoff was already made).
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
            url="https://github.com/imunitic/synapse/releases/latest/download/synapse-$target.tar.gz"
            # Best-effort, not `|| exit 0`: a failed re-fetch of a *newer*
            # version must fall through to running the still-perfectly-good
            # binary already cached below, not exit silently and skip the
            # hook entirely for this turn.
            if curl -fsSL -o "$tmp/synapse.tar.gz" "$url" 2>/dev/null \
                && tar -xzf "$tmp/synapse.tar.gz" -C "$tmp" 2>/dev/null \
                && [ -x "$tmp/synapse-hook" ]; then
                mv "$tmp/synapse" "$bin_dir/synapse" 2>/dev/null || true
                mv "$tmp/synapse-hook" "$bin_path"
                [ -n "$current_version" ] && printf '%s' "$current_version" > "$version_file"
            fi
        fi
    fi
fi

[ -x "$bin_path" ] || exit 0
exec "$bin_path" "$hook" "$@"
