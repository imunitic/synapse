# The platforms Synapse ships prebuilt binaries for -- the single definition.
# `ci/build-targets.sh` (portability verification) and
# `.github/workflows/release.yml` (release artifacts) both source this rather
# than keeping their own copy of the list, because two copies of a list is
# one copy that goes stale.
#
# aarch64-macos is where the hooks actually run; x86_64-linux is CI, the test
# container, and bard's Android cloud session.
#
# x86_64-windows is deliberately absent, and its absence is a correction
# rather than an omission. Windows is *bard's* target -- its author's machine
# -- and bard does not exist yet. `synapse` is a developer tool for macOS and
# Linux, and cross-compiling it to Windows was over-broad from the start. It
# is also now impossible: `std.DynLib` is a compile error on Windows in Zig
# 0.16 ("unsupported platform"), and `synapse` loads grammars through it.
#
# That costs nothing bard needs. Bard uses the frontmatter extractor, links no
# libtree-sitter, and loads nothing dynamically -- which is exactly why it is
# a separate module. When bard exists it brings its own Windows target, and
# the portability guard this list provides moves with it.
targets=(x86_64-linux aarch64-macos)
