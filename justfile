# Task runner for this repo. The recipes mirror .github/workflows/tests.yml
# deliberately: "green locally" and "green in CI" cannot mean different things.
# If you change the gate, change it in both places.
#
#   just              list the recipes
#   just build        the three programs, into bin/
#   just test         the AUnit suite
#   just acceptance   the subprocess suite and text checks, against the built programs
#   just check        the full gate -- before PUSHING, not before every commit
#   just fix          regenerate whatever `check` verifies
#
# WHAT TO RUN WHEN:
#
#   changed Ada code            just build && just test
#   changed a proved unit       just prove
#   changed a command's output  just acceptance
#   changed docs/ or README     nothing -- prose has no test to fail
#   changed packages/**/*.md    just acceptance -- a "shipped instruction names
#                               a real command" check covers them
#   about to push               just check
#
# Needs Alire (`alr`) on PATH; it fetches GNAT, gprbuild, AUnit and GNATprove
# itself on first use. `just --list` shows the comment line immediately above
# a recipe.

# Every build passes `-m` to gprbuild, which then recompiles a unit only when
# its source checksum changed and not when its timestamp did. A fresh checkout
# gives every file a new timestamp, so without it a cached `obj/` would be
# recompiled whole.

set shell := ["bash", "-uc"]

_default:
    @just --list --unsorted


ucd_version := "18.0.0"

# Download the pinned Unicode Character Database files the tables generator and the conformance tests read.
ucd:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p ucd
    for f in UnicodeData.txt CompositionExclusions.txt CaseFolding.txt NormalizationTest.txt; do
        [ -s "ucd/$f" ] || curl -fsSL -o "ucd/$f" \
            "https://www.unicode.org/Public/{{ ucd_version }}/ucd/$f"
    done
    echo "ucd {{ ucd_version }} ok"

# Regenerate the Unicode tables from the downloaded UCD files.
gen-unicode: ucd
    cd tools && alr -n build --validation -- -m && alr -n run --skip-build --args="../ucd ../src/core/text {{ ucd_version }}"

# Fail if the committed Unicode tables differ from what the generator produces.
gen-check: ucd
    mkdir -p ucd/check
    cd tools && alr -n build --validation && alr -n run --skip-build --args="../ucd ../ucd/check {{ ucd_version }}"
    cmp src/core/text/synapse-core-unicode_tables.ads ucd/check/synapse-core-unicode_tables.ads
    cmp src/core/text/synapse-core-unicode_tables.adb ucd/check/synapse-core-unicode_tables.adb

tree_sitter_commit := "42f33fe2f8ddef5617a8536723c5d2b8a19a615e"

# Refresh the vendored libtree-sitter runtime from the pinned upstream commit.
vendor-tree-sitter:
    #!/usr/bin/env bash
    set -euo pipefail
    dest="vendor/tree-sitter"
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    curl -fsSL -o "$work/ts.tar.gz" \
        "https://github.com/tree-sitter/tree-sitter/archive/{{ tree_sitter_commit }}.tar.gz"
    tar -xzf "$work/ts.tar.gz" -C "$work"
    src="$work/tree-sitter-{{ tree_sitter_commit }}"
    rm -rf "$dest/lib"
    mkdir -p "$dest/lib"
    cp -R "$src/lib/src" "$src/lib/include" "$dest/lib/"
    cp "$src/LICENSE" "$dest/LICENSE"
    printf '%s\n' "{{ tree_sitter_commit }}" > "$dest/VERSION"
    echo "tree-sitter {{ tree_sitter_commit }} vendored"

json_suite_commit := "1ef36fa01286573e846ac449e8683f8833c5b26a"

# Download the pinned JSONTestSuite parsing cases the JSON tests read.
json-suite:
    #!/usr/bin/env bash
    set -euo pipefail
    dest="testdata/json"
    if [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then echo "json suite ok"; exit 0; fi
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    curl -fsSL -o "$work/suite.tar.gz" \
        "https://github.com/nst/JSONTestSuite/archive/{{ json_suite_commit }}.tar.gz"
    tar -xzf "$work/suite.tar.gz" -C "$work"
    mkdir -p "$dest"
    cp "$work/JSONTestSuite-{{ json_suite_commit }}/test_parsing/"* "$dest/"
    echo "json suite {{ json_suite_commit }} ok"

# Build the programs with the validation profile (contracts checked at runtime) into bin/.
build:
    alr -n build --validation -- -m

# The AUnit suite; exits non-zero on any failed test.
test: ucd json-suite
    cd tests/unit && alr -n exec -- gprbuild -q -p -P fixtures/fixtures.gpr && alr -n build --validation && alr -n run --skip-build

# Build the release binaries.
release:
    alr -n build --release -- -m

# Package the release binaries as npm packages, install them into a scratch prefix and check the installed program end to end.
package: release
    ci/package.sh

# Prove the SPARK units with GNATprove; exits non-zero on any unproved check.
prove:
    cd tests/unit && alr -n exec -- gnatprove -P synapse_proof.gpr --level=2 --report=all --checks-as-errors=on

# The acceptance suite: runs the built programs against scratch repositories and checks the shipped text.
acceptance: build
    cd tests/acceptance && alr -n build --validation -- -m
    ./tests/acceptance/bin/synapse_acceptance

# Build the Linux release binaries in a container against a glibc 2.28 sysroot.
linux-release:
    ci/linux-release.sh

# Parse-check every shipped script without executing it.
syntax:
    #!/usr/bin/env bash
    set -euo pipefail
    n=0
    # claude/bin and claude/lib/synapse are gone -- the tooling is one
    # binary. Every shipped hook/setup script is .cjs now (packages/synapse/),
    # not .sh -- nothing left for this recipe to parse-check there, but
    # plugins/*/hooks/*.sh stays in the glob list rather than being deleted:
    # the `[ -f ]` guard below makes an empty match harmless, and the moment
    # a `.sh` script reappears in any plugin's hooks dir, this starts
    # checking it again automatically.
    # docs/*/*.sh reaches synapse's own generators (docs/synapse/); docs/*.sh
    # still needed for generate-site.sh, which stays at the top level.
    for f in ci/*.sh docs/*.sh docs/*/*.sh plugins/*/hooks/*.sh; do
        [ -f "$f" ] || continue
        bash -n "$f"
        n=$((n + 1))
    done
    echo "syntax ok: $n scripts"

# Verify the generated cli.md and rendered diagrams match their sources.
docs-check:
    ./docs/synapse/generate-cli-reference.sh --check
    ./docs/synapse/generate-diagrams.sh --check

# Verify the npm package actually includes every shipped schema document.
npm-check:
    #!/usr/bin/env bash
    set -euo pipefail
    out="$(npm pack --dry-run --json ./packages/synapse)"
    for f in schema/vault-note/v1.yaml schema/vault-design-note/v1.yaml schema/vault-task-note/v1.yaml; do
        grep -qF "$f" <<< "$out" || { echo "npm package is missing $f" >&2; exit 1; }
    done
    echo "npm-check ok"

# Show what changed against the pushed branch.
diff:
    @git --no-pager diff --stat @{u}.. 2>/dev/null || git --no-pager diff --stat

# Regenerate all generated artefacts; diagrams need mermaid-cli and its Chromium.
fix:
    ./docs/synapse/generate-cli-reference.sh
    ./docs/synapse/generate-diagrams.sh

# The full gate -- run before pushing (see WHAT TO RUN WHEN at the top).
check: build test prove gen-check acceptance syntax docs-check npm-check
    @echo "all green"
