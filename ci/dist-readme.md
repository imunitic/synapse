# synapse-bard — dist

Machine-generated. Do not edit by hand — this branch is force-pushed by
`.github/workflows/bard-dist.yml` on every push to `main`, and everything
here, this file included, is overwritten each time.

This branch holds prebuilt `synapse-bard`/`synapse-bard-hook` binaries for
the **latest build only**: no history, no older versions, one commit that
replaces the last one. One `.tar.gz` per target platform (`x86_64-linux`,
`aarch64-linux`, `aarch64-macos`), plus one `SHA256SUMS` covering all of
them. Synapse's own binaries no longer live here — they're distributed via
npm (`@imunitic/synapse`) instead, bundled directly rather than fetched.

`plugins/synapse-bard/hooks/fetch-and-run.cjs` fetches `SHA256SUMS`
alongside its own tarball and verifies it before extracting —
`raw.githubusercontent.com` is plain HTTP-over-TLS to GitHub's CDN, not a
signed artifact channel, so this is what actually confirms a downloaded
tarball is the one this workflow published.

## Why this exists instead of GitHub Releases

`fetch-and-run.cjs` fetches the binary on first use and caches it locally,
rather than shipping a platform-specific binary inside the plugin itself.
That fetch used to point at a GitHub Release download URL. In an
Anthropic-hosted Claude Code cloud sandbox — the environment
`synapse-bard`'s primary user runs in, via the Android app — release-asset
downloads route through a proxy that only allows requests to the
repository actually attached to that session; any other repo's release
assets get a 403, even though the URL is otherwise public.
`raw.githubusercontent.com` isn't subject to that restriction, so
binaries live here as plain committed files instead, fetched from this
branch directly.

## Why every push to main, not a tagged release

Synapse's own releases (`release.yml`) are tag-only and semver-versioned —
deliberate, infrequent, npm-published. Bard isn't tied to that cadence: her
author isn't drafting alongside a release schedule, so this publishes
whatever's on `main` after every push, unconditionally.

## Version

`version.txt` in this branch's root holds the build's version,
`YYYY-MM_N` — a human-readable date plus a same-month counter, not a git
tag. Deliberately not a tag on `main`: this branch is rebuilt from scratch
every push, so nothing needs a durable ref, and a tag here would sit in
the same namespace `release.yml`'s own tag-push trigger watches for real
releases.

See the `main` branch's `README.md` for what Synapse and Synapse Bard
actually are.
