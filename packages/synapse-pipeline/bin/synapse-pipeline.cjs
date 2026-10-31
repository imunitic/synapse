#!/usr/bin/env node
// Thin shim so `synapse-pipeline` resolves on PATH after
// `npm install -g @imunitic/synapse-pipeline`: the binary itself lives in the
// platform package, which npm never links into the global bin directory.

"use strict";

const { spawnSync } = require("child_process");
const { binaryPath, platformPackageName } = require("../lib/resolve-binary.cjs");

const bin = binaryPath();
if (!bin) {
  console.error(`synapse-pipeline: ${platformPackageName()} isn't installed for this platform`);
  process.exit(1);
}

const result = spawnSync(bin, process.argv.slice(2), { stdio: "inherit" });
process.exit(result.status ?? 1);
