#!/usr/bin/env node
// Checks that the frontmatter of each SKILL.md named on the command line is
// valid YAML in the one way a skill gets it wrong: a plain value that holds
// `: ` or ` #`, which a strict YAML parser reads as a second mapping key or a
// comment. Such a value has to be written in double quotes. Every skill needs
// a `name` and a non-empty `description`.
//
//   node ci/check-skill-frontmatter.cjs <SKILL.md>...

"use strict";

const fs = require("fs");

function problems(file) {
  const found = [];
  const match = fs.readFileSync(file, "utf8").match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n/);
  if (!match) return ["has no frontmatter"];
  const keys = {};
  for (const line of match[1].split(/\r?\n/)) {
    const pair = line.match(/^([A-Za-z][\w-]*):\s*(.*)$/);
    if (!pair) continue;
    const [, key, value] = pair;
    keys[key] = value;
    if (value === "" || /^[\[{|>&*!%@`']/.test(value)) continue;
    if (value[0] === '"') {
      try {
        JSON.parse(value);
      } catch {
        found.push(`'${key}' is a double-quoted value that is not a valid string`);
      }
    } else if (/: | #/.test(value)) {
      found.push(`'${key}' holds ': ' or ' #' and is not in double quotes`);
    }
  }
  for (const required of ["name", "description"]) {
    if (!keys[required]) found.push(`has no '${required}'`);
  }
  return found;
}

let bad = 0;
for (const file of process.argv.slice(2)) {
  for (const problem of problems(file)) {
    console.error(`${file}: ${problem}`);
    bad++;
  }
}
if (process.argv.length < 3) {
  console.error("usage: check-skill-frontmatter.cjs <SKILL.md>...");
  process.exit(2);
}
process.exit(bad === 0 ? 0 : 1);
