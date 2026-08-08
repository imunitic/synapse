#!/bin/bash
# Enumerates a repo's tracked files, dropping binaries, generated/lockfile
# noise, submodule gitlinks and oversized files. Standalone and vault-free --
# no manifest.tsv, no clustering, nothing beyond git and the repo itself.
#
# Usage: synapse-enumerate.sh [--reenumerate]
#   Work dir: $SYNAPSE_WORK_DIR, default ~/.claude/synapse-work/{repo}@{branch}/.
#   Never the script's own location, and never the repo -- see below.
#
# Writes  $SYNAPSE_WORK_DIR/all.txt        enumerated tracked files (kept if present)
#         $SYNAPSE_WORK_DIR/oversize.txt   size<TAB>path for files over the cap
#
# An existing all.txt is reused as-is unless --reenumerate forces a rebuild --
# a caller that only needs the file list, not a fresh one, pays nothing extra.
#
# Two ways to drop more than the built-in exclusions, both OR'd together:
#   ~/.claude/synapse-ignore-files.conf   one ERE per line, comments allowed
#   $SYNAPSE_EXTRA_EXCLUDE_RE             a single ERE, for one-off invocations
# Excluding a path removes it from the graph entirely -- no owning node, no
# vault search hit, no staleness flag when it changes. Right for build output
# and vendored code; wrong for anything whose edits still matter.
#
# Files over $SYNAPSE_MAX_FILE_BYTES (default 1048576, 1 MB) are skipped and
# reported, not dropped silently: no extension or name rule anticipates a
# generated monster, and a silent skip makes `enumerated` disagree with the repo.
#
# Exit codes: 0 ok, 1 could not run, 2 usage error
set -euo pipefail

# Extracted from the header block, so help and docs/scripts.md cannot disagree.
usage() { # usage [exit-code]
    awk '/^# Usage:/ { p = 1 } p && !/^#/ { exit } p { sub(/^# ?/, ""); print }' "$0" >&2
    exit "${1:-2}"
}

reenumerate=false
case "${1:-}" in
    "") ;;
    --reenumerate) reenumerate=true ;;
    -h|--help) usage 0 ;;
    *) usage ;;
esac

command -v git >/dev/null || { echo "synapse-enumerate: git required" >&2; exit 1; }
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$REPO_ROOT" ]] || { echo "synapse-enumerate: not inside a git repo" >&2; exit 1; }

# "{repo}@{branch}", not a bare repo name -- see synapse-identity.sh.
# shellcheck source=/dev/null
. "${SYNAPSE_LIB_DIR:-$HOME/.claude/lib/synapse}/synapse-identity.sh" 2>/dev/null || {
    echo "synapse-enumerate: synapse-identity.sh not installed (run setup.sh)" >&2; exit 1; }
REPO_NAME="$(synapse_namespace "$REPO_ROOT")" || exit 1

# Not $PWD: the repo is resolved from $PWD, so a $PWD default would write the
# enumeration into the user's checkout. Per repo, so a re-run finds the
# previous enumeration.
readonly WORK_DIR="${SYNAPSE_WORK_DIR:-$HOME/.claude/synapse-work/$REPO_NAME}"
mkdir -p "$WORK_DIR"
readonly ALL="$WORK_DIR/all.txt"

# Dropped at enumeration, so _unassigned means "text I could not place". Grouped
# by what a file is rather than by ecosystem, so adding a language is a one-line
# change. Source formats never belong here.
readonly BINARY_RE='\.('\
'png|gif|jpg|jpeg|bmp|tif|tiff|webp|avif|ico|svgz|psd|ai|sketch|fig|'\
'mp3|m4a|wav|flac|ogg|mp4|m4v|mov|avi|mkv|webm|'\
'zip|gz|tgz|tar|bz2|xz|zst|7z|rar|'\
'jar|war|ear|class|aar|apk|whl|egg|gem|nupkg|deb|rpm|dmg|pkg|msi|'\
'o|a|obj|lib|pdb|so|dylib|dll|exe|rlib|wasm|node|pyc|pyo|pyd|beam|'\
'parquet|avro|orc|db|sqlite|sqlite3|mdb|'\
'pkl|pickle|npy|npz|h5|hdf5|onnx|pt|pth|ckpt|safetensors|gguf|bin|'\
'pdf|xls|xlsx|doc|docx|ppt|pptx|odt|ods|odp|'\
'ttf|otf|woff|woff2|eot|'\
'keystore|jks|p12|pem|crt|cer|der'\
')$'

