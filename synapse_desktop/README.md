# Synapse Desktop

A desktop client for `synapse-pipeline`, developed as a web app first and wrapped in Tauri 2 afterwards.

## Run it

Needs Node 24 or later and the `synapse-pipeline` binary on `PATH`.

```sh
npm install
npm run dev      # the API server on :5174 and the Vite dev server on :5173
```

Open <http://127.0.0.1:5173>. `npm run check` is what CI runs: type-check, build, lint, format check and tests.

## Layout

| Path       | What it holds                                                                                     |
| ---------- | ------------------------------------------------------------------------------------------------- |
| `shared/`  | The `Transport` contract, the API call parameters and the values both sides agree on.             |
| `src/`     | The React app. It reaches the machine only through a `Transport`.                                 |
| `server/`  | The local API server of the web phase: guards, allowed directories, the CLI allowlist, the calls. |
| `scripts/` | `dev.ts`, which starts both servers with one per-launch token.                                    |

## How the server protects itself

Any web page can send a request to a localhost server, so every request must carry the per-launch token, come from an allowed `Host` and `Origin`, and be JSON. File access is limited to the work directory's `pipelines` folder and the definition directories, with symbolic links resolved first. The `cli` call runs only the listed subcommands of the listed binaries, with no shell.

The server is development tooling and is not shipped; Tauri replaces it by implementing the same `Transport`.
