"use strict";

// Runs check-skill-frontmatter.cjs on small SKILL.md files and checks what it
// reports.
//
//   node --test ci/*.test.cjs

const assert = require("node:assert");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { test } = require("node:test");

function check(frontmatter) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "skill-frontmatter-"));
  const file = path.join(dir, "SKILL.md");
  fs.writeFileSync(file, `---\n${frontmatter}\n---\n\nBody\n`);
  try {
    return spawnSync("node", [path.join(__dirname, "check-skill-frontmatter.cjs"), file], {
      encoding: "utf8",
    });
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

test("a name and a description are valid", () => {
  assert.strictEqual(check('name: demo\ndescription: "Does a thing: well."').status, 0);
});

test("an empty quoted description is missing", () => {
  const result = check('name: demo\ndescription: ""');
  assert.strictEqual(result.status, 1);
  assert.match(result.stderr, /has no 'description'/);
});

test("a plain value that ends in a colon is refused", () => {
  const result = check("name: demo\ndescription: Does a thing:");
  assert.strictEqual(result.status, 1);
  assert.match(result.stderr, /final ':'/);
});

test("a plain value that holds a colon and a space is refused", () => {
  const result = check("name: demo\ndescription: Does a thing: well");
  assert.strictEqual(result.status, 1);
});
