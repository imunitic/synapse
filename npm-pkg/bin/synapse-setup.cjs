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
const { execFileSync } = require("child_process");
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
  if (harness === "claude") return configureClaude();
  if (harness === "codex") return configureCodex();
  if (harness === "opencode") return configureOpencode();
}

// ---------------------------------------------------------------------------
// Shared: vault/Obsidian plugin data, skill/command copies, JSON merge helpers
// ---------------------------------------------------------------------------

function readObsidianPluginData() {
  const { resolveVaultDir } = require("../lib/obsidian-mcp-refresh.cjs");
  const vault = resolveVaultDir();
  if (!vault || !fs.existsSync(vault)) {
    fail("no OBSIDIAN_VAULT_DIR resolvable (see synapse.conf) -- can't configure the obsidian MCP connection");
  }
  const pluginDataPath = path.join(vault, ".obsidian", "plugins", "obsidian-local-rest-api", "data.json");
  if (!fs.existsSync(pluginDataPath)) {
    fail(`${pluginDataPath} not found -- install/enable the Local REST API plugin in Obsidian first`);
  }
  const data = JSON.parse(fs.readFileSync(pluginDataPath, "utf8"));
  if (!data.apiKey) fail(`${pluginDataPath} has no apiKey`);
  return data;
}

