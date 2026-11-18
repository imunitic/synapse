"use strict";

// Runs synapse-pipeline-setup.cjs against a stand-in for the platform package's
// binary, and checks what the binary is given: the arguments, and the folder of
// this package's skills as the content to install. What `configure` does with
// them is tested in the Ada suite and by ci/package.sh against the real binary.
//
//   node --test ci/*.test.cjs

const assert = require("node:assert");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");

const PKG = path.join(__dirname, "..", "packages", "synapse-pipeline");
const SETUP = path.join(PKG, "bin", "synapse-pipeline-setup.cjs");

// A platform package, found through NODE_PATH, whose binary prints what it was run with.
function standIn(exitCode) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "pipeline-setup-"));
  const pkg = path.join(root, "node_modules", "@imunitic", `synapse-pipeline-${process.platform}-${process.arch}`);
  fs.mkdirSync(path.join(pkg, "bin"), { recursive: true });
  fs.writeFileSync(path.join(pkg, "package.json"), JSON.stringify({ name: "stand-in", version: "0.0.0" }));
  const bin = path.join(pkg, "bin", "synapse-pipeline");
  fs.writeFileSync(bin, `#!/bin/sh\necho "args: $*"\necho "root: $SYNAPSE_CONTENT_ROOT"\nexit ${exitCode}\n`, { mode: 0o755 });
  return { root, nodePath: path.join(root, "node_modules") };
}

function setup(args, nodePath) {
  return spawnSync("node", [SETUP, ...args], {
    encoding: "utf8",
    env: { ...process.env, NODE_PATH: nodePath, SYNAPSE_CONTENT_ROOT: "/not/this" },
  });
}

test("configure runs the binary with the arguments and this package's folder", { skip: process.platform === "win32" }, () => {
  const { root, nodePath } = standIn(0);
  try {
    const result = setup(["configure", "codex"], nodePath);
    assert.strictEqual(result.status, 0, result.stderr);
    assert.ok(result.stdout.includes("args: configure codex"), result.stdout);
    assert.ok(result.stdout.includes(`root: ${PKG}`), result.stdout);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("the exit code of the binary is the exit code of the setup", { skip: process.platform === "win32" }, () => {
  const { root, nodePath } = standIn(3);
  try {
    assert.strictEqual(setup(["configure", "claude"], nodePath).status, 3);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test("anything but configure is a usage error and runs nothing", () => {
  const result = setup(["install", "claude"], "/nowhere");
  assert.strictEqual(result.status, 2);
  assert.ok(result.stderr.includes("usage: synapse-pipeline-setup configure <harness>"), result.stderr);
});

test("a platform without the binary says so", () => {
  const result = setup(["configure", "claude"], "/nowhere");
  assert.strictEqual(result.status, 1);
  assert.ok(result.stderr.includes("isn't installed for this platform"), result.stderr);
});

test("the package ships its skills for the binary to install", () => {
  assert.ok(fs.existsSync(path.join(PKG, "skills", "synapse-pipeline", "SKILL.md")));
});
