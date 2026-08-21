# synapse — dist

Machine-generated. Do not edit by hand — this branch is force-pushed by
`.github/workflows/release.yml` on every push to `main`, and everything
here, this file included, is overwritten each time.

This branch holds prebuilt binaries for the **latest release only**: no
history, no older versions, one commit that replaces the last one.
`synapse`/`synapse-hook` and `synapse-bard`/`synapse-bard-hook`, one
`.tar.gz` per target platform (`x86_64-linux`, `aarch64-linux`,
`aarch64-macos`).

## Why this exists instead of GitHub Releases

Both plugins' `hooks/fetch-and-run.sh` fetch their own binary on first use
and cache it locally, rather than shipping a platform-specific binary
inside the plugin itself. That fetch used to point at a GitHub Release
download URL. In an Anthropic-hosted Claude Code cloud sandbox — the
environment `synapse-bard`'s primary user runs in, via the Android app —
release-asset downloads route through a proxy that only allows requests
to the repository actually attached to that session; any other repo's
release assets get a 403, even though the URL is otherwise public.
`raw.githubusercontent.com` isn't subject to that restriction, so
binaries live here as plain committed files instead, fetched from this
branch directly.

## Version

This branch's one commit message names the release tag it was built
from (`dist: YYYY-MM_N`). `main`'s own git tags are the full release
history; this branch keeps none.

See the `main` branch's `README.md` for what Synapse and Synapse Bard
actually are.
