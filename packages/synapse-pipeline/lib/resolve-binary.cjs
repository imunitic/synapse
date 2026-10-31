// Locates the compiled synapse-pipeline binary for the current platform --
// shipped as a separate optionalDependency package
// (@imunitic/synapse-pipeline-{platform}-{arch}), not fetched at install time.
// npm's own `os`/`cpu` package.json fields make `npm install` skip every
// platform package but the matching one, and the registry's checksums already
// cover integrity, so this module only ever reads what npm put on disk.

"use strict";

const fs = require("fs");
const path = require("path");

const NAME = "synapse-pipeline";
const EXE = process.platform === "win32" ? ".exe" : "";

// Matches process.platform/process.arch, which is what npm's `os` and `cpu`
// fields select against.
function platformPackageName() {
  return `@imunitic/synapse-pipeline-${process.platform}-${process.arch}`;
}

// Goes through node's own module resolution, so it works whether the platform
// package landed as a normal dependency, a workspace link or a `file:` link.
function binaryPath() {
  try {
    const pkgJson = require.resolve(`${platformPackageName()}/package.json`);
    const file = path.join(path.dirname(pkgJson), "bin", NAME + EXE);
    return fs.existsSync(file) ? file : null;
  } catch {
    return null;
  }
}

module.exports = { platformPackageName, binaryPath, NAME, EXE };
