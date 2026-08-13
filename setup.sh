#!/bin/bash
# Installs the portable Synapse tooling (CLAUDE.md, hooks, commands, skills,
# scripts) into ~/.claude on this machine. Merges into existing
# settings.json rather than overwriting it. Does NOT touch Obsidian
# itself, plugin installs, API keys/certs, or note content -- see
# setup-obsidian-mcp.sh and the README for those.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/claude"
DEST="$HOME/.claude"

command -v jq >/dev/null || { echo "jq is required. Install it first (e.g. brew install jq)." >&2; exit 1; }

# THE BINARIES ARE A PRECONDITION, and this check is deliberately here -- before
# anything at all is written -- rather than beside the copy step.
#
# `synapse` and `synapse-hook` *are* the tooling: no shell library stands behind
# them any more. Earlier this script noted their absence and carried on, then wired
# settings.json to `~/.claude/bin/synapse-hook` regardless. That produced exactly the
# state `synapse doctor` exists to shout about, and worse than the comment claimed:
# the hooks are built to exit 0 on every missing precondition, but a hook whose
# *executable* is missing never runs to exit anything, so every turn and every edit
# surfaces a launch failure instead of silence.
#
# So: refuse the whole install, loudly, and leave the machine as it was. Both paths
# are overridable because a release tarball ships built binaries and has no
# toolchain to build them with -- the alternative to an override there is no
# supported install at all.
SYNAPSE_BIN="${SYNAPSE_BIN:-$HERE/zig-out/bin/synapse}"
SYNAPSE_HOOK_BIN="${SYNAPSE_HOOK_BIN:-$HERE/zig-out/bin/synapse-hook}"
missing=()
[ -x "$SYNAPSE_BIN" ] || missing+=("$SYNAPSE_BIN")
[ -x "$SYNAPSE_HOOK_BIN" ] || missing+=("$SYNAPSE_HOOK_BIN")
if [ "${#missing[@]}" -gt 0 ]; then
  {
    echo "setup.sh: the binaries this installs are not built yet:"
    printf '  %s\n' "${missing[@]}"
    echo
    echo "Build them first, from this checkout:"
    echo "  zig build        (or: just build)"
    echo
    echo "Or point \$SYNAPSE_BIN and \$SYNAPSE_HOOK_BIN at prebuilt ones."
    echo
    echo "Nothing was installed. This is a hard stop rather than a warning because"
    echo "the hook wiring below would otherwise name a program that does not exist,"
    echo "and every turn would fail to launch it."
  } >&2
  exit 1
fi

mkdir -p "$DEST/commands" "$DEST/bin"

echo "== CLAUDE.md / synapse-claude.md =="
# Synapse-owned content lives in synapse-claude.md, installed unconditionally
# every run -- same treatment as skills/hooks below. CLAUDE.md itself stays
# entirely the user's own file and is never overwritten; the only thing this
# does to it is make sure one @import line pointing at synapse-claude.md is
# present, appending it if missing. That line is what makes an edit to this
# content actually reach every machine on re-run, rather than the old
# behavior: install once, then refuse forever the moment CLAUDE.md has
# diverged at all, silently orphaning every future edit.
cp "$SRC/synapse-claude.md" "$DEST/synapse-claude.md"
echo "  synapse-claude.md installed."

IMPORT_LINE='@~/.claude/synapse-claude.md'
if [ ! -f "$DEST/CLAUDE.md" ]; then
  printf '%s\n' "$IMPORT_LINE" > "$DEST/CLAUDE.md"
  echo "  CLAUDE.md created with the import line."
elif grep -qF "$IMPORT_LINE" "$DEST/CLAUDE.md"; then
  echo "  CLAUDE.md already imports synapse-claude.md."
else
  printf '\n%s\n' "$IMPORT_LINE" >> "$DEST/CLAUDE.md"
  echo "  added the import line to the end of existing CLAUDE.md."
  echo "  NOTE: if CLAUDE.md already has an old inline copy of this content"
  echo "  (from before synapse-claude.md existed), it's now redundant --"
  echo "  safe to delete by hand, the import above covers it."
fi

