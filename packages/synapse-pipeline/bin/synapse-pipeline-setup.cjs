#!/usr/bin/env node
// Installs the synapse-pipeline skills for a harness (Claude Code, Codex CLI,
// OpenCode), so an agent knows how to write and check pipelines.
//
//   synapse-pipeline-setup configure <harness>
//
// The work is `synapse-pipeline configure <harness>`; this runs it with the
// skills of this package as the content to install.

"use strict";

const { spawnSync } = require("child_process");
const path = require("path");
const { binaryPath, platformPackageName } = require("../lib/resolve-binary.cjs");

const args = process.argv.slice(2);
if (args[0] !== "configure") {
  console.error("usage: synapse-pipeline-setup configure <harness>");
  console.error("  <harness> is one of: claude, codex, opencode");
  process.exit(2);
}

const bin = binaryPath();
if (!bin) {
  console.error(`synapse-pipeline-setup: ${platformPackageName()} isn't installed for this platform`);
  process.exit(1);
}

const result = spawnSync(bin, args, {
  stdio: "inherit",
  env: { ...process.env, SYNAPSE_CONTENT_ROOT: path.join(__dirname, "..") },
});
process.exit(result.status ?? 1);
