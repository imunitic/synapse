# Synapse Desktop

A desktop client for `synapse-pipeline`, developed as a web app first and wrapped in Tauri 2 afterwards.

## Download

Each release of Synapse has a `Synapse Desktop_<version>_aarch64.dmg` on its [GitHub Release](https://github.com/imunitic/synapse/releases), for macOS on Apple Silicon. Open it and drag Synapse Desktop to Applications.

The app is not notarized by Apple, so macOS blocks a downloaded copy the first time. Run this once after copying it:

```sh
xattr -dr com.apple.quarantine "/Applications/Synapse Desktop.app"
```

The app brings its own `synapse`, `synapse-hook` and `synapse-pipeline`, of the same version as the app. It needs no Node, Rust or Synapse installed to run.

## Installing Synapse into your harnesses

Install and update Synapse in Claude Code, Codex and OpenCode from the app: Settings, then Integrations. It installs the same version of Synapse the app bundles, and after the app is updated it offers to update the harnesses to match.

A version installed another way is not supported: by hand with npm, or newer or older than the app's. The Integrations page shows it, and offers to replace it with the app's version.

Installing runs `npm install -g` and each package's `configure` in a terminal tab, so it needs Node and npm. Without it, a harness started from the app's Terminals page still loads the app's Synapse, for that session only.

## Run it

Needs Node 24 or later and the `synapse-pipeline` binary on `PATH`.

```sh
npm install
npm run dev      # the Node host on :5174 and the Vite dev server on :5173
```

Open <http://127.0.0.1:5173>. `npm run check` is what CI runs: type-check, build, lint, format check and tests.

## The desktop app

The desktop build is a Tauri 2 window with the Rust host in its own process; it needs no Node at run time. Needs a Rust toolchain and the programs built in this checkout (`just build`).

```sh
npm run app:dev     # the window on the dev server, with hot reload
npm run app:build   # Synapse Desktop.app in src-tauri/target/release/bundle/macos
```

`npm run stage` (part of both) copies what the app brings with it into `src-tauri/resources`, from where Tauri bundles it into the app's resource folder: `bin/` with the native `synapse`, `synapse-hook` and `synapse-pipeline`, and `packages/` with the skills, commands and harness files of the two packages. The host puts `bin/` first on the `PATH` of everything it starts and reads the packages from there. The native programs are used, not the Node launchers of the npm packages.

The page and the host talk by the same messages as in the served build, over Tauri's IPC (`web/transport/tauri-link.ts` and the commands in `src-tauri/src/app_main.rs`). The window itself is given no file or shell access: the host does that, and only for the messages of the protocol.

## End-to-end tests

`npm run e2e` runs the app in a browser (Playwright, Chromium) against the Node host, and `npm run e2e -- --host rust` against the Rust host (`src-tauri/`), which it builds first with `cargo`. It runs on a world made for the run: a temporary configuration directory with a few definitions, a `synapse.conf`, a finished run with a transcript and a folder that looks like a vault. Runs are scripted, so no agent is started and nothing costs anything. It needs the programs built in this checkout (`just build`) and the ports of `npm run dev` free, and `npx playwright install chromium` once. `just desktop-e2e` does all of it.

## Layout

| Path         | What it holds                                                                              |
| ------------ | ------------------------------------------------------------------------------------------ |
| `shared/`    | The messages of the protocol, the `Transport` contract and the values both sides agree on. |
| `web/`       | The React app. It reaches the machine only through a `Transport`, which sends messages.    |
| `server/`    | The Node host: it answers the messages over a WebSocket.                                   |
| `src-tauri/` | The Rust host: the same messages, answered in the process of the desktop build.            |

The React app in `web/` is split by role:

| Path              | What it holds                                                                                                             |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `web/app/`        | The entry: `main.tsx`, `App.tsx` and the stylesheets.                                                                     |
| `web/layout/`     | The frame around the pages: the shell, rail, tab bar, status bar, side panel and its panels.                              |
| `web/pages/`      | One file per screen. A page can be embedded in another, such as the definition page in a pipeline.                        |
| `web/components/` | Parts a page uses: cards, badges, forms, dialogs, views and the code editor.                                              |
| `web/state/`      | What has no screen: the app state, the loading hook and the providers for config and diagnosis.                           |
| `web/domain/`     | Pure logic with its tests, and the fake transport.                                                                        |
| `web/transport/`  | The `Transport` implementation that sends messages over a bus, and the WebSocket that carries them.                       |
| `scripts/`        | `dev.ts`, which starts the host and the dev server with one per-launch token, and `e2e.ts`, which runs the browser tests. |
| `e2e/`            | The browser tests and the world they run in.                                                                              |

## The protocol

The page and a host talk by messages over one bus: requests that are answered, topics that tell what changed, and streams for the terminals. [docs/protocol.md](docs/protocol.md) describes them. Each message is defined once in `shared/`, and both hosts answer it and are tested against the same example files in `shared/examples/` and the same end-to-end suite.

## How the Node host protects itself

Any web page can open a connection to a localhost server, so a WebSocket must come from an allowed `Host` and `Origin` and carry the per-launch token; this is checked once, when it opens. File access is limited to the work directory's `pipelines` folder and the definition directories, with symbolic links resolved first. The `cli` message runs only the listed subcommands of the listed programs, with no shell.

The Node host serves the web build. The desktop build runs the Rust host in its own process and needs no Node at run time.
