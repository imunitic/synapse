#!/usr/bin/env node
// SessionStart hook: keeps the `obsidian` MCP server registration current,
// automatically, every session -- the hook-driven replacement for manually
// running setup-obsidian-mcp.sh. Independent of, and never wired through,
// fetch-and-run.cjs/synapse-hook: different domain (wiring up the connection
// to the vault, not Synapse's own code-graph/vault logic), kept separate so
// a bug here can never risk the core Synapse injection into every turn's
// context.
//
// Node, not a shell script: the only interpreter every hook subprocess is
// guaranteed to have on PATH is the one Claude Code itself ships with. `jq`
// and `curl` are gone entirely (native JSON.parse and the built-in `https`
// module replace them); `claude` itself is still an external dependency,
// since MCP registration is its own command, not something this hook can do
// any other way.
//
// Every missing precondition is silence, same convention every other Synapse
// hook already follows -- this never blocks a turn, and produces no stdout
// (a SessionStart hook's stdout becomes injected context; this is a pure
// side-effecting maintenance task, nothing worth telling the model). Genuine
// problems go to stderr only, same as the original script already did.
//
// One real, pre-existing limitation, not new here: MCP servers connect at
// Claude Code startup, before any hook fires, so this can't fix the *current*
// session's connection -- first-time registration or a cert/key rotation
// still needs one restart to take effect.

"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const https = require("https");
const { spawnSync } = require("child_process");

function commandExists(cmd) {
  const res = spawnSync(cmd, ["--version"], { stdio: "ignore" });
  return !(res.error && res.error.code === "ENOENT");
}

// `$VAR`/`${VAR}` expansion looks HOME up through this rather than reading
// `process.env.HOME` directly, so the one thing standing between this
// resolving correctly and not on a platform with no `HOME` env var (Windows)
// is this one substitution -- everything downstream (conf-file tiering,
// `~`/`$HOME` expansion) is otherwise a direct port of core/conf.zig's
// algorithm and stays untouched.
function getVar(name) {
  if (name === "HOME") return os.homedir();
  return process.env[name];
}

// Mirrors core/conf.zig's `get`: one key's raw value from a conf file's
// text, unexpanded. Comments, blank lines, an `export` prefix, and a
// matched-quote or trailing-comment unquote, same as a shell would read it.
// The last assignment wins, same as sourcing would.
function confGet(text, key) {
  let found = null;
  for (let raw of text.split("\n")) {
    let line = raw.trim();
    if (line.length === 0 || line[0] === "#") continue;
    if (line.startsWith("export ")) line = line.slice("export ".length).trimStart();
    if (!line.startsWith(key)) continue;
    const rest = line.slice(key.length);
    if (rest.length === 0 || rest[0] !== "=") continue;
    found = confUnquote(rest.slice(1).trim());
  }
  return found;
}

