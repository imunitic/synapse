// Locates the compiled synapse-bard/synapse-bard-hook binaries for the
// current platform -- shipped as a separate optionalDependency package
// (@imunitic/synapse-bard-{platform}-{arch}, mirroring esbuild/@rollup's own
// split), not fetched at install time. npm's own `os`/`cpu` package.json
// fields make `npm install` skip every platform package but the matching
// one, and registry shasum verification already covers integrity, so
// there's no fetch/SHA256SUMS/timeout logic to hand-roll here at all --
// this module only ever reads what npm already put on disk.
//
// A fork of @imunitic/synapse's own lib/resolve-binaries.cjs, not a shared
// dependency -- same reasoning fetch-and-run.cjs's own header already gives
// for forking rather than sharing: the two packages stay independently
// installable, with nothing in either one's node_modules tree pulling in
// the other.

"use strict";

const fs = require("fs");
const path = require("path");

const CLI_NAME = "synapse-bard";
const HOOK_NAME = "synapse-bard-hook";

// Matches process.platform/process.arch directly (not a Zig target triple)
// since that's what npm's own `os`/`cpu` fields select against -- the
// release pipeline maps its Zig target names to this naming once, at
// publish time, not here.
function platformPackageName() {
  return `@imunitic/synapse-bard-${process.platform}-${process.arch}`;
}

// Goes through node's own module resolution -- works whether the platform
// package landed as a normal npm dependency, a workspace symlink, or a
// `file:` link for local testing, rather than assuming a node_modules
// layout this shouldn't hardcode.
function resolveBinDir() {
  try {
    const pkgJsonPath = require.resolve(`${platformPackageName()}/package.json`);
    return path.join(path.dirname(pkgJsonPath), "bin");
  } catch {
    return null;
  }
}

function resolvedPath(name) {
  const binDir = resolveBinDir();
  if (!binDir) return null;
  const file = path.join(binDir, name);
  return fs.existsSync(file) ? file : null;
}

function cliPath() {
  return resolvedPath(CLI_NAME);
}

function hookPath() {
  return resolvedPath(HOOK_NAME);
}

module.exports = { platformPackageName, resolveBinDir, cliPath, hookPath, CLI_NAME, HOOK_NAME };
