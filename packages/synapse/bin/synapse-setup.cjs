#!/usr/bin/env node
// The single install/configure entry point for every harness Synapse
// supports (Claude Code, Codex CLI, OpenCode) -- the npm-packaged
// successor to harnesses/setup.cjs, now covering Claude Code too instead of
// leaving it to a separate marketplace-plugin packaging path.
//
//   synapse-setup configure <harness>
//
// The binaries themselves need no step here at all: `npm install` already
// pulled in the right @imunitic/synapse-{platform}-{arch} optionalDependency
// (see lib/resolve-binaries.cjs). `configure <harness>` is what actually
// needs the human: which harnesses to wire up is a per-machine choice this
// script can't infer.

"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const { hookPath, platformPackageName, HOOK_NAME } = require("../lib/resolve-binaries.cjs");

const PKG_ROOT = path.join(__dirname, "..");

async function main() {
  const args = process.argv.slice(2);
  const known = ["claude", "codex", "opencode"];
  const usage = () => {
    console.error("usage: synapse-setup configure <harness>");
    console.error(`  <harness> is one of: ${known.join(", ")}`);
  };

  if (args[0] === "configure") {
    if (!args[1] || !known.includes(args[1])) {
      usage();
      process.exitCode = 1;
      return;
    }
    configure(args[1]);
    return;
  }

  usage();
  process.exitCode = 1;
}

function resolveHookBin() {
  const hookBin = hookPath();
  if (!hookBin) {
    fail(
      `${platformPackageName()} isn't installed -- either this platform has no published build yet, ` +
        `or npm skipped it. Try "npm install" again, or check that ${platformPackageName()} exists.`
    );
  }
  return hookBin;
}

function configure(harness) {
  bootstrapSynapseConf();
  if (harness === "claude") return configureClaude();
  if (harness === "codex") return configureCodex();
  if (harness === "opencode") return configureOpencode();
}

// ---------------------------------------------------------------------------
// Shared: synapse.conf bootstrap, skill/command copies, JSON merge helpers
// ---------------------------------------------------------------------------

// Mirrors `core.conf.resolveConfPath`/`resolveWritePath`'s own three-tier
// order for `synapse.conf` specifically (see `docs/synapse/synapse-config.md`
// "Where a conf file actually lives"), so a fresh machine gets a real file to
// edit instead of a silent gap the next `SessionStart` hook has to explain.
// A no-op once any tier already has a file -- re-running `configure` never
// overwrites an existing choice, deliberate or inherited.
function bootstrapSynapseConf() {
  const home = os.homedir();
  const xdg = process.env.XDG_CONFIG_HOME;
  const candidates = [];
  if (xdg) candidates.push(path.join(xdg, "synapse", "synapse.conf"));
  candidates.push(path.join(home, ".config", "synapse", "synapse.conf"));
  candidates.push(path.join(home, ".claude", "synapse.conf"));
  if (candidates.some((p) => fs.existsSync(p))) return;

  let dest;
  if (xdg) dest = path.join(xdg, "synapse", "synapse.conf");
  else if (fs.existsSync(path.join(home, ".config")) && fs.statSync(path.join(home, ".config")).isDirectory())
    dest = path.join(home, ".config", "synapse", "synapse.conf");
  else dest = path.join(home, ".claude", "synapse.conf");

  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.copyFileSync(path.join(PKG_ROOT, "synapse.conf.template"), dest);
  console.log(`wrote ${dest} -- edit SYNAPSE_VAULT_DIR in it before your next session`);
}

// The manifest recording exactly which names this tool wrote into a given
// destination on the prior run -- diffed against the current run's names
// so a renamed or removed skill/command is deleted instead of left behind
// as an orphan forever. Scoped strictly to names a previous manifest
// actually listed: anything else living in the same directory (a skill
// from a different source, or the user's own) was never in that manifest
// and is never touched. Lives inside `destRoot` itself, as a dotfile --
// no `.md` extension and not a `{name}/SKILL.md` subdirectory, so no
// harness's own skill/command discovery mistakes it for one of ours.
const MANAGED_MANIFEST = ".synapse-managed.json";

function pruneStale(destRoot, currentNames) {
  const manifestPath = path.join(destRoot, MANAGED_MANIFEST);
  let previous = [];
  if (fs.existsSync(manifestPath)) {
    try {
      previous = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
    } catch {
      previous = [];
    }
  }
  const current = new Set(currentNames);
  for (const name of previous) {
    if (current.has(name)) continue;
    fs.rmSync(path.join(destRoot, name), { recursive: true, force: true });
  }
  fs.mkdirSync(destRoot, { recursive: true });
  fs.writeFileSync(manifestPath, JSON.stringify(currentNames, null, 2) + "\n");
}

