//! Which of a repo's tracked files belong in the graph.
//!
//! Three filters, and only two of them live here. The binary-extension set and
//! the generated-noise set are *ours*: fixed lists shipped with the tool, and
//! the bash spelled them as EREs (`\.(png|gif|…)$`, `(^|/)(yarn\.lock|…)$`)
//! only because `grep -vE` was the tool at hand. They are a suffix test and a
//! basename test, so they are written as those here — no regex engine, and no
//! chance of a pattern typo silently matching everything.
//!
//! The third filter is user-supplied EREs from
//! `~/.claude/synapse-ignore-files.conf` and `$SYNAPSE_EXTRA_EXCLUDE_RE`. Those
//! stay with `grep -vE` in the caller, because an ERE means whatever `grep`
//! says it means and reimplementing a subset would be a second dialect that
//! disagrees at the edges. It costs one spawn, only when the user has patterns.
//!
//! ## Case sensitivity is deliberate, not an oversight
//!
//! `grep -vE '\.(png|…)$'` is case-sensitive, so the bash enumerates `LOGO.PNG`
//! and drops `logo.png`. That is arguably wrong, and it is not this port's
//! business to fix: the CLI contract is frozen, and a file appearing or
//! disappearing from `all.txt` changes which nodes claim it. Matched
//! byte-for-byte here, with this comment so the next reader does not "fix" it
//! into a behaviour change.

const std = @import("std");

/// Extensions that are binary by nature. Dropped at enumeration so
/// `_unassigned` means "text I could not place" rather than "a PNG".
///
/// Grouped by what a file is rather than by ecosystem, so adding a language is
/// a one-line change. Source formats never belong here.
const binary_extensions = [_][]const u8{
    // images and design files
    "png",  "gif",   "jpg",   "jpeg",  "bmp",  "tif",  "tiff", "webp",
    "avif", "ico",   "svgz",  "psd",   "ai",   "sketch", "fig",
    // audio and video
    "mp3",  "m4a",   "wav",   "flac",  "ogg",  "mp4",  "m4v",  "mov",
    "avi",  "mkv",   "webm",
    // archives
    "zip",  "gz",    "tgz",   "tar",   "bz2",  "xz",   "zst",  "7z",
    "rar",
    // packaged artefacts
    "jar",  "war",   "ear",   "class", "aar",  "apk",  "whl",  "egg",
    "gem",  "nupkg", "deb",   "rpm",   "dmg",  "pkg",  "msi",
    // compiled output
    "o",    "a",     "obj",   "lib",   "pdb",  "so",   "dylib", "dll",
    "exe",  "rlib",  "wasm",  "node",  "pyc",  "pyo",  "pyd",  "beam",
    // columnar and embedded data
    "parquet", "avro", "orc",  "db",   "sqlite", "sqlite3", "mdb",
    // serialised models and arrays
    "pkl",  "pickle", "npy",  "npz",  "h5",   "hdf5", "onnx", "pt",
    "pth",  "ckpt",  "safetensors", "gguf", "bin",
    // documents
    "pdf",  "xls",   "xlsx",  "doc",  "docx", "ppt",  "pptx", "odt",
    "ods",  "odp",
    // fonts
    "ttf",  "otf",   "woff",  "woff2", "eot",
    // keys and certificates
    "keystore", "jks", "p12",  "pem",  "crt",  "cer",  "der",
};

/// Generated files whose *names*, not extensions, identify them. A lockfile is
/// thousands of lines of resolved versions with nothing to summarise.
const noise_basenames = [_][]const u8{
    "package-lock.json", "npm-shrinkwrap.json", "yarn.lock",
    "pnpm-lock.yaml",    "Cargo.lock",          "poetry.lock",
    "Pipfile.lock",      "uv.lock",             "Gemfile.lock",
    "composer.lock",     "go.sum",              "mix.lock",
    "pubspec.lock",      "packages.lock.json",  "flake.lock",
};

/// A minified bundle or a source map is machine output that happens to end in
/// `.js`. Suffixes rather than basenames, because the stem is arbitrary.
const noise_suffixes = [_][]const u8{
    ".min.js", ".min.css",
    ".js.map", ".css.map", ".ts.map",
};