# Migrate the pre-rename filenames before the install checks below, or an existing
# machine gets a fresh template alongside its real config and silently loses its
# vault path. A move rather than a copy: two files, one of them stale, is worse
# than either alone -- and the readers fall back to the old name only so that
# scripts updated ahead of this script keep working, not as a place to keep
# config permanently.
echo "== config filenames =="
for pair in "second-brain.conf:synapse.conf" "second-brain-projects.conf:synapse-projects.conf"; do
  old="${pair%%:*}"; new="${pair##*:}"
  if [ -f "$DEST/$old" ] && [ ! -f "$DEST/$new" ]; then
    mv "$DEST/$old" "$DEST/$new"
    echo "  renamed (project rename): $old -> $new"
  elif [ -f "$DEST/$old" ] && [ -f "$DEST/$new" ]; then
    echo "  WARNING both $old and $new exist -- $new is the one that is read."
    echo "  Merge anything you need out of $old, then delete it."
  fi
done

echo "== synapse.conf =="
if [ -f "$DEST/synapse.conf" ]; then
  echo "  already exists, leaving in place: $DEST/synapse.conf"
else
  cp "$SRC/synapse.conf.template" "$DEST/synapse.conf"
  echo "  installed from template -- EDIT THIS FILE (paths are machine-specific): $DEST/synapse.conf"
fi

echo "== synapse-projects.conf =="
if [ -f "$DEST/synapse-projects.conf" ]; then
  echo "  already exists, leaving in place: $DEST/synapse-projects.conf"
else
  cp "$SRC/synapse-projects.conf.template" "$DEST/synapse-projects.conf"
  echo "  installed from template -- machine-local, self-managed by /synapse-note: $DEST/synapse-projects.conf"
fi

echo "== synapse-module-boilerplate.conf =="
if [ -f "$DEST/synapse-module-boilerplate.conf" ]; then
  echo "  already exists, leaving in place: $DEST/synapse-module-boilerplate.conf"
else
  cp "$SRC/synapse-module-boilerplate.conf.template" "$DEST/synapse-module-boilerplate.conf"
  echo "  installed from template -- edit to add your own ecosystem's src/ conventions: $DEST/synapse-module-boilerplate.conf"
fi

echo "== synapse-ignore-files.conf =="
if [ -f "$DEST/synapse-ignore-files.conf" ]; then
  echo "  already exists, leaving in place: $DEST/synapse-ignore-files.conf"
else
  cp "$SRC/synapse-ignore-files.conf.template" "$DEST/synapse-ignore-files.conf"
  echo "  installed from template -- excludes nothing extra by default: $DEST/synapse-ignore-files.conf"
fi

echo "== synapse-prompt-stopwords.conf =="
if [ -f "$DEST/synapse-prompt-stopwords.conf" ]; then
  echo "  already exists, leaving in place: $DEST/synapse-prompt-stopwords.conf"
else
  cp "$SRC/synapse-prompt-stopwords.conf.template" "$DEST/synapse-prompt-stopwords.conf"
  echo "  installed from template -- edit to add another language's stopwords: $DEST/synapse-prompt-stopwords.conf"
fi

echo "== commands/skills =="
cp "$SRC/commands/"*.md "$DEST/commands/"
# Every skill directory, discovered rather than listed. Naming each one meant a new
# skill silently did not install until someone remembered to add a line here --
# the same mistake the bin/ glob was introduced to fix, and it had already been
# made once by the time there were three of them.
for skill_dir in "$SRC/skills/"*/; do
    skill_name="$(basename "$skill_dir")"
    [ -f "$skill_dir/SKILL.md" ] || continue
    mkdir -p "$DEST/skills/$skill_name"
    cp "$skill_dir/SKILL.md" "$DEST/skills/$skill_name/SKILL.md"
done
echo "  installed."
# Copied rather than built: `zig build` belongs to the checkout (`just build`), and
# running a compiler from an installer would make this step slow, network-capable and
# dependent on a toolchain a tarball install does not have. Their existence was
# settled at the top of this script, so there is no branch here.
#
# Two binaries rather than one, deliberately: a hook runs on every edit and every
# turn, so `synapse-hook` links no tree-sitter and no C library at all.
cp "$SYNAPSE_BIN" "$DEST/bin/synapse"
chmod +x "$DEST/bin/synapse"
echo "  installed binary: $DEST/bin/synapse"

