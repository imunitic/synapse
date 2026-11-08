# Synapse Desktop

A desktop client for `synapse-pipeline`, developed as a web app first and wrapped in Tauri 2 afterwards.

## Run it

Needs Node 24 or later and the `synapse-pipeline` binary on `PATH`.

```sh
npm install
npm run dev      # the API server on :5174 and the Vite dev server on :5173
```

Open <http://127.0.0.1:5173>. `npm run check` is what CI runs: type-check, build, lint, format check and tests.

## End-to-end tests

`npm run e2e` runs the app in a browser (Playwright, Chromium) on a world made for the run: a temporary configuration directory with a few definitions, a `synapse.conf`, a finished run with a transcript and a folder that looks like a vault. Runs are scripted, so no agent is started and nothing costs anything. It needs the programs built in this checkout (`just build`) and the ports of `npm run dev` free, and `npx playwright install chromium` once. `just desktop-e2e` does all of it.

## Layout

| Path      | What it holds                                                                         |
| --------- | ------------------------------------------------------------------------------------- |
| `shared/` | The `Transport` contract, the API call parameters and the values both sides agree on. |
| `web/`    | The React app. It reaches the machine only through a `Transport`.                     |

The React app in `web/` is split by role:

| Path              | What it holds                                                                                              |
| ----------------- | ---------------------------------------------------------------------------------------------------------- |
| `web/app/`        | The entry: `main.tsx`, `App.tsx` and the stylesheets.                                                      |
| `web/layout/`     | The frame around the pages: the shell, rail, tab bar, status bar, side panel and its panels.               |
| `web/pages/`      | One file per screen. A page can be embedded in another, such as the definition page in a pipeline.         |
| `web/components/` | Parts a page uses: cards, badges, forms, dialogs, views and the code editor.                               |
| `web/state/`      | What has no screen: the app state, the loading hook and the providers for config and diagnosis.            |
| `web/domain/`     | Pure logic with its tests, and the fake transport.                                                         |
| `web/transport/`  | The `Transport` implementation that talks to the local server.                                             |
| `server/`         | The local API server of the web phase: guards, allowed directories, the CLI allowlist, the calls.          |
| `scripts/`        | `dev.ts`, which starts both servers with one per-launch token, and `e2e.ts`, which runs the browser tests. |
| `e2e/`            | The browser tests and the world they run in.                                                               |

## How the server protects itself

Any web page can send a request to a localhost server, so every request must carry the per-launch token, come from an allowed `Host` and `Origin`, and be JSON. File access is limited to the work directory's `pipelines` folder and the definition directories, with symbolic links resolved first. The `cli` call runs only the listed subcommands of the listed binaries, with no shell.

The server is development tooling and is not shipped; Tauri replaces it by implementing the same `Transport`.
