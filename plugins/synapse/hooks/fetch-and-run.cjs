#!/usr/bin/env node
// Every hook in hooks.json routes through this rather than invoking
// synapse-hook directly: the compiled binary isn't shipped inside the plugin
// (which would bloat every install with a platform-specific artifact and
// require rebuilding the marketplace source per push) -- it's downloaded
// once from the `dist` branch's latest committed tarball and cached, same
// idea as SYNAPSE_GRAMMARS_DIR already caching cloned grammars at
// ~/.cache/synapse/grammars.
//
// Node, not a shell script: the only interpreter every hook subprocess is
// guaranteed to have on PATH is the one Claude Code itself ships with.
// `curl`/`sha256sum`/`awk`/`uname` aren't guaranteed the same way, so this
// uses only Node builtins (global fetch, crypto, fs) for everything except
// archive extraction, which shells out to `tar` -- present by default on
// macOS, Linux, and Windows 10 1803+.
//
// Fetched via raw.githubusercontent.com, not a GitHub Release download URL,
// for consistency with synapse-bard's own fetch-and-run.cjs -- that plugin
// needs this specific URL shape to work at all from an Anthropic-hosted
// cloud sandbox (see its own comment), and one fetch mechanism for every
// binary this repo ships, rather than two, is worth keeping even though
// synapse's own local/desktop sessions never hit the constraint that forced
// the change.
//
//   fetch-and-run.cjs <hook-subcommand> [args passed through to synapse-hook]
//
// Never blocks a turn on a network hiccup: any failure here exits 0 with no
// output, same "every missing precondition is silence" contract synapse-hook
// itself already follows.
//
// Nothing here resolves synapse-claude.md or the plugin root at all --
// CLAUDE_PLUGIN_ROOT is a real exported environment variable on the spawned
// process ("regardless of how it was launched", per Claude Code's own hooks
// reference), which the final spawn below inherits automatically.
// synapse-hook reads it directly.
//
// Re-checks for a newer binary once per plugin update, not every session and
// not never (the two extremes the design originally left open): with only a
// fresh-cache check, a machine's cached binary silently never updates again,
// ever, however many releases ship after it. Rather than polling the network
// for a version marker every session, this piggybacks on Claude Code's own
// plugin-update detection: plugin.json's `version` field already changes
// exactly when Claude Code decides the plugin updated, so comparing it
// locally (a file read, not a network call) costs nothing and stays
// correctly in sync with zero polling logic here.

"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const { execFileSync, spawnSync } = require("child_process");

const CACHE_NAME = "synapse";
const CLI_NAME = "synapse";
const HOOK_NAME = "synapse-hook";
const DIST_REPO = "imunitic/synapse";

async function main() {
  const hook = process.argv[2];
  if (!hook) return;
  const passthroughArgs = process.argv.slice(3);

  const cacheDir = path.join(process.env.XDG_CACHE_HOME || path.join(os.homedir(), ".cache"), CACHE_NAME);
  const binDir = path.join(cacheDir, "bin");
  const binPath = path.join(binDir, HOOK_NAME);
  const versionFile = path.join(binDir, ".plugin-version");

  const currentVersion = readCurrentVersion();
  const cachedVersion = readIfExists(versionFile);
  const stale = currentVersion !== "" && currentVersion !== cachedVersion;

  if (!isExecutable(binPath) || stale) {
    await refreshBinary({ binDir, binPath, versionFile, currentVersion });
  }

  if (!isExecutable(binPath)) return;

  const result = spawnSync(binPath, [hook, ...passthroughArgs], { stdio: "inherit" });
  process.exitCode = result.status === null ? 0 : result.status;
}

function readCurrentVersion() {
  const pluginRoot = process.env.CLAUDE_PLUGIN_ROOT;
  if (!pluginRoot) return "";
  try {
    const pluginJson = JSON.parse(
      fs.readFileSync(path.join(pluginRoot, ".claude-plugin", "plugin.json"), "utf8")
    );
    return typeof pluginJson.version === "string" ? pluginJson.version : "";
  } catch {
    return "";
  }
}

function readIfExists(file) {
  try {
    return fs.readFileSync(file, "utf8");
  } catch {
    return "";
  }
}

