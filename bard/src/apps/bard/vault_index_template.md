---
title: "Index"
---

# Index
Map of the Writer's notes vault (`_bard/vault/`) folders and what each is for -- plain markdown
files, git-tracked in this repo, read and written with ordinary Read/Write/Edit/Glob/Grep. See the
`synapse-bard-vault` skill for how to search it and edit it safely.

This index is agent-maintained: whenever an agent creates a new top-level folder, it must add a
one-line section for it here in the same edit. Treat this file as out of date if a folder exists on
disk with no matching section below -- fix the drift rather than working around it.

This is a starter index, not a fixed schema -- an agent reads this file as the authority on what
your folders are and mean, not the other way around. Only the two structurally-fixed folders below
exist from the start; `projects/`, `research/`, `scratchpad/`, and `inbox/` aren't listed yet because
nothing has created one on this vault -- `/synapse-bard-design-note`, `/synapse-bard-task-note`, and
`/synapse-bard-note` each add their own section here the first time they actually create that folder.

## designs/
Free-form design discussions about the story -- tone choices, plot mechanics, character motivation
problems, worldbuilding decisions. Created and maintained by `/synapse-bard-design-note`.

## tasks/
Tracked work: a checklist compiled from a `Ready` design note (`/synapse-bard-task-note`), or created
directly (`/synapse-bard-note --task`). Status transitions (`TODO` → `IN-PROGRESS` → `REVIEW`, never
`DONE`) are handled by the `synapse-bard-task` skill, not by hand.
