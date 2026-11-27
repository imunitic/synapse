# The Synapse Desktop protocol

The messages between the frontend and a host. There are two hosts: the Node host (`server/`), which serves the web build over a WebSocket, and the Rust host (`src-tauri/`), which the desktop build runs in its own process. They answer the same messages, read the same example files, and pass the same end-to-end suite (`npm run e2e -- --host node` and `--host rust`).

The definition is in `shared/`: `protocol.ts` holds the envelope, `messages.ts` the table of requests, `terminal.ts` the terminal streams. The Rust types in `src-tauri/src/protocol.rs` and `messages.rs` are written by hand to match.

## Link

A Link is a pipe that carries one JSON message at a time, in both directions, and tells when it closes. What carries it is not part of the protocol: a WebSocket to the Node host on `/api/bus`, Tauri's IPC to the Rust host, a pair of channels in a test.

## Connecting

The host sends `hello` first. A frontend sends nothing before it.

```json
{
  "kind": "hello",
  "protocol": 1,
  "capabilities": { "host": "node", "shell": true, "installActions": true }
}
```

`protocol` is the version of this document, 1; it changes with any change an older frontend or host would misread. `capabilities` says what the host can do, and the frontend adapts to it:

| Field            | Meaning                                                   |
| ---------------- | --------------------------------------------------------- |
| `host`           | `node`, `tauri` or `fake`.                                |
| `shell`          | A shell can be started in a terminal.                     |
| `installActions` | Synapse can be installed into the harnesses from the app. |

A WebSocket is checked once, when it is opened: the `Host` and `Origin` headers must be the app's own and the per-launch token must be present. A connection that passed is the page's own.

## Messages

A message is an object with a `kind`.

From the frontend:

| Kind          | Fields                 | Meaning                                                         |
| ------------- | ---------------------- | --------------------------------------------------------------- |
| `request`     | `id`, `name`, `params` | Asks for one of the requests below. `id` is 1 to 64 characters. |
| `subscribe`   | `topic`, `after?`      | Asks to be told what happens at a topic, after a cursor.        |
| `unsubscribe` | `topic`                | Stops it.                                                       |
| `stream`      | `session`, `data`      | A message to a terminal session.                                |

From the host:

| Kind     | Fields                     | Meaning                                                   |
| -------- | -------------------------- | --------------------------------------------------------- |
| `hello`  | `protocol`, `capabilities` | See above.                                                |
| `reply`  | `id`, `result` or `error`  | The answer to the request with that `id`: one of the two. |
| `event`  | `topic`, `cursor?`, `data` | Something happened at a topic.                            |
| `stream` | `session`, `data`          | A message from a terminal session.                        |

`shared/examples/_envelope.json` has one of each.

### Requests

A request has a `name` from the table below, and its `params` are the object that message takes. A request that has nothing to say answers `null`. Parameters that are not the ones the message takes are refused with `bad_request` before a handler sees them.

| Name                                                                   | What it does                                                                         |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| `fs.read`, `fs.list`                                                   | Read a file or list a folder inside the folders the host may touch.                  |
| `cli`                                                                  | Run one of the listed programs with one of its listed subcommands, with no shell.    |
| `config.get`, `config.set`                                             | The app's settings and the folders they name.                                        |
| `registry.list`, `registry.add`, `registry.remove`                     | The projects and the conventions Synapse keeps in the configuration directory.       |
| `models.get`                                                           | The models of a harness, kept between runs.                                          |
| `history.get`                                                          | The sessions and workspaces of the harnesses.                                        |
| `agent.run`                                                            | Have a harness write a definition, a note, a change to a note or the input of a run. |
| `note.restore`                                                         | Put a note back as it was before an edit.                                            |
| `definition.preview`, `definition.write`                               | Check and save a definition.                                                         |
| `run.start`, `run.stop`, `run.ask`                                     | Start a run of a pipeline, stop it, and ask it about itself.                         |
| `vault.inspect`, `vault.seed`                                          | What a folder holds as a vault, and make it one.                                     |
| `graph.repo`, `graph.health`, `graph.manage`                           | The code graphs: where they were built from, how they are, and cleaning them.        |
| `terminal.start`, `terminal.attach`, `terminal.list`, `terminal.close` | The terminal sessions, below.                                                        |
| `diagnose`, `integrations`                                             | What is set up on this machine, and what Synapse is installed into.                  |

