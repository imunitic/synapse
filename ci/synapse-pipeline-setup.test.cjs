"use strict";

// Runs synapse-pipeline-setup.cjs against a scratch home directory and checks
// what it leaves in the harness's skills directory.
//
//   node --test ci/

const assert = require("node:assert");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");

const SETUP = path.join(__dirname, "..", "packages", "synapse-pipeline", "bin", "synapse-pipeline-setup.cjs");
const PKG_SKILLS = path.join(__dirname, "..", "packages", "synapse-pipeline", "skills");

function configure(home) {
  return spawnSync("node", [SETUP, "configure", "claude"], {
    encoding: "utf8",
    env: { ...process.env, HOME: home },
  });
}

test("a file a newer skill version no longer ships is removed", () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pipeline-setup-"));
  try {
    const name = fs.readdirSync(PKG_SKILLS)[0];
    const skill = path.join(home, ".claude", "skills", name);
    fs.mkdirSync(skill, { recursive: true });
    fs.writeFileSync(path.join(skill, "dropped.md"), "an old file");
    const result = configure(home);
    assert.strictEqual(result.status, 0, result.stderr);
    assert.ok(!fs.existsSync(path.join(skill, "dropped.md")));
    assert.ok(fs.existsSync(path.join(skill, "SKILL.md")));
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
});

test("a folder the package does not ship is left alone", () => {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pipeline-setup-"));
  try {
    const other = path.join(home, ".claude", "skills", "someone-elses");
    fs.mkdirSync(other, { recursive: true });
    fs.writeFileSync(path.join(other, "SKILL.md"), "mine");
    const result = configure(home);
    assert.strictEqual(result.status, 0, result.stderr);
    assert.strictEqual(fs.readFileSync(path.join(other, "SKILL.md"), "utf8"), "mine");
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
});
