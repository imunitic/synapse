# The platforms Synapse ships prebuilt binaries for -- the single definition.
# `ci/build-targets.sh` (portability verification) and
# `.github/workflows/release.yml` (release artifacts) both source this rather
# than keeping their own copy of the list, because two copies of a list is
# one copy that goes stale.
#
# aarch64-macos is where the hooks actually run; x86_64-linux is CI, the test
# container, and bard's Android cloud session. aarch64-linux was added later,
# once podman testing under emulation showed it isn't the niche case it looked
# like from a developer-laptop vantage point: AWS Graviton, GitHub Actions'
# arm64 runners, and Docker Desktop on Apple Silicon (which defaults new
# containers to linux/arm64 unless told otherwise) all put it in front of
# plenty of real machines this plugin installs onto.
#
# x86_64-windows is deliberately absent, and its absence is a correction
# rather than an omission. `synapse` is a developer tool for macOS and
# Linux, and cross-compiling it to Windows was over-broad from the start. It
# is also now impossible: `std.DynLib` is a compile error on Windows in Zig
# 0.16 ("unsupported platform"), and `synapse` loads grammars through it.
#
# Correction, 2026-08-17: this comment used to say Windows was bard's target
# and would arrive once bard existed. It doesn't -- bard's author runs
# Claude Code almost entirely through the Android app's default cloud
# session (an ephemeral x86_64 Ubuntu VM, not her own machine), which made
# repo-local storage the primary design rather than a network-reachable
# Obsidian vault (see synapse-bard's own "Execution environment" design
# note). Bard ships the same platform set as synapse -- this same list,
# nothing narrower -- not just the one architecture her own session
# happens to run today.
targets=(x86_64-linux aarch64-linux aarch64-macos)
