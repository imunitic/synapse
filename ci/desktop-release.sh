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
#
#   ci/desktop-release.sh check-tarball <tar.gz> <programs-version> <app-version>
#       Extracts the macOS tarball into a temporary folder and runs `check` on
#       the "Synapse Desktop.app" in it.
#
#   ci/desktop-release.sh stamp-install <version> <base-url> <out>
#       Writes ci/install.sh to <out> with <version> and <base-url> (the folder
#       the release's files download from) filled in.
#
#   ci/desktop-release.sh check-install <tar.gz> <programs-version> <app-version>
#       macOS: installs the tarball with a stamped ci/install.sh into a
#       temporary HOME, from a folder of local files, and runs `check` on the
#       installed app. Also checks that the installed app has no quarantine
#       attribute and that a wrong checksum installs nothing.
#
#   ci/desktop-release.sh check-deb <.deb> <programs-version> <app-version>
#       Linux: unpacks the package with dpkg-deb, runs the bundled programs from
#       the unpacked tree, compares the package's version with <app-version>,
#       then starts the unpacked app under xvfb-run and fails if it ends within
#       15 seconds. Needs dpkg-deb, xvfb-run and the libraries the app links.
#
#   ci/desktop-release.sh check-nsis <setup.exe> <programs-version> <app-version>
#       Windows, from Git Bash (Git for Windows): runs the installer silently
#       into a temporary folder, runs the installed programs, compares the
#       installed app's version with <app-version>, then starts the installed
#       app and fails if it ends within 15 seconds. Git Bash provides the
#       `cygpath` that turns a bash path into the Windows path PowerShell and
#       the installer take.
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

# Runs synapse and synapse-pipeline of a folder of bundled programs and checks
# that they report <programs-version>. <suffix> is ".exe" on Windows.
check_programs() {
  local bin="$1" programs_version="$2" suffix="${3:-}"
  local name said
  for name in synapse synapse-pipeline; do
    [ -x "$bin/$name$suffix" ] || die "$bin/$name$suffix is missing or not executable"
    said=$(run_briefly "$bin/$name$suffix" --version) || die "$bin/$name$suffix --version failed: $said"
    [ "$said" = "$name $programs_version" ] ||
      die "$name reports '$said', not '$name $programs_version'"
    echo "$said"
  done
  [ -x "$bin/synapse-hook$suffix" ] || die "$bin/synapse-hook$suffix is missing or not executable"
}

# Whether an installed app's version <said> is the release's <wanted>. A bundle
# version may hold only the numbers of a pre-release such as 0.18.0-rc.1, and
# Windows writes a fourth number, so 0.18.0 and 0.18.0.0 are accepted for it.
version_matches() {
  local said="$1" wanted="$2"
  [ "$said" = "$wanted" ] || [ "$said" = "${wanted%%-*}" ] || [ "$said" = "${wanted%%-*}.0" ]
}

# Starts a command in the background, lets it run for 15 seconds and fails if
# it has ended by then: a missing library, a glibc mismatch, a wrong bundle
# layout or a crash on start ends the process within seconds. The command is
# ended afterwards.
start_app() {
  "$@" >/dev/null 2>&1 &
  local pid=$!
  local waited=0
  while [ "$waited" -lt 15 ]; do
    sleep 1
    waited=$((waited + 1))
    if ! kill -0 "$pid" 2>/dev/null; then
      local status=0
      wait "$pid" || status=$?
      die "the app ended after $waited seconds with status $status"
    fi
  done
  kill "$pid" 2>/dev/null || true
  # The app can be a child of the command that was started (xvfb-run) or a
  # Windows process that kill does not reach.
  pkill -x synapse-desktop 2>/dev/null || true
  taskkill //F //IM synapse-desktop.exe >/dev/null 2>&1 || true
  echo "the app was still running after 15 seconds"
}

check() {
  local app="$1" programs_version="$2" app_version="$3"
  [ -d "$app" ] || die "$app is not there"

  codesign --verify --deep --strict "$app" || die "the signature of $app does not verify"
  echo "signature verifies"

  check_programs "$app/Contents/Resources/bin" "$programs_version"

  local plist="$app/Contents/Info.plist" said
  said=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist")
  version_matches "$said" "$app_version" ||
    die "the app's version is '$said', not '$app_version'"
  echo "app version $said"
}

check_tarball() {
  local tarball="$1" programs_version="$2" app_version="$3"
  [ -f "$tarball" ] || die "$tarball is not there"
  local dir
  dir=$(mktemp -d)
  tar -xzf "$tarball" -C "$dir"
  check "$dir/Synapse Desktop.app" "$programs_version" "$app_version"
  rm -rf "$dir"
}