// Copies every shared SKILL.md into `destRoot/{name}/SKILL.md`, verbatim
// unless `transform` is given. Each skill gets its own uniquely-named
// subdirectory, so overwriting ours on every run never touches anything a
// harness's own skill discovery also finds there under a different name.
function copySkills(destRoot, transform) {
  const src = path.join(PKG_ROOT, "skills");
  const names = fs
    .readdirSync(src, { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .map((e) => e.name);
  fs.mkdirSync(destRoot, { recursive: true });
  for (const name of names) {
    const destDir = path.join(destRoot, name);
    fs.mkdirSync(destDir, { recursive: true });
    writeMaybeTransformed(path.join(src, name, "SKILL.md"), path.join(destDir, "SKILL.md"), transform);
  }
  return names.length;
}

function copyCommands(destRoot, transform) {
  const src = path.join(PKG_ROOT, "commands");
  const names = fs.readdirSync(src).filter((f) => f.endsWith(".md"));
  fs.mkdirSync(destRoot, { recursive: true });
  for (const name of names) {
    writeMaybeTransformed(path.join(src, name), path.join(destRoot, name), transform);
  }
  return names.length;
}

function writeMaybeTransformed(srcPath, destPath, transform) {
  const text = fs.readFileSync(srcPath, "utf8");
  fs.writeFileSync(destPath, transform ? transform(text) : text);
}

// `\w+` catches a real tool name (mcp__obsidian__vault_read); `\*` catches
// prose referring to the whole family (mcp__obsidian__*).
function opencodeToolNameTransform(text) {
  return text.replace(/mcp__obsidian__(\w+|\*)/g, "obsidian_$1");
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

// Merges a rendered hooks.json-shaped template into an existing hooks.json
// (Codex) or into settings.json's own `hooks` key (Claude Code) -- same
// merge either way: drop only the groups a previous run of this script
// itself wrote (every hook in the group calling the resolved hookBin path),
// append the freshly rendered ones, leave anything else untouched. Re-running
// this is therefore idempotent instead of accumulating duplicate entries.
function mergeHooksInto(existingHooks, rendered, hookBin) {
  const hooks = existingHooks || {};
  for (const [event, groups] of Object.entries(rendered.hooks)) {
    const kept = (hooks[event] || []).filter(
      (group) => !group.hooks.every((h) => typeof h.command === "string" && h.command.startsWith(hookBin))
    );
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
// session's own skill listing). Commands need no transform either: they were
// authored for Claude Code in the first place, so the copy is the identity
// function. `~/.claude/settings.json`'s own `hooks`/`env` keys are the same
// mechanism the retired setup.sh (pre-plugin Synapse) already used, and the
// same one NanoNets/Graft uses for its own Claude Code integration -- this
// harness is not doing anything Claude Code doesn't already support natively.
function configureClaude() {
  const hookBin = resolveHookBin();

  const skillCount = copySkills(path.join(os.homedir(), ".claude", "skills"));
  const commandCount = copyCommands(path.join(os.homedir(), ".claude", "commands"));
  console.log(`installed ${skillCount} skills, ${commandCount} commands to ~/.claude`);

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
  settings.hooks = mergeHooksInto(settings.hooks, rendered, hookBin);

  // Keeps the obsidian MCP registration current automatically, every
  // session -- the same job plugins/synapse/hooks/obsidian-mcp-refresh.cjs
  // did as a plugin-era SessionStart hook. Merged the same way as the
  // templated hooks above (dedup key = the exact resolved command), just
  // not sourced from harness/claude/hooks.json since its path needs no
  // per-platform hookBin substitution -- it's always PKG_ROOT-relative.
  const refreshCmd = `node ${path.join(PKG_ROOT, "lib", "obsidian-mcp-refresh.cjs")}`;
  const refreshHooks = { hooks: { SessionStart: [{ hooks: [{ type: "command", command: refreshCmd }] }] } };
  settings.hooks = mergeHooksInto(settings.hooks, refreshHooks, refreshCmd);

  const pluginData = readObsidianPluginData();
  if (!pluginData.crypto || typeof pluginData.crypto.cert !== "string") {
    fail("Local REST API's data.json has no crypto.cert -- can't set up the HTTPS trust Claude Code needs");
  }
  const certPath = path.join(os.homedir(), ".claude", "obsidian-local-rest-api-ca.pem");
  fs.mkdirSync(path.dirname(certPath), { recursive: true });
  fs.writeFileSync(certPath, pluginData.crypto.cert);
  settings.env = settings.env || {};
  settings.env.NODE_EXTRA_CA_CERTS = certPath;

  // The npm-install counterpart to $CLAUDE_PLUGIN_ROOT -- conf.zig's own
  // resolveConfPath and session_start.zig's synapse-claude.md/Index.md.template
  // lookups both check this env var now that there's no plugin marketplace
  // to set CLAUDE_PLUGIN_ROOT for them. Points at PKG_ROOT, the same
  // relative shape CLAUDE_PLUGIN_ROOT used to point at plugins/synapse/ --
  // synapse-claude.md, Index.md.template, and every *.conf.template sit
  // directly under it.
  settings.env.SYNAPSE_CONTENT_ROOT = PKG_ROOT;

  backupIfExists(settingsPath);
  fs.writeFileSync(settingsPath, JSON.stringify(settings, null, 2) + "\n");
  console.log(`configured ${settingsPath}`);
  console.log(`wrote ${certPath}`);

  // Claude Code already has a working HTTPS cert-trust story (unlike
  // Codex/OpenCode), so this registers against the real endpoint directly --
  // no plain-HTTP fallback needed here. Registering means removing first --
  // `claude mcp add` will not overwrite an existing name.
  try {
    execFileSync("claude", ["mcp", "remove", "obsidian", "-s", "user"], { stdio: "ignore" });
  } catch {
    // Fine if it wasn't registered yet.
  }
  execFileSync(
    "claude",
    [
      "mcp",
      "add",
      "--transport",
      "http",
      "obsidian",
      `https://127.0.0.1:${pluginData.port}/mcp/`,
      "--header",
      `Authorization: Bearer ${pluginData.apiKey}`,
      "-s",
      "user",
    ],
    { stdio: "ignore" }
  );
  console.log("registered the obsidian MCP server");
  console.log("");
  console.log("No manual steps -- restart Claude Code so the new hooks/settings/MCP");
  console.log("registration take effect for the running session.");
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
  existing.hooks = mergeHooksInto(existing.hooks, rendered, hookBin);
  fs.mkdirSync(path.dirname(hooksPath), { recursive: true });
  backupIfExists(hooksPath);
  fs.writeFileSync(hooksPath, JSON.stringify(existing, null, 2) + "\n");
  console.log(`configured ${hooksPath}`);

  const skillsDestRoot = path.join(os.homedir(), ".codex", "skills");
  const sharedCount = copySkills(skillsDestRoot);
  const codexSkillsSrc = path.join(PKG_ROOT, "harness", "codex", "skills");
  const codexNames = fs
    .readdirSync(codexSkillsSrc, { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .map((e) => e.name);
  fs.mkdirSync(skillsDestRoot, { recursive: true });
  for (const name of codexNames) {
    fs.cpSync(path.join(codexSkillsSrc, name), path.join(skillsDestRoot, name), { recursive: true, force: true });
  }
  console.log(`installed ${sharedCount + codexNames.length} skills to ${skillsDestRoot}`);

  const pluginData = readObsidianPluginData();
  if (!pluginData.enableInsecureServer || !pluginData.insecurePort) {
    fail(
      "Local REST API's plain-HTTP server is off -- Codex can't trust its self-signed HTTPS cert " +
        "(no per-server cert field in config.toml). Enable it: Obsidian Settings -> " +
        "Local REST API -> Enable HTTP server, then re-run this command."
    );
  }
  const tokenEnvVar = "SYNAPSE_OBSIDIAN_API_KEY";
  mergeCodexConfigToml(path.join(os.homedir(), ".codex", "config.toml"), pluginData.insecurePort, tokenEnvVar);
  console.log(`configured ${path.join(os.homedir(), ".codex", "config.toml")}`);

  console.log("");
  console.log("One manual step -- Codex reads the vault API key from an env var by name,");
  console.log("not from config.toml. Add this to your shell profile, then restart your terminal:");
  console.log("");
  console.log(`  export ${tokenEnvVar}="${pluginData.apiKey}"`);
  console.log("");
  console.log("The next real `codex` session will prompt to trust the hooks this just wrote --");
  console.log("approve it interactively.");
}

const CODEX_TOML_BEGIN = "# >>> synapse: obsidian MCP (managed by synapse-setup configure codex) >>>";
const CODEX_TOML_END = "# <<< synapse <<<";

function mergeCodexConfigToml(configTomlPath, insecurePort, tokenEnvVar) {
  const block = [
    CODEX_TOML_BEGIN,
    "[mcp_servers.obsidian]",
    `url = "http://127.0.0.1:${insecurePort}/mcp/"`,
    `bearer_token_env_var = "${tokenEnvVar}"`,
    CODEX_TOML_END,
  ].join("\n");

  let text = "";
  if (fs.existsSync(configTomlPath)) text = fs.readFileSync(configTomlPath, "utf8");
  const beginIdx = text.indexOf(CODEX_TOML_BEGIN);
  const endIdx = text.indexOf(CODEX_TOML_END);
  let next;
  if (beginIdx !== -1 && endIdx !== -1 && endIdx > beginIdx) {
    next = text.slice(0, beginIdx) + block + text.slice(endIdx + CODEX_TOML_END.length);
  } else {
    const sep = text.length === 0 || text.endsWith("\n\n") ? "" : text.endsWith("\n") ? "\n" : "\n\n";
    next = text + sep + block + "\n";
  }
  fs.mkdirSync(path.dirname(configTomlPath), { recursive: true });
  backupIfExists(configTomlPath);
  fs.writeFileSync(configTomlPath, next);
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

  const skillCount = copySkills(path.join(os.homedir(), ".config", "opencode", "skill"), opencodeToolNameTransform);
  const commandCount = copyCommands(
    path.join(os.homedir(), ".config", "opencode", "command"),
    opencodeToolNameTransform
  );
  console.log(`installed ${skillCount} skills, ${commandCount} commands to ~/.config/opencode`);

  const pluginData = readObsidianPluginData();
  if (!pluginData.enableInsecureServer || !pluginData.insecurePort) {
    fail(
      "Local REST API's plain-HTTP server is off -- OpenCode's mcp.obsidian schema has no per-server " +
        "cert/TLS field either. Enable it: Obsidian Settings -> Local REST API -> Enable HTTP server, " +
        "then re-run this command."
    );
  }
  const configPath = path.join(os.homedir(), ".config", "opencode", "opencode.jsonc");
  mergeOpencodeMcp(configPath, pluginData.insecurePort, pluginData.apiKey);
  console.log(`configured ${configPath}`);

  console.log("");
  console.log("No manual steps -- the plugin resolves its synapse-hook binary from the shared");
  console.log(`install location (${hookBin}) automatically.`);
}

function mergeOpencodeMcp(configPath, insecurePort, apiKey) {
  let config = {};
  if (fs.existsSync(configPath)) {
    const raw = fs.readFileSync(configPath, "utf8");
    try {
      config = JSON.parse(raw);
    } catch (err) {
      fail(
        `${configPath} isn't plain JSON (${err.message}) -- can't safely merge into a commented .jsonc ` +
          `file without risking losing the comments. Add this entry by hand instead: ` +
          `mcp.obsidian: {"type":"remote","url":"http://127.0.0.1:${insecurePort}/mcp/",` +
          `"headers":{"Authorization":"Bearer <the vault's apiKey>"}}`
      );
    }
  }
  config.mcp = config.mcp || {};
  config.mcp.obsidian = {
    type: "remote",
    url: `http://127.0.0.1:${insecurePort}/mcp/`,
    headers: { Authorization: `Bearer ${apiKey}` },
  };
  fs.mkdirSync(path.dirname(configPath), { recursive: true });
  backupIfExists(configPath);
  fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + "\n");
}

function fail(message) {
  console.error(`synapse-setup: ${message}`);
  process.exit(1);
}

main().catch((err) => {
  console.error(`synapse-setup: ${err.message || err}`);
  process.exitCode = 1;
});