function isExecutable(file) {
  try {
    fs.accessSync(file, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

// Darwin-arm64 / Linux-x86_64 / Linux-aarch64 -- the only targets
// ci/release-targets.sh publishes today. No default case: an unmatched
// platform (including Windows, which has no published binary yet) leaves
// the cached binary, if any, untouched.
function releaseTarget() {
  const plat = os.platform();
  const arch = os.arch();
  if (plat === "darwin" && arch === "arm64") return "aarch64-macos";
  if (plat === "linux" && arch === "x64") return "x86_64-linux";
  if (plat === "linux" && arch === "arm64") return "aarch64-linux";
  return "";
}

// Best-effort end to end: any failure here (network, checksum mismatch,
// missing `tar`, corrupt archive) leaves whatever was already cached in
// place rather than throwing -- a failed re-fetch of a *newer* version must
// fall through to running the still-perfectly-good binary already cached,
// not abort the hook for this turn.
async function refreshBinary({ binDir, binPath, versionFile, currentVersion }) {
  const target = releaseTarget();
  if (!target) return;

  let tmpDir;
  try {
    fs.mkdirSync(binDir, { recursive: true });
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "synapse-fetch-"));

    const archive = `${CLI_NAME}-${target}.tar.gz`;
    const archivePath = path.join(tmpDir, archive);
    const sumsPath = path.join(tmpDir, "SHA256SUMS");

    const base = `https://raw.githubusercontent.com/${DIST_REPO}/dist`;
    await downloadTo(`${base}/${archive}`, archivePath);
    await downloadTo(`${base}/SHA256SUMS`, sumsPath);

    // The only thing standing between "raw.githubusercontent.com served
    // bytes" and "these are the bytes release.yml actually published" --
    // that domain is plain HTTP-over-TLS to GitHub's CDN, not a signed
    // artifact channel.
    const expected = sha256ForFile(sumsPath, archive);
    const actual = sha256OfFile(archivePath);
    if (!expected || expected !== actual) return;

    execFileSync("tar", ["-xzf", archivePath, "-C", tmpDir], { stdio: "ignore" });

    const extractedHook = path.join(tmpDir, HOOK_NAME);
    if (!isExecutable(extractedHook)) return;

    const extractedCli = path.join(tmpDir, CLI_NAME);
    if (fs.existsSync(extractedCli)) {
      try {
        fs.renameSync(extractedCli, path.join(binDir, CLI_NAME));
      } catch {
        // Best-effort, matching the hook binary's move below being the only
        // one that must succeed for this refresh to count.
      }
    }

    fs.renameSync(extractedHook, binPath);
    if (os.platform() !== "win32") fs.chmodSync(binPath, 0o755);
    if (currentVersion) fs.writeFileSync(versionFile, currentVersion);
  } catch {
    // Silent by design -- see the file header.
  } finally {
    if (tmpDir) {
      try {
        fs.rmSync(tmpDir, { recursive: true, force: true });
      } catch {
        // Nothing to do about a leftover temp dir.
      }
    }
  }
}

// A silently-dropped connection (no RST, no DNS failure) would otherwise
// hang forever -- `fetch` has no default timeout, and the header's "never
// blocks a turn" contract has to hold even when the network fails open
// rather than closed.
const fetch_timeout_ms = 10_000;

async function downloadTo(url, destPath) {
  const res = await fetch(url, { signal: AbortSignal.timeout(fetch_timeout_ms) });
  if (!res.ok) throw new Error(`${res.status} fetching ${url}`);
  fs.writeFileSync(destPath, Buffer.from(await res.arrayBuffer()));
}

function sha256OfFile(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

// SHA256SUMS is `sha256sum` output: one `<hash>  <filename>` pair per line.
function sha256ForFile(sumsPath, filename) {
  const contents = fs.readFileSync(sumsPath, "utf8");
  for (const line of contents.split("\n")) {
    const parts = line.trim().split(/\s+/);
    if (parts.length === 2 && parts[1] === filename) return parts[0];
  }
  return "";
}

main().catch(() => {
  process.exitCode = 0;
});
