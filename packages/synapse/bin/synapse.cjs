#!/usr/bin/env node
// Thin shim so `synapse` resolves on PATH after `npm install -g @imunitic/synapse`
// -- the real binary lives inside the platform-specific optionalDependency
// package (node_modules/@imunitic/synapse-{platform}-{arch}/bin/synapse),
// which npm never symlinks into the global bin dir itself. Same shape as
// esbuild/sharp's own per-binary shims.

"use strict";

const { spawnSync } = require("child_process");
const path = require("path");
const { cliPath, platformPackageName } = require("../lib/resolve-binaries.cjs");

const bin = cliPath();
if (!bin) {
  console.error(`synapse: ${platformPackageName()} isn't installed for this platform`);
  process.exit(1);
}

const env = { ...process.env };
if (!env.SYNAPSE_CONTENT_ROOT) env.SYNAPSE_CONTENT_ROOT = path.join(__dirname, "..");
const result = spawnSync(bin, process.argv.slice(2), { stdio: "inherit", env });
process.exit(result.status ?? 1);
