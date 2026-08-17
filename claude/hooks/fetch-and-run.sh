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

set -euo pipefail

hook="${1:-}"
[ -n "$hook" ] || exit 0
shift

cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/synapse"
bin_dir="$cache_dir/bin"
bin_path="$bin_dir/synapse-hook"

if [ ! -x "$bin_path" ]; then
    os=$(uname -s)
    arch=$(uname -m)
    case "$os-$arch" in
        Darwin-arm64|Darwin-aarch64) target="aarch64-macos" ;;
        Linux-x86_64)                target="x86_64-linux"  ;;
        Linux-aarch64|Linux-arm64)   target="aarch64-linux" ;;
        *) exit 0 ;; # unsupported platform -- no prebuilt binary, nothing to fetch
    esac

    mkdir -p "$bin_dir"
    tmp=$(mktemp -d) || exit 0
    trap 'rm -rf "$tmp"' EXIT

    url="https://github.com/imunitic/synapse/releases/latest/download/synapse-$target.tar.gz"
    curl -fsSL -o "$tmp/synapse.tar.gz" "$url" || exit 0
    tar -xzf "$tmp/synapse.tar.gz" -C "$tmp" || exit 0
    [ -x "$tmp/synapse-hook" ] || exit 0
    mv "$tmp/synapse" "$bin_dir/synapse" 2>/dev/null || true
    mv "$tmp/synapse-hook" "$bin_path"
fi

exec "$bin_path" "$hook" "$@"