### Errors

An error is `{ "code", "message" }`. The code says what went wrong without saying what carried the message:

| Code          | Meaning                                                                                           |
| ------------- | ------------------------------------------------------------------------------------------------- |
| `bad_request` | The parameters are not the ones the message takes.                                                |
| `not_found`   | What was asked for is not there.                                                                  |
| `forbidden`   | The host refuses it: outside the folders it may touch, or not allowed.                            |
| `conflict`    | The state of things does not allow it: nothing set up yet, or the file changed since it was read. |
| `too_large`   | A file or an input is over the limit.                                                             |
| `unavailable` | Something the host depends on failed: a program or a harness.                                     |
| `internal`    | Anything else. The message does not carry the detail.                                             |

## Topics

A topic is what a client subscribes to to be told of a change.

| Topic               | Event                                                                   |
| ------------------- | ----------------------------------------------------------------------- |
| `files.work`        | Something under the work directory's `pipelines` folder changed.        |
| `files.definitions` | Something in the definition folders changed.                            |
| `files.vault`       | Something in the vault changed. `.git` and `.obsidian` are not watched. |
| `run.<id>`          | An event of the run with that id.                                       |

The `files.*` events have no cursor and no data: a client that is told reads again what it shows. A `run.<id>` event has the index of the run's event as its cursor. `subscribe` takes `after`, the cursor of the last event the client has, and the host sends what follows it. When a Link closes and another is given, the frontend subscribes again to every topic from the last cursor of each. Changes are gathered for 250 ms before a client is told.

## Terminals

A terminal session belongs to the host, not to a connection: a connection that goes leaves its sessions running, and a connection that attaches later is given the screen as the program drew it. A session belongs to the user who started it, and only that user can attach to it, type into it, close it or list it.

`terminal.start` makes a session and attaches the connection to it. `terminal.attach` attaches another connection, with its size. `terminal.list` lists the sessions of the user. `terminal.close` ends a session and its program.

After that the session's messages travel as `stream` messages with the session's name as `session`.

From the frontend, `data` is one of:

| `type`   | Fields         | Meaning                   |
| -------- | -------------- | ------------------------- |
| `input`  | `data`         | What is typed.            |
| `resize` | `cols`, `rows` | The size of the terminal. |

Input and size are taken only from a connection that is attached to the session, and not once the program has ended.

From the host, `data` is one of:

| `type`              | Fields                 | Meaning                                                                                                                 |
| ------------------- | ---------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `snapshot`          | `data`                 | The screen and its scrollback, as escape sequences that draw it. Sent when a connection attaches, before anything else. |
| `output`            | `data`                 | What the program printed.                                                                                               |
| `transcript-source` | `id`, `harness`, `cwd` | A conversation of a harness in the terminal is being followed.                                                          |
| `transcript`        | `id`, `lines`          | Lines of that conversation, in order.                                                                                   |
| `exit`              | `code`                 | The program ended with that code.                                                                                       |

A snapshot has 100 lines above the screen. A session whose program has ended is kept, readable, until its tab is closed. A session that no connection has been attached to for 12 hours ends. At most 8 sessions whose programs are running are open at once.

## Adding a message

1. Add its schemas to `shared/messages.ts` and, for a Rust type, to `src-tauri/src/messages.rs` with its rules.
2. Write its example in `shared/examples/<name>.json`: both hosts' tests read it, so the two sides agree on its form.
3. Answer it in `server/calls.ts` and in `src-tauri/src/families.rs`.
4. Call it from `web/transport/bus-transport.ts`.