stamp_install() {
  local version="$1" base_url="$2" out="$3"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]] ||
    die "'$version' is not a version such as 0.18.0"
  # `|` is the delimiter: a URL has no | in it.
  sed -e "s|@VERSION@|$version|" -e "s|@BASE_URL@|$base_url|" ci/install.sh >"$out"
  grep -q '@VERSION@\|@BASE_URL@' "$out" && die "$out still has a placeholder"
  return 0
}

check_install() {
  local tarball="$1" programs_version="$2" app_version="$3"
  [ -f "$tarball" ] || die "$tarball is not there"
  local dir
  dir=$(mktemp -d)
  mkdir "$dir/release" "$dir/home"

  # The release's files, as the script finds them at its base URL.
  local name="synapse-desktop_${app_version}_macos-arm64.tar.gz"
  cp "$tarball" "$dir/release/$name"
  (cd "$dir/release" && shasum -a 256 "$name" >SHA256SUMS)
  stamp_install "$app_version" "file://$dir/release" "$dir/install.sh"

  HOME="$dir/home" sh "$dir/install.sh"
  local app="$dir/home/Applications/Synapse Desktop.app"
  check "$app" "$programs_version" "$app_version"
  if xattr -p com.apple.quarantine "$app" >/dev/null 2>&1; then
    die "the installed app has a quarantine attribute"
  fi
  echo "no quarantine attribute"

  # A tarball that is not the listed one installs nothing.
  rm -rf "${dir:?}/home"
  mkdir "$dir/home"
  echo "0000000000000000000000000000000000000000000000000000000000000000  $name" >"$dir/release/SHA256SUMS"
  if HOME="$dir/home" sh "$dir/install.sh" >/dev/null 2>&1; then
    die "install.sh installed a tarball whose checksum is not the listed one"
  fi
  [ ! -e "$dir/home/Applications/Synapse Desktop.app" ] ||
    die "install.sh left an app behind after a checksum mismatch"
  echo "a wrong checksum installs nothing"
  rm -rf "$dir"
}

check_deb() {
  local deb="$1" programs_version="$2" app_version="$3"
  [ -f "$deb" ] || die "$deb is not there"
  local dir said
  dir=$(mktemp -d)
  dpkg-deb -x "$deb" "$dir"

  # The programs are the only files called `synapse` in the package; where
  # Tauri puts the resources is not assumed.
  local programs
  programs=$(find "$dir" -type f -name synapse)
  [ "$(echo "$programs" | grep -c .)" -eq 1 ] ||
    die "expected one bundled synapse in $deb, found: ${programs:-none}"
  check_programs "$(dirname "$programs")" "$programs_version"

  said=$(dpkg-deb -f "$deb" Version)
  version_matches "$said" "$app_version" ||
    die "the package's version is '$said', not '$app_version'"
  echo "package version $said"

  local exe="$dir/usr/bin/synapse-desktop"
  [ -x "$exe" ] || die "$exe is missing or not executable"
  start_app xvfb-run -a "$exe"
  rm -rf "$dir"
}

check_nsis() {
  local setup="$1" programs_version="$2" app_version="$3"
  [ -f "$setup" ] || die "$setup is not there"
  local dir
  dir=$(mktemp -d)
  # NSIS takes /D=<folder> last, without quotes, in Windows notation.
  powershell.exe -NoProfile -Command \
    "Start-Process -FilePath '$(cygpath -w "$setup")' -ArgumentList '/S','/D=$(cygpath -w "$dir")' -Wait"

  local programs
  programs=$(find "$dir" -type f -name synapse.exe)
  [ "$(echo "$programs" | grep -c .)" -eq 1 ] ||
    die "expected one bundled synapse.exe after installing $setup, found: ${programs:-none}"
  check_programs "$(dirname "$programs")" "$programs_version" .exe

  local exe="$dir/synapse-desktop.exe" said
  [ -f "$exe" ] || die "$exe is missing"
  said=$(powershell.exe -NoProfile -Command "(Get-Item '$(cygpath -w "$exe")').VersionInfo.ProductVersion" | tr -d '\r')
  version_matches "$said" "$app_version" ||
    die "the app's version is '$said', not '$app_version'"
  echo "app version $said"

  start_app "$exe"
  rm -rf "$dir"
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
  stamp-install)
    [ $# -eq 4 ] || die "usage: $0 stamp-install <version> <base-url> <out>"
    stamp_install "$2" "$3" "$4"
    ;;
  check-tarball | check-install | check-deb | check-nsis)
    [ $# -eq 4 ] || die "usage: $0 $1 <file> <programs-version> <app-version>"
    "${1//-/_}" "$2" "$3" "$4"
    ;;
  *)
    die "usage: $0 set-version <version> | stamp-install <version> <base-url> <out> | check | check-tarball | check-install | check-deb | check-nsis <file> <programs-version> <app-version>"
    ;;
esac