cp "$SYNAPSE_HOOK_BIN" "$DEST/bin/synapse-hook"
chmod +x "$DEST/bin/synapse-hook"
echo "  installed binary: $DEST/bin/synapse-hook"
# This script copies in but never deletes, so scripts that moved out of bin/
# and into lib/synapse/ during the porcelain rewrite linger in $DEST/bin/ on an
# existing machine -- unreferenced but still executable and still on PATH,
# which is worse than absent because a stray old copy can shadow the real one.
# The whole shell library is gone: `synapse` and `synapse-hook` are the tooling.
# This script copies in but never deletes, so an existing machine keeps every
# script it was ever given -- unreferenced but still executable, and in bin/ still
# on PATH, which is worse than absent because a stray old copy can shadow nothing
# and yet still be run by hand or by a hand-edited settings.json.
# Globbed by prefix, not by extension: `hooks/` and `bin/` are shared with every
# other tool the user installs into ~/.claude, and an unprefixed glob claimed one of
# those -- claude-code-setup's check-update.sh, wired into SessionStart -- was
# unreferenced. Both of Synapse's own prefixes count, since `second-brain-*` is what
# the hooks were called before the rename and those linger on an old machine too.
stale=()
for f in "$DEST/bin/"synapse*.sh "$DEST/bin/"second-brain*.sh \
         "$DEST/hooks/"synapse-*.sh "$DEST/hooks/"second-brain-*.sh \
         "$DEST/lib/synapse/"*.sh; do
  [ -e "$f" ] && stale+=("$f")
done
if [ "${#stale[@]}" -gt 0 ]; then
  echo "  NOTE: ${#stale[@]} shell script(s) from before the Zig rewrite are still installed."
  echo "    Nothing references them: the hooks are now 'synapse-hook <name>' and every"
  echo "    command is a subcommand of 'synapse'. Safe to remove by hand:"
  printf '    %s\n' "${stale[@]}"
  echo "    (or: rm -rf $DEST/lib/synapse $DEST/hooks/{synapse,second-brain}-*.sh $DEST/bin/{synapse,second-brain}*.sh)"
fi
if [ -d "$DEST/skills/obsidian-task" ] || [ -f "$DEST/bin/second-brain-switch" ] || ls "$DEST/commands/obsidian-"*.md >/dev/null 2>&1 || [ -d "$DEST/skills/org-task" ]; then
  echo "  NOTE: found stale files from before the sb- rename / org-roam removal --"
  echo "    $DEST/skills/obsidian-task/, $DEST/skills/org-task/, $DEST/bin/second-brain-switch,"
  echo "    $DEST/commands/obsidian-*.md are no longer installed by this script and are safe"
  echo "    to remove by hand."
fi
# The sb- -> synapse- rename. Worth its own louder warning than the note above,
# because these are not merely unused: a leftover commands/sb-note.md still
# registers as /sb-note, so the command list shows two of everything and only one
# is maintained. Claude Code discovers commands by filename, so nothing here can
# deduplicate them -- only deleting the old file can.
if ls "$DEST/commands/sb-"*.md >/dev/null 2>&1 || [ -d "$DEST/skills/sb-task" ]; then
  echo "  WARNING: found pre-rename copies of the renamed commands/skill:"
  ls "$DEST/commands/sb-"*.md 2>/dev/null | sed 's/^/    /'
  [ -d "$DEST/skills/sb-task" ] && echo "    $DEST/skills/sb-task/"
  echo "    They are no longer installed, but they still REGISTER -- you will see both"
  echo "    /sb-note and /synapse-note until you delete them. Remove them by hand."
fi

echo "== settings.json hook wiring =="
SETTINGS="$DEST/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