function confUnquote(raw) {
  if (raw.length >= 2 && (raw[0] === '"' || raw[0] === "'") && raw[raw.length - 1] === raw[0]) {
    return raw.slice(1, -1);
  }
  const m = raw.match(/[#\s]/);
  return m ? raw.slice(0, m.index) : raw;
}

const NAME_RE = /^[A-Za-z_][A-Za-z0-9_]*/;

// Mirrors core/conf.zig's `expand`: a leading `~`, `$VAR` and `${VAR}`
// replaced against `getVar`; everything else (including `${VAR:-default}`,
// `~user`, and a Windows path's backslashes) left exactly as-is.
function confExpand(raw) {
  let out = "";
  let i = 0;
  if (raw.length !== 0 && raw[0] === "~" && (raw.length === 1 || raw[1] === "/")) {
    out += getVar("HOME") || "";
    i = 1;
  }
  while (i < raw.length) {
    if (raw[i] === "\\" && raw[i + 1] === "$") {
      out += "$";
      i += 2;
      continue;
    }
    if (raw[i] !== "$") {
      out += raw[i];
      i += 1;
      continue;
    }
    const after = raw.slice(i + 1);
    if (after[0] === "{") {
      const close = after.indexOf("}");
      if (close === -1) {
        out += raw[i];
        i += 1;
        continue;
      }
      const name = after.slice(1, close);
      if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) {
        out += raw[i];
        i += 1;
        continue;
      }
      out += getVar(name) || "";
      i += 1 + close + 1;
      continue;
    }
    const m = after.match(NAME_RE);
    if (!m) {
      out += raw[i];
      i += 1;
      continue;
    }
    out += getVar(m[0]) || "";
    i += 1 + m[0].length;
  }
  return out;
}

// Mirrors core/conf.zig's `resolveExisting` (tiers 1-2 only -- this hook,
// like the shell script it replaces, never falls back to the plugin's own
// bundled template: that template's SYNAPSE_VAULT_DIR is a placeholder
// path, not a real vault, and silently trying it would be worse than doing
// nothing).
function resolveConfPath(name) {
  const xdg = process.env.XDG_CONFIG_HOME;
  const home = getVar("HOME");
  const candidates = [];
  if (xdg) candidates.push(path.join(xdg, "synapse", name));
  if (home) candidates.push(path.join(home, ".config", "synapse", name));
  if (home) candidates.push(path.join(home, ".claude", name));
  for (const p of candidates) {
    if (fs.existsSync(p)) return p;
  }
  return null;
}

// Mirrors core/conf.zig's `vaultDir`: the env override first, then each
// conf file name in turn (synapse.conf, then the pre-rename second-brain.conf
// as a fallback), each resolved through the same tier order.
function resolveVaultDir() {
  const override = process.env.SYNAPSE_VAULT_DIR;
  if (override) return override;

  for (const name of ["synapse.conf", "second-brain.conf"]) {
    const confPath = resolveConfPath(name);
    if (!confPath) continue;
    let text;
    try {
      text = fs.readFileSync(confPath, "utf8");
    } catch {
      continue;
    }
    const raw = confGet(text, "SYNAPSE_VAULT_DIR");
    if (raw === null) continue;
    const expanded = confExpand(raw);
    if (expanded) return expanded;
  }
  return null;
}

// Same request curl -s --cacert ... --max-time 5 made: any HTTP response
// (whatever the status) counts as reachable, matching curl's own default of
// treating a completed request, not a 2xx, as success. Only a TLS/connection
// failure or the timeout counts as unreachable.
function endpointReachable(port, certPath) {
  return new Promise((resolve) => {
    let ca;
    try {
      ca = fs.readFileSync(certPath);
    } catch {
      resolve(false);
      return;
    }
    const req = https.request(
      { hostname: "127.0.0.1", port, path: "/", method: "GET", ca, timeout: 5000 },
      (res) => {
        res.resume();
        resolve(true);
      }
    );
    req.on("timeout", () => {
      req.destroy();
      resolve(false);
    });
    req.on("error", () => resolve(false));
    req.end();
  });
}

function updateSettingsCaCert(settingsPath, certPath) {
  let settings = {};
  try {
    settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
  } catch {
    // Missing file -> {} (matches the original always seeding one); invalid
    // JSON in an existing file -> also {}, but written to a temp file and
    // swapped in atomically below, same as jq's own "never touch the
    // original until the replacement is known-good" behavior.
  }
  settings.env = settings.env || {};
  settings.env.NODE_EXTRA_CA_CERTS = certPath;

  const tmp = path.join(os.tmpdir(), `obsidian-mcp-refresh.${process.pid}.${Date.now()}`);
  fs.writeFileSync(tmp, JSON.stringify(settings, null, 2) + "\n");
  fs.renameSync(tmp, settingsPath);
}

// Registering means removing first -- `claude mcp add` will not overwrite an
// existing name, and there is no atomic replace.
function isRegistered() {
  const res = spawnSync("claude", ["mcp", "get", "obsidian"], { stdio: "ignore" });
  return !res.error && res.status === 0;
}

function main() {
  if (!commandExists("claude")) return;

  const vault = resolveVaultDir();
  if (!vault || !fs.existsSync(vault)) return;

  const pluginData = path.join(vault, ".obsidian", "plugins", "obsidian-local-rest-api", "data.json");
  if (!fs.existsSync(pluginData)) return;

  const home = os.homedir();
  const certPath = path.join(home, ".claude", "obsidian-local-rest-api-ca.pem");

  let data;
  try {
    data = JSON.parse(fs.readFileSync(pluginData, "utf8"));
  } catch {
    return;
  }

  const apiKey = data.apiKey;
  const port = data.port;
  if (!apiKey || !port) return;
  if (!data.crypto || typeof data.crypto.cert !== "string") return;

  fs.mkdirSync(path.dirname(certPath), { recursive: true });
  fs.writeFileSync(certPath, data.crypto.cert);

  endpointReachable(port, certPath).then((endpointOk) => {
    // Written unconditionally, before the registered/reachable check below --
    // the cert path itself doesn't depend on whether the endpoint answers
    // right now, so a session that never gets past the "leave it alone"
    // branch still ends up with NODE_EXTRA_CA_CERTS pointing at the current
    // cert.
    const settingsPath = path.join(home, ".claude", "settings.json");
    try {
      updateSettingsCaCert(settingsPath, certPath);
    } catch {
      // Best-effort, matching the original: a failed settings.json update
      // does not block anything below.
    }

    const registered = isRegistered();

    // An existing registration that already works is, by definition, one
    // that worked at some point; replacing it with one pointing at a port
    // that does not currently answer trades something working for nothing,
    // so leave it alone in that case rather than risk it.
    if (!endpointOk && registered) {
      process.stderr.write(
        "synapse: obsidian MCP endpoint unreachable, left the existing registration in place\n"
      );
      return;
    }

    spawnSync("claude", ["mcp", "remove", "obsidian", "-s", "user"], { stdio: "ignore" });
    spawnSync(
      "claude",
      [
        "mcp",
        "add",
        "--transport",
        "http",
        "obsidian",
        `https://127.0.0.1:${port}/mcp/`,
        "--header",
        `Authorization: Bearer ${apiKey}`,
        "-s",
        "user",
      ],
      { stdio: "ignore" }
    );
  });
}

if (require.main === module) main();

module.exports = { confGet, confUnquote, confExpand, resolveConfPath, resolveVaultDir };
