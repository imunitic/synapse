#!/usr/bin/env node
// Same shim as synapse.cjs, for the hook binary -- see that file's header.
// Not what hooks.json's own entries invoke (those call the resolved
// platform-package path directly, per synapse-setup.cjs's renderHooksTemplate),
// only here so `synapse-hook` also resolves on PATH for manual/debugging use.

"use strict";

const { spawnSync } = require("child_process");
const { hookPath, platformPackageName } = require("../lib/resolve-binaries.cjs");

const bin = hookPath();
if (!bin) {
  console.error(`synapse-hook: ${platformPackageName()} isn't installed for this platform`);
  process.exit(1);
}

const result = spawnSync(bin, process.argv.slice(2), { stdio: "inherit" });
process.exit(result.status ?? 1);