fn basename(path: []const u8) []const u8 {
    // Deliberately not `Io.Dir.path.basename`: the bash matched `(^|/)`, which
    // is a `/` test and nothing else, on every platform it runs on. A
    // path-aware basename would also split on `\` under Windows, which
    // `synapse` does not target and which would silently change what is
    // enumerated if it ever did.
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |at| return path[at + 1 ..];
    return path;
}

/// The extension after the last `.` of the basename, or null when there is
/// none. A leading dot is a hidden file, not an extension: `.gitignore` has no
/// extension, matching `\.(…)$`, which needs at least one character before the
/// dot to match.
fn extension(path: []const u8) ?[]const u8 {
    const name = basename(path);
    const at = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    if (at == 0) return null;
    return name[at + 1 ..];
}

/// Case-sensitive by design -- see the note at the top of this file.
pub fn isBinary(path: []const u8) bool {
    const ext = extension(path) orelse return false;
    for (binary_extensions) |e| if (std.mem.eql(u8, ext, e)) return true;
    return false;
}

pub fn isNoise(path: []const u8) bool {
    const name = basename(path);
    for (noise_basenames) |n| if (std.mem.eql(u8, name, n)) return true;
    for (noise_suffixes) |s| if (std.mem.endsWith(u8, name, s)) return true;
    return false;
}

/// Everything the shipped filters drop. The user's own patterns are applied by
/// the caller, before this.
pub fn isExcluded(path: []const u8) bool {
    return isBinary(path) or isNoise(path);
}

const testing = std.testing;

test "binary extensions are dropped, source formats never are" {
    for ([_][]const u8{
        "assets/logo.png",       "doc/manual.pdf",   "lib/libfoo.so",
        "target/app.jar",        "model/weights.pt", "fonts/Inter.woff2",
        "certs/ca.pem",          "data/rows.parquet",
    }) |p| try testing.expect(isBinary(p));

    // The list is about what a file *is*. A `.svg` is text and stays; `.svgz`
    // is the gzipped one and goes. Likewise `.ts` against `.ts.map`.
    for ([_][]const u8{
        "assets/logo.svg",       "src/main.java",    "src/app.ts",
        "README.md",             "Makefile",         ".gitignore",
        "conf/nginx.conf",       "src/mod.rs",
    }) |p| try testing.expect(!isBinary(p));
}

test "case sensitivity matches the bash byte for byte" {
    // `grep -vE '\.(png|…)$'` never matched an uppercase extension, so the
    // bash enumerated these. Changing that would move files into and out of
    // `all.txt`, which changes which nodes claim them -- a behaviour change
    // wearing a bug fix's clothes.
    try testing.expect(isBinary("logo.png"));
    try testing.expect(!isBinary("LOGO.PNG"));
    try testing.expect(!isBinary("logo.Png"));
}

test "lockfiles and generated bundles are dropped by name, at any depth" {
    for ([_][]const u8{
        "yarn.lock",             "web/package-lock.json",
        "a/b/c/Cargo.lock",      "go.sum",
        "dist/app.min.js",       "dist/style.min.css",
        "dist/app.js.map",       "dist/app.ts.map",
    }) |p| try testing.expect(isNoise(p));

    // `(^|/)` anchored the basename, so a path that merely *contains* the name
    // as a substring was never matched.
    for ([_][]const u8{
        "src/yarn.lock.example",  "docs/about-go.sum.md",
        "src/minified.js",        "src/app.map.ts",
        "my-package-lock.json",   "src/main.js",
    }) |p| try testing.expect(!isNoise(p));
}

test "a dotfile has no extension, so it is never dropped for one" {
    // `\.(…)$` needs a character before the dot, so `.pem` as a whole filename
    // never matched. A repo with a literal `.pem` file keeps it.
    try testing.expect(!isBinary(".pem"));
    try testing.expect(!isBinary("conf/.pem"));
    // But a named one is still dropped.
    try testing.expect(isBinary("conf/ca.pem"));
}

test "a path with no extension and no match survives both filters" {
    try testing.expect(!isExcluded("LICENSE"));
    try testing.expect(!isExcluded("bin/run"));
    try testing.expect(!isExcluded("src/deeply/nested/thing"));
}