// Copies every shared SKILL.md into `destRoot/{name}/SKILL.md`. Each skill
// gets its own uniquely-named subdirectory, so overwriting ours on every run
// never touches anything a harness's own skill discovery also finds there
// under a different name. Returns the names written -- pruning stale ones is
// the caller's job, since a destRoot shared with another source (Codex's own
// skills, on top of these) needs the combined set before it can prune safely.
function copySkills(destRoot) {
  const src = path.join(PKG_ROOT, "skills");
  const names = fs
    .readdirSync(src, { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .map((e) => e.name);
  fs.mkdirSync(destRoot, { recursive: true });
  for (const name of names) {
    const destDir = path.join(destRoot, name);
    fs.mkdirSync(destDir, { recursive: true });
    fs.copyFileSync(path.join(src, name, "SKILL.md"), path.join(destDir, "SKILL.md"));
  }
  return names;
}

function copyCommands(destRoot) {
  const src = path.join(PKG_ROOT, "commands");
  const names = fs.readdirSync(src).filter((f) => f.endsWith(".md"));
  fs.mkdirSync(destRoot, { recursive: true });
  for (const name of names) {
    fs.copyFileSync(path.join(src, name), path.join(destRoot, name));
  }
  return names;
}

function backupIfExists(filePath) {
  if (!fs.existsSync(filePath)) return;
  fs.copyFileSync(filePath, `${filePath}.bak`);
}

// A generic hooks.json-shaped template (harness/{claude,codex}/hooks.json
// both use this shape): swaps the leading bare "synapse-hook" token in each
// command string for the real installed absolute path.
function renderHooksTemplate(templatePath, hookBin) {
  const template = JSON.parse(fs.readFileSync(templatePath, "utf8"));
  for (const groups of Object.values(template.hooks)) {
    for (const group of groups) {
      for (const hook of group.hooks) {
        if (hook.command.startsWith(`${HOOK_NAME} `)) {
          hook.command = hookBin + hook.command.slice(HOOK_NAME.length);
        }
      }
    }
  }
  return template;
}

// "Ours" by the resolved binary's own basename, not the absolute path it's
// resolved to today -- an install-location change (a different platform
// package version, a different global npm prefix) would otherwise leave a
// previously-written entry unrecognized as ours, appending a second,
// duplicate hook group instead of replacing the first.
function isOurHookCommand(command) {
  if (typeof command !== "string") return false;
  const binToken = command.split(" ", 1)[0];
  return path.basename(binToken) === HOOK_NAME;
}

// Merges a rendered hooks.json-shaped template into an existing hooks.json
// (Codex) or into settings.json's own `hooks` key (Claude Code) -- same
// merge either way: drop only the groups a previous run of this script
// itself wrote (every hook in the group is one of ours, per
// `isOurHookCommand`), append the freshly rendered ones, leave anything else
// untouched. Re-running this is therefore idempotent instead of
// accumulating duplicate entries.
function mergeHooksInto(existingHooks, rendered) {
  const hooks = existingHooks || {};
  for (const [event, groups] of Object.entries(rendered.hooks)) {
    const kept = (hooks[event] || []).filter((group) => !group.hooks.every((h) => isOurHookCommand(h.command)));
    hooks[event] = [...kept, ...groups];
  }
  return hooks;
}

// ---------------------------------------------------------------------------
// Claude Code
// ---------------------------------------------------------------------------

// Claude Code needs no separate skill/command discovery-path research the
// way Codex/OpenCode did -- confirmed live against this machine's own real
// install: `~/.claude/skills/{name}/SKILL.md` and `~/.claude/commands/
// {name}.md` are both read with no plugin involved (a probe skill dropped
// directly into the global skills dir showed up in a fresh `claude -p`
// session's own skill listing). `~/.claude/settings.json`'s own `hooks`/`env`
// keys are the same mechanism the retired setup.sh (pre-plugin Synapse)
// already used, and the same one NanoNets/Graft uses for its own Claude Code
// integration -- this harness is not doing anything Claude Code doesn't
// already support natively.
function configureClaude() {
  const hookBin = resolveHookBin();

  const skillsDest = path.join(os.homedir(), ".claude", "skills");
  const skillNames = copySkills(skillsDest);
  pruneStale(skillsDest, skillNames);
  const commandsDest = path.join(os.homedir(), ".claude", "commands");
  const commandNames = copyCommands(commandsDest);
  pruneStale(commandsDest, commandNames);
  console.log(`installed ${skillNames.length} skills, ${commandNames.length} commands to ~/.claude`);

  const settingsPath = path.join(os.homedir(), ".claude", "settings.json");
  let settings = {};
  if (fs.existsSync(settingsPath)) {
    try {
      settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
    } catch (err) {
      fail(`${settingsPath} has invalid JSON (${err.message}) -- fix or back it up manually before re-running`);
    }
  }

  const rendered = renderHooksTemplate(path.join(PKG_ROOT, "harness", "claude", "hooks.json"), hookBin);
  settings.hooks = mergeHooksInto(settings.hooks, rendered);

  // The npm-install counterpart to $CLAUDE_PLUGIN_ROOT -- conf.zig's own
  // resolveConfPath and session_start.zig's synapse-claude.md/Index.md.template
  // lookups both check this env var now that there's no plugin marketplace
  // to set CLAUDE_PLUGIN_ROOT for them. Points at PKG_ROOT, the same
  // relative shape CLAUDE_PLUGIN_ROOT used to point at plugins/synapse/ --
  // synapse-claude.md, Index.md.template, and every *.conf.template sit
  // directly under it.
  settings.env = settings.env || {};
  settings.env.SYNAPSE_CONTENT_ROOT = PKG_ROOT;

  backupIfExists(settingsPath);
  fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
  console.log(`configured ${settingsPath}`);
  console.log("");
  console.log("No manual steps -- restart Claude Code so the new hooks/settings take effect");
  console.log("for the running session.");
}

// ---------------------------------------------------------------------------
// Codex
// ---------------------------------------------------------------------------

function configureCodex() {
  const hookBin = resolveHookBin();

  const rendered = renderHooksTemplate(path.join(PKG_ROOT, "harness", "codex", "hooks.json"), hookBin);
  const hooksPath = path.join(os.homedir(), ".codex", "hooks.json");
  let existing = { hooks: {} };
  if (fs.existsSync(hooksPath)) {
    try {
      existing = JSON.parse(fs.readFileSync(hooksPath, "utf8"));
    } catch (err) {
      fail(`${hooksPath} has invalid JSON (${err.message}) -- fix or back it up manually before re-running`);
    }
  }
  existing.hooks = mergeHooksInto(existing.hooks, rendered);
  fs.mkdirSync(path.dirname(hooksPath), { recursive: true });
  backupIfExists(hooksPath);
  fs.writeFileSync(hooksPath, JSON.stringify(existing, null, 2) + "\n");
  console.log(`configured ${hooksPath}`);

  const skillsDestRoot = path.join(os.homedir(), ".codex", "skills");
  const sharedNames = copySkills(skillsDestRoot);
  const codexSkillsSrc = path.join(PKG_ROOT, "harness", "codex", "skills");
  const codexNames = fs
    .readdirSync(codexSkillsSrc, { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .map((e) => e.name);
  fs.mkdirSync(skillsDestRoot, { recursive: true });
  for (const name of codexNames) {
    fs.cpSync(path.join(codexSkillsSrc, name), path.join(skillsDestRoot, name), { recursive: true, force: true });
  }
  pruneStale(skillsDestRoot, [...sharedNames, ...codexNames]);
  console.log(`installed ${sharedNames.length + codexNames.length} skills to ${skillsDestRoot}`);

  console.log("");
  console.log("No manual steps -- the next real `codex` session will prompt to trust the");
  console.log("hooks this just wrote, approve it interactively.");
}

// ---------------------------------------------------------------------------
// OpenCode
// ---------------------------------------------------------------------------

function configureOpencode() {
  const hookBin = resolveHookBin();

  const pluginSrc = path.join(PKG_ROOT, "harness", "opencode", "plugin", "synapse.js");
  const pluginDestDir = path.join(os.homedir(), ".config", "opencode", "plugin");
  const pluginDest = path.join(pluginDestDir, "synapse.js");
  fs.mkdirSync(pluginDestDir, { recursive: true });
  // synapse.js as shipped is a template -- it has no way to compute its own
  // binary's install path at import time (no CLAUDE_PLUGIN_ROOT-equivalent
  // for OpenCode plugins), so this bakes the real resolved path in as a
  // literal, the same absolute path resolveHookBin() already gave the
  // Claude/Codex hooks.json rendering above.
  const pluginSource = fs.readFileSync(pluginSrc, "utf8").replace('"__SYNAPSE_HOOK_BIN__"', JSON.stringify(hookBin));
  fs.writeFileSync(pluginDest, pluginSource);
  console.log(`installed ${pluginDest}`);

  const skillsDest = path.join(os.homedir(), ".config", "opencode", "skill");
  const skillNames = copySkills(skillsDest);
  pruneStale(skillsDest, skillNames);
  const commandsDest = path.join(os.homedir(), ".config", "opencode", "command");
  const commandNames = copyCommands(commandsDest);
  pruneStale(commandsDest, commandNames);
  console.log(`installed ${skillNames.length} skills, ${commandNames.length} commands to ~/.config/opencode`);

  console.log("");
  console.log("No manual steps -- the plugin resolves its synapse-hook binary from the shared");
  console.log(`install location (${hookBin}) automatically.`);
}

function fail(message) {
  console.error(`synapse-setup: ${message}`);
  process.exit(1);
}

main().catch((err) => {
  console.error(`synapse-setup: ${err.message || err}`);
  process.exitCode = 1;
});