TMP="$(mktemp)"
jq '
  # Rewrite existing hook commands BEFORE the add-if-missing logic below. That
  # order is the whole difficulty of moving a hook: settings.json references hooks
  # by command string, and this script copies in without deleting -- so without
  # this pass an existing machine ends up with the old entry AND the new one, both
  # runnable, and every hook fires twice. Two index injections, two nudges, two
  # vault commits per write.
  #
  # Two generations to rewrite now: the pre-rename `second-brain-*.sh` names, and
  # the shell wrappers that the Zig rewrite replaced. A wrapper still on disk
  # would still work, which is exactly why the entry has to be rewritten rather
  # than left for the user to notice.
  #
  # Scoped to the hook arrays rather than walk(), so an unrelated `command`
  # elsewhere in settings.json (a statusLine, for instance) is never touched.
  def fixcmd:
    if type == "string" then
        gsub("second-brain-(?<n>session-start|stop-nudge|db-sync)\\.sh"; "synapse-\(.n).sh")
      | gsub("bash +~/\\.claude/hooks/synapse-(?<n>[a-z-]+)\\.sh"; "~/.claude/bin/synapse-hook \(.n)")
      | gsub("~/\\.claude/hooks/synapse-(?<n>[a-z-]+)\\.sh"; "~/.claude/bin/synapse-hook \(.n)")
    else . end;
  # Order-preserving dedupe: if a machine had both spellings, the rewrite above
  # makes them identical, and two identical entries fire twice.
  def dedupe: reduce .[] as $x ([]; if any(.[]; . == $x) then . else . + [$x] end);
  .hooks = ((.hooks // {}) | map_values(
      map(.hooks = ((.hooks // []) | map(.command |= fixcmd))) | dedupe)) |

  .hooks = (.hooks // {}) |
  .hooks.SessionStart = (.hooks.SessionStart // []) |
  .hooks.PostToolUse = (.hooks.PostToolUse // []) |
  .hooks.Stop = (.hooks.Stop // []) |
  .hooks.UserPromptSubmit = (.hooks.UserPromptSubmit // []) |
  (if any(.hooks.SessionStart[]?.hooks[]?; .command == "~/.claude/bin/synapse-hook session-start")
   then . else .hooks.SessionStart += [{"hooks":[{"type":"command","command":"~/.claude/bin/synapse-hook session-start"}]}] end) |
  (if any(.hooks.UserPromptSubmit[]?.hooks[]?; .command == "~/.claude/bin/synapse-hook prompt-context")
   then . else .hooks.UserPromptSubmit += [{"hooks":[{"type":"command","command":"~/.claude/bin/synapse-hook prompt-context"}]}] end) |
  (if any(.hooks.PostToolUse[]?.hooks[]?; .command == "~/.claude/bin/synapse-hook db-sync")
   then . else .hooks.PostToolUse += [{"matcher":"Write|Edit|mcp__obsidian__vault_(write|patch|append|delete|move)","hooks":[{"type":"command","command":"~/.claude/bin/synapse-hook db-sync"}]}] end) |
  (if any(.hooks.PostToolUse[]?.hooks[]?; .command == "~/.claude/bin/synapse-hook staleness")
   then . else .hooks.PostToolUse += [{"matcher":"Write|Edit|MultiEdit","hooks":[{"type":"command","command":"~/.claude/bin/synapse-hook staleness"}]}] end) |
  (if any(.hooks.Stop[]?.hooks[]?; .command == "~/.claude/bin/synapse-hook stop-nudge")
   then . else .hooks.Stop += [{"hooks":[{"type":"command","command":"~/.claude/bin/synapse-hook stop-nudge"}]}] end)
' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
echo "  merged (idempotent -- safe to re-run)."

cat <<'EOF'

== Done with the automatable part. Manual steps remaining: ==

1. Edit ~/.claude/synapse.conf -- set OBSIDIAN_VAULT_DIR for this
   machine.
2. Install Obsidian.app, open your vault.
3. Settings -> Community plugins -> Browse -> install + enable:
   "Local REST API with MCP", "Headless Mode", "Iconic" (optional).
4. Run: ./setup-obsidian-mcp.sh <path-to-vault>
   (extracts the plugin's generated cert + API key, registers the
   MCP server, wires up NODE_EXTRA_CA_CERTS -- all automatic once
   the plugin is installed and has generated its data.json).
5. Optionally add Obsidian to login items and enable "Start headless"
   in the Headless Mode plugin settings, so it runs like a background
   daemon (see README).
6. Restart Claude Code so the new hooks/settings/MCP registration
   actually take effect for the running session.
EOF
