#!/usr/bin/env node
// Installs the synapse-pipeline skill for a harness (Claude Code, Codex CLI,
// OpenCode), so an agent knows how to write and check pipelines.
//
//   synapse-pipeline-setup configure <harness>
//
// Each skill in this package's skills/ directory is copied, with everything
// beside its SKILL.md, into the harness's skills directory. A manifest in
// that directory records the names written, so a skill renamed or removed
// here is removed there on the next run; nothing the manifest does not list
// is ever touched.

"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");

const PKG_ROOT = path.join(__dirname, "..");
const MANIFEST = ".synapse-pipeline-managed.json";

const SKILL_DIRS = {
  claude: path.join(os.homedir(), ".claude", "skills"),
  codex: path.join(os.homedir(), ".codex", "skills"),
  opencode: path.join(os.homedir(), ".config", "opencode", "skill"),
};

function installSkills(dest) {
  const src = path.join(PKG_ROOT, "skills");
  const names = fs
    .readdirSync(src, { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .map((e) => e.name);
  fs.mkdirSync(dest, { recursive: true });
  for (const name of names) {
    fs.cpSync(path.join(src, name), path.join(dest, name), { recursive: true, force: true });
  }
  const manifestPath = path.join(dest, MANIFEST);
  let previous = [];
  try {
    previous = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  } catch {
    previous = [];
  }
  for (const name of previous) {
    if (!names.includes(name)) fs.rmSync(path.join(dest, name), { recursive: true, force: true });
  }
  fs.writeFileSync(manifestPath, JSON.stringify(names, null, 2) + "\n");
  return names;
}

function main() {
  const [command, harness] = process.argv.slice(2);
  const known = Object.keys(SKILL_DIRS);
  if (command !== "configure" || !known.includes(harness) || process.argv.length !== 4) {
    console.error("usage: synapse-pipeline-setup configure <harness>");
    console.error(`  <harness> is one of: ${known.join(", ")}`);
    process.exit(2);
  }
  const dest = SKILL_DIRS[harness];
  const names = installSkills(dest);
  console.log(`installed ${names.length} skill${names.length === 1 ? "" : "s"} to ${dest}`);
}

main();
