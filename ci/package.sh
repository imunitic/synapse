#!/bin/bash
# Assembles the npm packages around the Ada release binaries of this
# machine's platform, installs them into a scratch prefix as a user would, and
# checks the installed program end to end: the `synapse` and `synapse-hook`
# shims find the binaries, `synapse-setup configure claude` wires the hooks to
# the installed hook binary, and that binary answers as a hook does. The
# synapse-pipeline packages are installed beside them, the installed
# `synapse-pipeline` runs a pipeline from a script, and `synapse-pipeline-setup`
# installs the pipeline skills, whose examples are checked, and `next` steps a
# pipeline one result at a time.
#
#   ci/package.sh [--keep]
#
# Needs `synapse_cli/bin/synapse` and `synapse_cli/bin/synapse-hook` built with
# `alr build --release` in synapse_cli, and `synapse_pipeline/bin/synapse-pipeline`
# built the same way in synapse_pipeline. --keep leaves the scratch directory in place.
set -euo pipefail

cd "$(dirname "$0")/.."
root="$PWD"
keep=0
[ "${1:-}" = "--keep" ] && keep=1

# Git Bash on Windows: the binaries end in .exe, node and the programs it starts
# read native paths, and the home directory is USERPROFILE.
exe=""
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) exe=".exe" ;; esac
native() { if [ -n "$exe" ]; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

for tool in node npm jq; do
    command -v "$tool" >/dev/null || { echo "$tool not on PATH" >&2; exit 1; }
done
for bin in synapse synapse-hook; do
    [ -x "synapse_cli/bin/$bin$exe" ] || { echo "synapse_cli/bin/$bin$exe missing -- run: just release" >&2; exit 1; }
done
[ -x "synapse_pipeline/bin/synapse-pipeline$exe" ] \
    || { echo "synapse_pipeline/bin/synapse-pipeline$exe missing -- run: just release" >&2; exit 1; }

# On Linux, when a floor is named, the binaries must not ask for a newer glibc.
if [ -n "${GLIBC_FLOOR:-}" ] && [ "$(uname -s)" = Linux ]; then
    for b in synapse_cli/bin/synapse synapse_cli/bin/synapse-hook synapse_pipeline/bin/synapse-pipeline; do
        top="$(objdump -T "$b" | grep -o 'GLIBC_[0-9.]*' | sed 's/GLIBC_//' | sort -Vu | tail -1)"
        [ "$(printf '%s\n%s\n' "$top" "$GLIBC_FLOOR" | sort -V | tail -1)" = "$GLIBC_FLOOR" ] \
            || { echo "FAIL: $(basename "$b") needs glibc $top, above $GLIBC_FLOOR" >&2; exit 1; }
    done
    echo "  glibc floor $GLIBC_FLOOR ok"
fi

plat="$(node -p 'process.platform + "-" + process.arch')"
[ -d "packages/synapse/platforms/$plat" ] || { echo "no npm platform package for $plat" >&2; exit 1; }
[ -d "packages/synapse-pipeline/platforms/$plat" ] || { echo "no synapse-pipeline platform package for $plat" >&2; exit 1; }

work="$(mktemp -d)"
cleanup() { [ "$keep" = 1 ] && echo "kept $work" || rm -rf "$work"; }
trap cleanup EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# The packages, copied so the checkout is never written to.
cp -R packages/synapse "$work/pkg"
mkdir -p "$work/pkg/platforms/$plat/bin"
cp "synapse_cli/bin/synapse$exe" "synapse_cli/bin/synapse-hook$exe" "$work/pkg/platforms/$plat/bin/"
cp -R packages/synapse-pipeline "$work/pipeline-pkg"
mkdir -p "$work/pipeline-pkg/platforms/$plat/bin"
cp "synapse_pipeline/bin/synapse-pipeline$exe" "$work/pipeline-pkg/platforms/$plat/bin/"

mkdir -p "$work/tarballs" "$work/prefix"
(cd "$work/tarballs" \
    && npm pack "$work/pkg/platforms/$plat" --silent >/dev/null && npm pack "$work/pkg" --silent >/dev/null \
    && npm pack "$work/pipeline-pkg/platforms/$plat" --silent >/dev/null && npm pack "$work/pipeline-pkg" --silent >/dev/null)
ls "$work/tarballs" | sed 's/^/  packed /'

# Both in one install, so the main package's optional dependency on the
# platform package is satisfied by the tarball and not looked up on a registry.
(cd "$work/prefix" && npm init -y >/dev/null && npm install --silent --no-audit --no-fund "$work"/tarballs/*.tgz)

nm="$work/prefix/node_modules"
bin="$nm/.bin"
# A path as node's real path, with `/` between the parts: /var is /private/var
# on macOS, and a Windows temp directory may be spelled with a short name
# (RUNNER~1) in one place and its long name in another.
canon() { node -p "require('fs').realpathSync.native(process.argv[1]).split(require('path').sep).join('/')" "$1"; }
pkgbin="$(canon "$nm/@imunitic/synapse-$plat/bin")"
[ -x "$pkgbin/synapse$exe" ] && [ -x "$pkgbin/synapse-hook$exe" ] || fail "the platform package holds no binaries"

# The shims resolve the binaries.
out="$("$bin/synapse" now)" || fail "synapse now through the shim"
[[ "$out" =~ ^20[0-9]{2}- ]] || fail "synapse now printed '$out'"
"$bin/synapse-hook" --help 2>&1 | grep -q "usage: synapse-hook" || fail "synapse-hook through the shim"
echo "  shims ok"

# Configure Claude Code in a machine of its own.
home="$work/home"
mkdir -p "$home/.claude" "$home/.config"
export HOME="$home"
[ -z "$exe" ] || export USERPROFILE="$(native "$home")"
unset XDG_CONFIG_HOME CLAUDE_PLUGIN_ROOT
"$bin/synapse-setup" configure claude >/dev/null || fail "synapse-setup configure claude"
settings="$home/.claude/settings.json"
[ -f "$settings" ] || fail "no settings.json written"
for hook in session-start prompt-context staleness stop-nudge; do
    cmd="$(jq -r --arg h "$hook" '[.hooks[][].hooks[].command | select(endswith(" " + $h))] | first // empty' "$settings")"
    [ -n "$cmd" ] || fail "settings.json registers no '$hook' hook"
    [ "$(canon "${cmd%% *}")" = "$pkgbin/synapse-hook$exe" ] || fail "'$hook' runs ${cmd%% *}, not the installed hook binary"
done
ls "$home/.claude/skills" | grep -q "synapse-query" || fail "no skills copied"
echo "  configure claude ok"

"$bin/synapse-setup" configure codex >/dev/null || fail "synapse-setup configure codex"
codex_bins="$(jq -r '[.hooks[][].hooks[].command | split(" ")[0]] | unique | .[]' "$home/.codex/hooks.json" | tr -d '\r')"
[ -n "$codex_bins" ] || fail "codex hooks name no binary"
for b in $codex_bins; do
    [ "$(canon "$b")" = "$pkgbin/synapse-hook$exe" ] || fail "codex hooks do not run the installed hook binary"
done
"$bin/synapse-setup" configure opencode >/dev/null || fail "synapse-setup configure opencode"
plugin_bin="$(grep -o '"[^"]*synapse-hook[^"]*"' "$home/.config/opencode/plugin/synapse.js" | head -1 | tr -d '"')"
[ -n "$plugin_bin" ] && [ "$(canon "$plugin_bin")" = "$pkgbin/synapse-hook$exe" ] || fail "the opencode plugin does not name the installed hook binary"
echo "  configure codex, opencode ok"

# The installed hooks, run the way Claude Code runs them.
vault="$work/vault"
mkdir -p "$vault"
printf '# the vault index\n' > "$vault/Index.md"
export SYNAPSE_VAULT_DIR="$(native "$vault")" SYNAPSE_CONTENT_ROOT="$(native "$nm")/@imunitic/synapse"
hook="$pkgbin/synapse-hook$exe"
ctx="$(printf '{"cwd":"%s"}' "$(native "$work")" | "$hook" session-start)" || fail "session-start exited non-zero"
echo "$ctx" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' >/dev/null || fail "session-start gave no context"
echo "$ctx" | jq -r '.hookSpecificOutput.additionalContext' | grep -q "the vault index" || fail "session-start left out the vault index"
printf '{"prompt":"hi","cwd":"%s"}' "$(native "$work")" | "$hook" prompt-context >/dev/null || fail "prompt-context exited non-zero"
printf '{"session_id":"x"}' | "$hook" stop-nudge >/dev/null || fail "stop-nudge exited non-zero"
printf '{"tool_input":{"file_path":"/nowhere"}}' | "$hook" staleness >/dev/null || fail "staleness exited non-zero"
"$hook" wat >/dev/null 2>&1 && fail "an unknown hook should not exit 0"
echo "  hooks ok"

# The installed synapse-pipeline: its shim finds the binary, and the binary
# checks and runs a pipeline from a script, with no harness on the machine.
pipebin="$(canon "$nm/@imunitic/synapse-pipeline-$plat/bin")"
[ -x "$pipebin/synapse-pipeline$exe" ] || fail "the synapse-pipeline platform package holds no binary"
"$bin/synapse-pipeline" --help 2>&1 | grep -q "usage: synapse-pipeline" || fail "synapse-pipeline through the shim"
mkdir -p "$work/defs"
printf 'Pipeline Smoke {\n   Build [Harness => Claude, Prompt => "Build it."];\n   Review [Harness => Claude, Prompt => "Review it."];\n}\n' > "$work/defs/Smoke.synapse"
printf '{"Build":[{"outcome":"Done","summary":"built","data":{}}],"Review":[{"outcome":"Approved","summary":"packaged ok","data":{}}]}\n' > "$work/answers.json"
export SYNAPSE_PIPELINE_PATH="$(native "$work/defs")" SYNAPSE_PIPELINE_RUNNER=scripted SYNAPSE_PIPELINE_SCRIPT="$(native "$work/answers.json")"
"$bin/synapse-pipeline" check Smoke >/dev/null || fail "synapse-pipeline check through the shim"
result="$("$bin/synapse-pipeline" run Smoke 2>/dev/null)" || fail "synapse-pipeline run through the shim"
echo "$result" | jq -e '.outcome == "Approved" and .summary == "packaged ok"' >/dev/null || fail "synapse-pipeline run printed '$result'"
echo "  synapse-pipeline ok"

# `next`, through the shim: a run driven one step at a time ends where it ends.
state="$work/state.json"
"$bin/synapse-pipeline" next Smoke > "$state" || fail "synapse-pipeline next (start)"
jq -e '.status == "running" and .current_step == "Build"' "$state" >/dev/null || fail "next started at '$(jq -r .current_step "$state")'"
printf '{"outcome":"Done","summary":"built","data":{}}\n' > "$work/r1.json"
"$bin/synapse-pipeline" next Smoke --state "$(native "$state")" --result "$(native "$work/r1.json")" > "$work/state2.json" \
    || fail "synapse-pipeline next (first result)"
jq -e '.status == "running" and .current_step == "Review" and .steps_run == 1' "$work/state2.json" >/dev/null || fail "next did not move on to Review"
printf '{"outcome":"Approved","summary":"packaged ok","data":{}}\n' > "$work/r2.json"
"$bin/synapse-pipeline" next Smoke --state "$(native "$work/state2.json")" --result "$(native "$work/r2.json")" > "$work/state3.json" \
    || fail "synapse-pipeline next (last result)"
jq -e '.status == "completed" and .previous_output.summary == "packaged ok"' "$work/state3.json" >/dev/null || fail "next did not complete the run"
echo "  synapse-pipeline next ok"

# The skills that teach an agent to write and to run pipelines: installed for each harness
# beside the Synapse skills without disturbing them, and every example
# definition in it passes the installed `check`.
for h in claude codex opencode; do
    "$bin/synapse-pipeline-setup" configure "$h" >/dev/null || fail "synapse-pipeline-setup configure $h"
done
for d in .claude/skills .codex/skills .config/opencode/skill; do
    [ -f "$home/$d/synapse-pipeline/SKILL.md" ] || fail "no synapse-pipeline skill in $d"
    [ -f "$home/$d/synapse-pipeline-execute/SKILL.md" ] || fail "no synapse-pipeline-execute skill in $d"
    [ -f "$home/$d/synapse-query/SKILL.md" ] || fail "synapse-pipeline-setup removed a Synapse skill from $d"
done
"$bin/synapse-setup" configure claude >/dev/null || fail "synapse-setup configure claude after the pipeline skill"
[ -f "$home/.claude/skills/synapse-pipeline/SKILL.md" ] || fail "synapse-setup removed the synapse-pipeline skill"
mkdir -p "$work/skilldefs"
node -e '
const fs = require("fs"), path = require("path");
const text = fs.readFileSync(process.argv[1], "utf8");
let n = 0;
for (const m of text.matchAll(/```\n-- (\w+\.synapse)\n([\s\S]*?)```/g)) {
  fs.writeFileSync(path.join(process.argv[2], m[1]), `-- ${m[1]}\n${m[2]}`);
  n++;
}
if (n < 2) { console.error("no example definitions in the skill"); process.exit(1); }
' "$home/.claude/skills/synapse-pipeline/SKILL.md" "$work/skilldefs" || fail "reading the skill's examples"
for example in Develop_Feature Review_Change Ready_Gate; do
    SYNAPSE_PIPELINE_PATH="$(native "$work/skilldefs")" "$bin/synapse-pipeline" check "$example" >/dev/null \
        || fail "the skill's example pipeline $example does not pass check"
done
echo "  synapse-pipeline skill ok"

echo "package ok ($plat)"
