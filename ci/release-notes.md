## Synapse Desktop

The installers are not signed with a paid certificate, so macOS and Windows ask for a confirmation the first time the app starts. Each `SHA256SUMS` line matches one of the files below; check a download with `shasum -a 256 -c SHA256SUMS --ignore-missing` (`sha256sum -c --ignore-missing SHA256SUMS` on Linux).

### macOS, Apple Silicon

Install from a terminal. A file downloaded with `curl` is not quarantined, so macOS opens the app without a prompt:

```sh
curl -fsSL https://github.com/imunitic/synapse/releases/download/@TAG@/install.sh | sh
```

It checks the download against `SHA256SUMS` and puts `Synapse Desktop.app` in `~/Applications`.

Or open `synapse-desktop_*_macos-arm64.dmg` and drag the app to Applications. macOS blocks the first start of a downloaded app: open it from its context menu (Open), or run `xattr -dr com.apple.quarantine "/Applications/Synapse Desktop.app"` once.

### Linux, x64

- `synapse-desktop_*_linux-x64.deb`: `sudo apt install ./synapse-desktop_*_linux-x64.deb`. It needs WebKitGTK 4.1, which Ubuntu 22.04 and Debian 12 and later have.
- `synapse-desktop_*_linux-x64.AppImage`: `chmod +x` it and run it. It needs FUSE 2 (`libfuse2`, or `libfuse2t64` on Ubuntu 24.04), which recent Ubuntu does not install.

### Windows, x64

Run `synapse-desktop_*_windows-x64-setup.exe`. It installs for the current user and needs no administrator rights. SmartScreen shows "Windows protected your PC": choose "More info", then "Run anyway". If the WebView2 runtime is missing (Windows 11 has it), the installer downloads it and needs a network connection.
