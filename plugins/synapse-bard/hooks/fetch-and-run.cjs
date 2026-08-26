#!/usr/bin/env node
// Every hook in synapse-bard's own hooks.json routes through this rather
// than invoking synapse-bard-hook directly: the compiled binary isn't
// shipped inside the plugin, it's downloaded once from the `dist` branch's
// latest committed tarball and cached -- same idea synapse's own
// hooks/fetch-and-run.cjs uses, forked rather than shared for the same
// reason the skill/command layer was forked: this is audience-independent
// protocol code, but it caches under its own ~/.cache/synapse-bard/bin,
// distinct from synapse's ~/.cache/synapse/bin, so the two plugins never
// fight over one binary slot on a machine that has both installed.
//
// Node, not a shell script: the only interpreter every hook subprocess is
// guaranteed to have on PATH is the one Claude Code itself ships with.
// `curl`/`sha256sum`/`awk`/`uname` aren't guaranteed the same way, so this
// uses only Node builtins (global fetch, crypto, fs) for everything except
// archive extraction, which shells out to `tar` -- present by default on
// macOS, Linux, and Windows 10 1803+.
//
// Fetched via raw.githubusercontent.com, not a GitHub Release download URL:
// `synapse-bard`'s primary audience is an Android-app cloud session, and in
// an Anthropic-hosted cloud sandbox, release-asset downloads route through a
// repo-scoped GitHub proxy that 403s any repo other than the one the session
// is attached to (rarely this one, since synapse-bard's primary audience
// isn't developing this plugin itself), per Claude Code's own
// cloud-environments docs. Raw file content from a public repo routes
// through the general security proxy instead, unscoped, so this URL shape
// actually reaches the session.
//
//   fetch-and-run.cjs <hook-subcommand> [args passed through to synapse-bard-hook]
//
// Never blocks a turn on a network hiccup: any failure here exits 0 with no
// output, same "every missing precondition is silence" contract
// synapse-bard-hook itself already follows.
//
// Same os/arch detection as the coding side's script, not narrowed to her
// own session's architecture: synapse-bard ships the same platform set
// synapse does (x86_64-linux, aarch64-linux, aarch64-macos), so this
// resolves whichever one the machine actually is rather than assuming.
//
// Re-checks for a newer binary once per plugin update, not never -- same
// mechanism as the coding side: plugin.json's `version` field changes
// exactly when Claude Code decides the plugin updated, so comparing it
// locally (a file read, not a network call) costs nothing and stays
// correctly in sync with zero polling logic here.

"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");
const { execFileSync, spawnSync } = require("child_process");

const CACHE_NAME = "synapse-bard";
const CLI_NAME = "synapse-bard";
const HOOK_NAME = "synapse-bard-hook";
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
  // No plugin.json to compare (the marketplace/plugin install path is gone --
  // her .claude/ files are committed directly into the bible repo now, not
  // installed through Claude Code's plugin system), so there's no local
  // signal for "did the binary change" at all. Rather than read that as
  // "never stale" (the empty-string comparison below would otherwise do
  // forever, since nothing ever writes a real version past the first run),
  // treat no signal as always-stale: refetch every SessionStart. `dist`
  // regenerates on every push to main now (bard-dist.yml), so this is the
  // only way a re-fetch ever actually happens.
  const stale = currentVersion === "" || currentVersion !== cachedVersion;

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
    tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "synapse-bard-fetch-"));

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
