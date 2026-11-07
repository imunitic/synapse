---
name: synapse-status
description: Read-only report of what in Synapse Vault currently needs a human decision.
---

# Synapse Status: Vault-Wide Attention Report

A read-only report of what in Synapse Vault currently needs a human decision, produced by the `synapse
status` command: an org-agenda-style check-in, printed as plain chat text. Run it whenever the user
asks for a vault status check, or on a recurring schedule the user has set up themselves -- never
wired into session start: the report reads the content of design notes, which unlike the vault's own
index note is not something the agent needs injected every session to behave correctly.

## Usage

Ask for a vault status check, or use the skill by name.

## Producing the report

Run `synapse status` and print what it prints, directly in the response and not left only in
tool-call output the user would have to go dig for. If it fails (no vault configured), say so and
stop -- there is no other fallback.

The report has up to five sections, left out when empty, and says "Vault is clear -- nothing
outstanding." when there is nothing:

- **Discussing:** design notes whose `## Status` is `Discussing`.
- **Ready, not yet compiled:** `Ready` design notes with no `> Compiled task:` line.
- **Open questions:** `Ready` design notes with a non-empty `## Open Questions`, naming the compiled
  task or saying there is none, and leaving out those whose compiled task is `DONE`.
- **In progress (unchecked items):** `TODO`/`IN-PROGRESS` tasks, with how many items are unchecked.
- **Awaiting review:** tasks in `REVIEW`.

Each line leads with the note's own id in brackets (`note_id` for a design note, `task_id` for a task
note) so that a human can act on it directly ("open sb-068"). `synapse status --format json` gives the
same report as `synapse-status/v1`, with the path of every note, for a tool that reads it.

## Constraints

- Read-only end to end. Never calls `vault-write`/`vault-patch` -- if a step here ever seems to need
  one, that step is out of scope, not a case to special-case around.
- No Artifact/web-UI output. No session-start wiring.
- Scoped to `designs/`/`tasks/` only -- never `inbox/`/`research/`/`scratchpad/`, which are per-install
  and for the vault owner's own periodic look.
