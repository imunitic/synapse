#!/bin/bash
# The steps of the Synapse Desktop release that are more than one command, so
# that they can be run and tried on a Mac as they run in CI.
#
#   ci/desktop-release.sh set-version <version>
#       Writes <version> (e.g. 0.18.0, no leading v) as the app's version into
#       synapse_desktop/src-tauri/tauri.conf.json and the [package] of
#       synapse_desktop/src-tauri/Cargo.toml.
#
#   ci/desktop-release.sh check <app> <programs-version> <app-version>
#       Checks a built "Synapse Desktop.app": the bundle's signature verifies,
#       the bundled synapse and synapse-pipeline run and report
#       <programs-version>, and the app's Info.plist says <app-version>. A
#       release passes its tag's version for both; a build of a commit that is
#       not a tag passes 0.0.0-dev and 0.0.0.
set -euo pipefail

cd "$(dirname "$0")/.."

die() {
  echo "desktop-release: $*" >&2
  exit 1
}

set_version() {
  local version="$1"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] ||
    die "'$version' is not a version such as 0.18.0"
  local conf="synapse_desktop/src-tauri/tauri.conf.json"
  local manifest="synapse_desktop/src-tauri/Cargo.toml"
  # Through node, so the rest of each file is left as it is written. In
  # tauri.conf.json the version is the top-level member, indented by two; in
  # Cargo.toml the first `version =` is the one of [package], at the top.
  node -e '
    const fs = require("fs")
    const [version, ...edits] = process.argv.slice(1)
    const patterns = [/^(  "version": )"[^"]*"/m, /^(version = )"[^"]*"/m]
    edits.forEach((file, i) => {
      const text = fs.readFileSync(file, "utf8")
      const next = text.replace(patterns[i], `$1"${version}"`)
      if (!patterns[i].test(text)) throw new Error(`no version in ${file}`)
      fs.writeFileSync(file, next)
    })
  ' "$version" "$conf" "$manifest"
  echo "version $version in $conf and $manifest"
}

# Runs a program and gives its output, or fails when it does not end within
# 20 seconds: a quarantined or unsigned program can wait on a Gatekeeper
# dialog instead of failing.
run_briefly() {
  local out
  out=$(mktemp)
  "$@" >"$out" 2>&1 &
  local pid=$!
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge 20 ]; then
      kill "$pid" 2>/dev/null || true
      rm -f "$out"
      die "$1 did not end within 20 seconds"
    fi
    sleep 1
    waited=$((waited + 1))
  done
  local status=0
  wait "$pid" || status=$?
  cat "$out"
  rm -f "$out"
  return "$status"
}

check() {
  local app="$1" programs_version="$2" app_version="$3"
  [ -d "$app" ] || die "$app is not there"

  codesign --verify --deep --strict "$app" || die "the signature of $app does not verify"
  echo "signature verifies"

  local bin="$app/Contents/Resources/bin"
  local name said
  for name in synapse synapse-pipeline; do
    [ -x "$bin/$name" ] || die "$bin/$name is missing or not executable"
    said=$(run_briefly "$bin/$name" --version) || die "$bin/$name --version failed: $said"
    [ "$said" = "$name $programs_version" ] ||
      die "$name reports '$said', not '$name $programs_version'"
    echo "$said"
  done
  [ -x "$bin/synapse-hook" ] || die "$bin/synapse-hook is missing or not executable"

  local plist="$app/Contents/Info.plist"
  said=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")
  # A macOS bundle version may hold only the numbers of a pre-release such as
  # 0.18.0-rc.1, so 0.18.0 is accepted for it too.
  [ "$said" = "$app_version" ] || [ "$said" = "${app_version%%-*}" ] ||
    die "the app's version is '$said', not '$app_version'"
  echo "app version $said"
}

case "${1:-}" in
  set-version)
    [ $# -eq 2 ] || die "usage: $0 set-version <version>"
    set_version "$2"
    ;;
  check)
    [ $# -eq 4 ] || die "usage: $0 check <app> <programs-version> <app-version>"
    check "$2" "$3" "$4"
    ;;
  *)
    die "usage: $0 set-version <version> | check <app> <programs-version> <app-version>"
    ;;
esac
