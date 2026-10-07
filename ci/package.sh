#!/bin/bash
# Assembles the npm packages around the Ada release binaries of this
# machine's platform, installs them into a scratch prefix as a user would, and
# checks the installed program end to end: the `synapse` and `synapse-hook`
# shims find the binaries, `synapse-setup configure claude` wires the hooks to
# the installed hook binary, and that binary answers as a hook does.
#
#   ci/package.sh [--keep]
#
# Needs `bin/synapse` and `bin/synapse-hook` built with
# `alr build --release`. --keep leaves the scratch directory in place.
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"
keep=0
[ "${1:-}" = "--keep" ] && keep=1

for tool in node npm jq; do
    command -v "$tool" >/dev/null || { echo "$tool not on PATH" >&2; exit 1; }
done
for bin in synapse synapse-hook; do
    [ -x "bin/$bin" ] || { echo "bin/$bin missing -- run: alr build --release" >&2; exit 1; }
done

# On Linux, when a floor is named, the binaries must not ask for a newer glibc.
if [ -n "${GLIBC_FLOOR:-}" ] && [ "$(uname -s)" = Linux ]; then
    for b in synapse synapse-hook; do
        top="$(objdump -T "bin/$b" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -Vu | tail -1)"
        [ "$(printf '%s\n%s\n' "$top" "$GLIBC_FLOOR" | sort -V | tail -1)" = "$GLIBC_FLOOR" ] \
            || { echo "FAIL: $b needs glibc $top, above $GLIBC_FLOOR" >&2; exit 1; }
    done
    echo "  glibc floor $GLIBC_FLOOR ok"
fi

plat="$(node -p 'process.platform + "-" + process.arch')"
[ -d "packages/synapse/platforms/$plat" ] || { echo "no npm platform package for $plat" >&2; exit 1; }

work="$(mktemp -d)"
cleanup() { [ "$keep" = 1 ] && echo "kept $work" || rm -rf "$work"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# The packages, copied so the checkout is never written to.
cp -R packages/synapse "$work/pkg"
mkdir -p "$work/pkg/platforms/$plat/bin"
cp bin/synapse bin/synapse-hook "$work/pkg/platforms/$plat/bin/"

mkdir -p "$work/tarballs" "$work/prefix"
(cd "$work/tarballs" && npm pack "$work/pkg/platforms/$plat" --silent >/dev/null && npm pack "$work/pkg" --silent >/dev/null)
ls "$work/tarballs" | sed 's/^/  packed /'

# Both in one install, so the main package's optional dependency on the
# platform package is satisfied by the tarball and not looked up on a registry.
(cd "$work/prefix" && npm init -y >/dev/null && npm install --silent --no-audit --no-fund "$work"/tarballs/*.tgz)

nm="$work/prefix/node_modules"
bin="$nm/.bin"
# Resolved through symlinks, as node resolves it: /var is /private/var on macOS.
pkgbin="$(cd "$nm/@imunitic/synapse-$plat/bin" && pwd -P)"
[ -x "$pkgbin/synapse" ] && [ -x "$pkgbin/synapse-hook" ] || fail "the platform package holds no binaries"

# The shims resolve the binaries.
out="$("$bin/synapse" now)" || fail "synapse now through the shim"
[[ "$out" =~ ^20[0-9]{2}- ]] || fail "synapse now printed '$out'"
"$bin/synapse-hook" --help 2>&1 | grep -q "usage: synapse-hook" || fail "synapse-hook through the shim"
echo "  shims ok"

# Configure Claude Code in a machine of its own.
home="$work/home"
mkdir -p "$home/.claude" "$home/.config"
export HOME="$home"
unset XDG_CONFIG_HOME CLAUDE_PLUGIN_ROOT
"$bin/synapse-setup" configure claude >/dev/null || fail "synapse-setup configure claude"
settings="$home/.claude/settings.json"
[ -f "$settings" ] || fail "no settings.json written"
for hook in session-start prompt-context staleness stop-nudge; do
    cmd="$(jq -r --arg h "$hook" '[.hooks[][].hooks[].command | select(endswith(" " + $h))] | first // empty' "$settings")"
    [ -n "$cmd" ] || fail "settings.json registers no '$hook' hook"
    [ "${cmd%% *}" = "$pkgbin/synapse-hook" ] || fail "'$hook' runs ${cmd%% *}, not the installed hook binary"
done
ls "$home/.claude/skills" | grep -q "synapse-query" || fail "no skills copied"
echo "  configure claude ok"

"$bin/synapse-setup" configure codex >/dev/null || fail "synapse-setup configure codex"
jq -e --arg bin "$pkgbin/synapse-hook" '[.hooks[][].hooks[].command | startswith($bin + " ")] | length > 0 and all' "$home/.codex/hooks.json" >/dev/null \
    || fail "codex hooks do not run the installed hook binary"
"$bin/synapse-setup" configure opencode >/dev/null || fail "synapse-setup configure opencode"
grep -qF "$pkgbin/synapse-hook" "$home/.config/opencode/plugin/synapse.js" || fail "the opencode plugin does not name the installed hook binary"
echo "  configure codex, opencode ok"

# The installed hooks, run the way Claude Code runs them.
vault="$work/vault"
mkdir -p "$vault"
printf '# the vault index\n' > "$vault/Index.md"
export SYNAPSE_VAULT_DIR="$vault" SYNAPSE_CONTENT_ROOT="$nm/@imunitic/synapse"
hook="$pkgbin/synapse-hook"
ctx="$(printf '{"cwd":"%s"}' "$work" | "$hook" session-start)" || fail "session-start exited non-zero"
echo "$ctx" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null || fail "session-start gave no context"
echo "$ctx" | jq -r '.hookSpecificOutput.additionalContext' | grep -q "the vault index" || fail "session-start left out the vault index"
printf '{"prompt":"hi","cwd":"%s"}' "$work" | "$hook" prompt-context >/dev/null || fail "prompt-context exited non-zero"
printf '{"session_id":"x"}' | "$hook" stop-nudge >/dev/null || fail "stop-nudge exited non-zero"
printf '{"tool_input":{"file_path":"/nowhere"}}' | "$hook" staleness >/dev/null || fail "staleness exited non-zero"
"$hook" wat >/dev/null 2>&1 && fail "an unknown hook should not exit 0"
echo "  hooks ok"

echo "package ok ($plat)"
