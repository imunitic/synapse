#!/usr/bin/env node
// The install/configure entry point for every harness Synapse supports (Claude
// Code, Codex CLI, OpenCode).
//
//   synapse-setup configure <harness>
//
// The binaries themselves need no step here: `npm install` already pulled in
// the right @imunitic/synapse-{platform}-{arch} optionalDependency (see
// lib/resolve-binaries.cjs). `configure <harness>` is what needs the person,
// since which harnesses to wire up is a per-machine choice. The work is
// `synapse configure <harness>`; this runs it with this package as the content
// to install.

"use strict";

const { spawnSync } = require("child_process");
const path = require("path");
const { cliPath, platformPackageName } = require("../lib/resolve-binaries.cjs");

const args = process.argv.slice(2);
if (args[0] !== "configure") {
  console.error("usage: synapse-setup configure <harness>");
  console.error("  <harness> is one of: claude, codex, opencode");
  process.exit(2);
}

const bin = cliPath();
if (!bin) {
  console.error(`synapse-setup: ${platformPackageName()} isn't installed for this platform -- try "npm install" again`);
  process.exit(1);
}

const result = spawnSync(bin, args, {
  stdio: "inherit",
  env: { ...process.env, SYNAPSE_CONTENT_ROOT: path.join(__dirname, "..") },
});
process.exit(result.status ?? 1);