# Generated files whose names, not extensions, identify them. A lockfile is
# thousands of lines of resolved versions with nothing to summarise, and a
# minified bundle or source map is machine output that happens to end in .js.
readonly NOISE_RE='(^|/)('\
'package-lock\.json|npm-shrinkwrap\.json|yarn\.lock|pnpm-lock\.yaml|'\
'Cargo\.lock|poetry\.lock|Pipfile\.lock|uv\.lock|Gemfile\.lock|composer\.lock|'\
'go\.sum|mix\.lock|pubspec\.lock|packages\.lock\.json|flake\.lock'\
')$|\.min\.(js|css)$|\.(js|css|ts)\.map$'

# Repo-specific exclusions from a conf file, OR'd with the pre-existing env var
# so an invocation that set it keeps behaving identically. One ERE per line;
# comments and blanks dropped. `^$` when there is nothing, which never matches a
# path -- an empty pattern would match everything and silently enumerate zero
# files.
IGNORE_CONF="$HOME/.claude/synapse-ignore-files.conf"
EXTRA_RE="${SYNAPSE_EXTRA_EXCLUDE_RE:-}"
if [[ -f "$IGNORE_CONF" ]]; then
    while IFS= read -r pat; do
        pat="${pat%%#*}"
        pat="$(printf '%s' "$pat" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [[ -n "$pat" ]] || continue
        EXTRA_RE="${EXTRA_RE:+$EXTRA_RE|}$pat"
    done < "$IGNORE_CONF"
fi
readonly EXTRA_RE

# A cap rather than a pattern, because no extension or name rule anticipates a
# generated monster. Borrowed from Graft, which caps at the same 1 MB. Counted
# and reported below: a file dropped silently would make `enumerated` a number
# that quietly disagrees with the repo.
readonly MAX_FILE_BYTES="${SYNAPSE_MAX_FILE_BYTES:-1048576}"

if [[ ! -s "$ALL" || "$reenumerate" == true ]]; then
    echo "--- enumerating tracked files"
    : > "$WORK_DIR/oversize.txt"
    git ls-files \
        | grep -vE "$BINARY_RE" \
        | grep -vE "$NOISE_RE" \
        | grep -vE "${EXTRA_RE:-^$}" \
        | while IFS= read -r p; do
        # -f drops submodule gitlinks: one ls-files entry each, but a directory on
        # disk, and `git hash-object` fails the whole batch on one. Written as an
        # `if` because as the body's last statement a false `[[ -f ]] && printf`
        # makes the loop exit 1, which under `set -e` kills the script.
        # `[[ -f ]]` is a shell builtin, so this loop stays subprocess-free. Sizes
        # are NOT taken here: a `wc -c` per path costs one fork each, which
        # measured 21s for 3,000 files -- about 15 minutes on a 125k-file repo,
        # against 0.075s for the batched `stat` below. Per-file forks are the
        # thing to avoid in any loop over a whole repository.
        if [[ -f "$p" ]]; then
            printf '%s\n' "$p"
        fi
    done > "$WORK_DIR/candidates.txt"

    # One `stat` per xargs batch rather than per file. Both dialects: BSD takes
    # -f '%z %N', GNU -c '%s %n', and CI runs Linux while development runs macOS.
    if stat -f '%z' . >/dev/null 2>&1; then
        stat_args=(-f '%z %N')
    else
        stat_args=(-c '%s %n')
    fi
    tr '\n' '\0' < "$WORK_DIR/candidates.txt" \
        | xargs -0 stat "${stat_args[@]}" 2>/dev/null \
        | awk -v cap="$MAX_FILE_BYTES" -v over="$WORK_DIR/oversize.txt" '
            {
              sz = $1
              name = $0; sub(/^[0-9]+ /, "", name)   # a path may contain spaces
              if (sz > cap) printf "%s\t%s\n", sz, name >> over
              else print name
            }' > "$ALL"
    rm -f "$WORK_DIR/candidates.txt"
fi

if [[ -s "$WORK_DIR/oversize.txt" ]]; then
    printf 'skipped %s file(s) over %s bytes (largest first):\n' \
        "$(wc -l < "$WORK_DIR/oversize.txt" | tr -d ' ')" "$MAX_FILE_BYTES"
    LC_ALL=C sort -rn "$WORK_DIR/oversize.txt" | head -5 | awk -F'\t' '{ printf "  %10s  %s\n", $1, $2 }'
fi
printf 'enumerated: %s\n' "$(wc -l < "$ALL" | tr -d ' ')"
