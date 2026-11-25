# Synapse Desktop

Synapse Desktop is the app for all of Synapse. It installs Synapse into Claude Code, Codex and OpenCode, and keeps them on the app's version. It shows the Vault, and lets you read, write and edit its notes. It runs pipelines and shows each run as it goes, and it lets you review what a run changed. It also hosts the harness terminals, so an agent session can run inside the app.

The app brings its own `synapse`, `synapse-hook` and `synapse-pipeline`. You do not need Node, Rust or Synapse installed to run it.

These pages are for a person who uses the app. They say what each area of the app is for and how to do the common tasks there. They do not list every button and setting.

## Pages

- [Getting started](getting-started.md): install the app, choose a vault, install Synapse into your harnesses, write a first note and run a first pipeline.
- [Home page](home.md): what needs your attention, what is running, and where to pick up.
- [Code graph](code-graph.md): browse the code graph of a repository.
- [Terminals](terminals.md): start Claude Code, Codex, OpenCode or a shell inside the app.
- [Definitions](definitions.md): find, open, edit and run pipeline definitions.
- [Executions](executions.md): follow a run, answer its interactive steps and review what it changed.
- [Vault and notes](vault.md): browse the vault, read and edit notes, and make new ones.
- [Settings](settings.md): the work directory, the vault, projects and conventions, the code graph, the environment, terminals, and the Integrations page.

## Other readers

- You use Synapse from the command line: start with the [Synapse documentation](../synapse/README.md) and the [command reference](../synapse/cli.md).
- You want to change the app itself: read the app's [developer README](https://github.com/imunitic/synapse/blob/main/synapse_desktop/README.md) and its [protocol](https://github.com/imunitic/synapse/blob/main/synapse_desktop/docs/protocol.md).
