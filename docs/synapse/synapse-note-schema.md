# Vault note schemas

A note decides to be validated by declaring a schema:

```yaml
schema: vault-note/v1
```

in its frontmatter. The schema system is opt-in — a note without that field is a
plain **legacy** note, always valid, and validation never runs on it. A note that
*does* declare a schema is held to its contract on every `vault-write`/`vault-patch`
(see [Writes](#writes)), and a `vault-check` run audits every schema-declaring note in one
pass (see [vault-check](#vault-check)).

Three schemas ship in the `@imunitic/synapse` package, under
`$SYNAPSE_CONTENT_ROOT/schema/`:

| Schema id | Note kind | Shipped file |
|---|---|---|
| `vault-note/v1` | a general research/decision note | `schema/vault-note/v1.yaml` |
| `vault-design-note/v1` | a design note (`/synapse-design-note`) | `schema/vault-design-note/v1.yaml` |
| `vault-task-note/v1` | a task note (`/synapse-task-note`) | `schema/vault-task-note/v1.yaml` |

A schema id has the form `{kind}/{version}` and always resolves to
`$SYNAPSE_CONTENT_ROOT/schema/{kind}/{version}.yaml` — it must stay safely inside that
directory (a schema id is rejected if it points anywhere else).

## What a schema file looks like

A schema document is written in a deliberately small YAML subset (see
[the YAML subset](#the-yaml-subset)). Its shape:

```yaml
# Declared keys are the full v1 spec; enforcement is a deliberate subset —
# unknown note fields are ignored, never an error.
schema: synapse-note-schema/v1     # the schema-document language, fixed
id: vault-task-note/v1             # must equal the schema id the note declares
frontmatter:
  fields:
    task_id:
      type: string                 # string | timestamp | list | integer | boolean
      required: true
      pattern: '^[a-z][a-z0-9-]*-[0-9]{3,}$'
      mutable: false               # absent means mutable on update
body:
  h1:                              # the H1 heading under the frontmatter
    required: true
    count: 1
    equals: frontmatter.title      # H1 text must equal this scalar
  sections:                        # named H2+ headings, in order
    - title: Checklist
      level: 2
      required: true
  lead:                            # prose directly under the H1
    type: prose
    required: true
checks:                            # cross-field invariants, JsonLogic expressions
  - on_create:
      var: id_is_unique
    message: 'frontmatter.task_id: identity already exists'
  - lte:
      - var: created_epoch
      - var: updated_epoch
    message: 'frontmatter.updated: must not precede frontmatter.created'
```

See [Schema rule language](synapse-schema-rules.md) for the full `checks:`/`lints:` syntax.

## `frontmatter.fields`

The only keys under `frontmatter` in v1. Each field is a mapping of rules:

| Rule | Meaning |
|---|---|
| `type` | `string`, `timestamp`, `list`, `integer`, or `boolean`. For `list`, `items` says the element type — v1 supports only `string` elements. |
| `required` | The field must be present. |
| `min_length` | String/timestamp length floor, **at least 1**. |
| `const` | The field must equal this exact string. |
| `pattern` | A bounded regex the scalar must match (see [the pattern dialect](#the-pattern-dialect)). |
| `enum` | String allow-list the scalar must be in. |
| `mutable` | `false` freezes the field across updates — the value must be byte-identical on every `vault-write`/`vault-patch` after creation. Absent, or `true`, means it may change. |
| `format` / `timezone` / `update_on` | Declared metadata for `timestamp` fields (local time, refreshed on write/patch). Declared-but-soft — see [Declared keys vs. enforcement](#declared-keys-vs-enforcement). |

Known-but-unenforced flags appear in the shipped schemas today (`format`,
`timezone`, `update_on`) — they document intent without adding a rule the validator
doesn't implement.

Frontmatter stays **open-world**: a field not declared by the schema is preserved and
ignored, never an error. Both flow (`tags: [a, b]`) and block
(`tags:\n  - a\n  - b`) YAML list styles are accepted for list-valued fields.

## `body`

| Key | Meaning |
|---|---|
| `h1` | The first `#` heading. `required`, `count` (default 1), and `equals` (must match a scalar, e.g. `frontmatter.title`). |
| `preamble` | A list of blockquotes/glue directly under the H1 (`type`, `required`, `position`, `pattern`). Used by the design-note schema for the `> Compiled task:` backlink. |
| `sections` | Named headings below the H1, in `section_order` (`relative` in every v1 schema). Each entry: `title` (or `title_pattern`), `level`, `required`, `non_empty`, `max_occurs`, `content` (`type`/`enum`), `children` (recursive section rules). |
| `lead` | Prose directly under the H1 (`type: prose`, `required`, `position`). Task notes hold their lead this way. |
| `checklist` | Task-note checklist: `required`, `min_items`, `nested_items`, `allowed_children`, `position`. The checklist must sit under a named `## Checklist` H2 (a sibling of `## Notes`, not nested under it) — which is also what lets `vault-patch` scope a checklist edit without touching the body around it. |

Body enforcement is structural (which headings exist, in what order, non-empty or not)
rather than body-text freeform validation.

## `checks`

A list of cross-field invariants; each entry is a JsonLogic expression plus an optional `message:`
sibling carrying its diagnostic text. See [Schema rule language](synapse-schema-rules.md) for the
full operator reference, the data tree a rule evaluates against, and worked examples — this
section covers only what's specific to `checks:` itself.

Every entry in `checks:` blocks the write outright when it fails; there's no severity choice the
way `lints:` has one. A create-only invariant wraps its condition in `on_create` rather than
carrying a separate `when:` key:

```yaml
checks:
  - on_create:
      var: id_is_unique
    message: 'frontmatter.note_id: identity already exists'
```

## `lints`

A list of advisory rules; each entry is a JsonLogic expression plus a required `severity` and an
optional `message:`, same as `checks:` — see [Schema rule language](synapse-schema-rules.md) for
the operator reference. Unlike `checks:`, a lint never blocks a write on its own — what happens
depends entirely on its `severity`:

| Severity | Behavior |
|---|---|
| `ignore` | The rule is skipped entirely — not run, not silently discarded output, just never evaluated. |
| `warn` | The rule runs; a finding is printed to stderr (`synapse: {path}: {message}`), never surfaced in `WriteResult`, the exit code, or stdout. The write proceeds regardless. |
| `error` | The rule runs; a finding blocks the write the same way a `checks:` violation does — a 422-style rejection, the candidate never reaches the inner store. |

```yaml
lints:
  - no_hard_wrap:
      var: body.prose
    severity: warn
    message: 'body: no_hard_wrap paragraph is wrapped'
```

`synapse vault-check` always reports every lint finding regardless of severity — a read-only sweep
over already-persisted notes has nothing to block, so `error` there means "flag prominently," not
"refuse."

## Schema overrides

A shipped schema (`schema/{kind}/{version}.yaml`) can be corrected locally without forking the
whole file: a `schema-overrides/{kind}/{version}.yaml` file, resolved through the standard tiered
config cascade (see [synapse-config.md](synapse-config.md#where-a-conf-file-actually-lives)) —
`$XDG_CONFIG_HOME/synapse/schema-overrides/{kind}/{version}.yaml` if set, else
`~/.config/synapse/schema-overrides/{kind}/{version}.yaml`, else
`~/.claude/schema-overrides/{kind}/{version}.yaml`. No separate opt-in: the override file's own
presence is the opt-in, the same way a `{ext}.scm` grammar override works. Absent entirely, schema
loading is byte-identical to not having this feature at all.

When an override resolves, it's parsed with the same strict YAML subset as the base schema and
deep-merged onto it before validation runs:

- **Maps merge key by key, recursively, at every depth** — an override can touch
  `frontmatter.fields`, `body`, or any other nested map exactly the same way it touches the
  top level. A key the override doesn't mention is left exactly as the base schema declared it.
- **A literal `null` at a map key deletes that key from the merged result** — the way to remove a
  field from `frontmatter.fields` (or any other map-valued key) entirely, rather than restating
  everything else around it.
- **A scalar, or a key where the two sides disagree on map-ness, is replaced wholesale.**
- **A list is either a literal replacement or a set of `match`-shaped patches, never both.** A
  plain list (today's only shape, still the default) replaces the base's list wholesale — omitting
  an entry removes it, including one adds it. A list whose entries are *all* shaped `{match, ...}`
  is patch mode instead: `match` is a partial pattern naming only the fields needed to find an
  entry already in the base list (regardless of what other fields that entry also has), and every
  other key in the same patch entry merges onto every entry `match` finds, using the same
  key-by-key rules above. A `match` that finds nothing is a schema-load error, not a silent no-op;
  finding more than one entry is not an error — the merge applies to each one independently. A
  patch entry with `match` and nothing else removes every entry it finds. Adding a wholly new
  entry that doesn't already exist in the base list is not patch mode's job — that stays the plain
  list's wholesale-replace, the same as it always has been. Mixing `match`-shaped and plain entries
  in the same list is a schema-load error.

Example — promote `no_hard_wrap` to a blocking error, naming only its operator and argument rather
than restating the whole entry, and drop the `tags` field's own rule entirely, for `vault-note/v1`
only:

```yaml
# schema-overrides/vault-note/v1.yaml
lints:
  - match:
      no_hard_wrap:
        var: body.prose
    severity: error
frontmatter:
  fields:
    tags: null
```

`match` also composes into a bulk edit — every entry `match` finds gets the delta, not just the
first one:

```yaml
# schema-overrides/vault-task-note/v1.yaml
lints:
  - match:
      severity: warn
    severity: error
```

And a `match` entry with nothing beside it removes every entry it finds, rather than being read as
a no-op:

```yaml
# schema-overrides/vault-note/v1.yaml
lints:
  - match:
      no_id_prefix_in_title:
        - var: frontmatter.title
        - var: frontmatter.note_id
```

`vault-task-note/v1` and `vault-design-note/v1` are completely unaffected — an override always
targets exactly the one schema id its own path names.

## Declared keys vs. enforcement

`validateSchema`'s allow-lists accept a **superset** of what a note is checked against,
deliberately: the shipped schema files are the full v1 spec, while enforcement is a
subset. A key that is declared but not enforced (`format`, `timezone`, `update_on`,
`body.preamble.*`, `body.lead.*`, `body.checklist.nested_items`/`allowed_children`/
`position`, `body.section_order`, `body.h1.equals`) documents
intent without adding a rule the validator doesn't run. This is option A of the v1
contract — the validator guarantees that declared fields are present and correctly
formatted, and that's all. Note frontmatter stays open-world on top of that.

The DSL is strict about the *schema document itself*: an unsupported key is an explicit
schema error, never silently skipped. Negative counts are rejected at schema-validation
time (a `min_length: -1` fails before any note is judged against it), boolean rule-values
are type-checked, and `min_length`/count diagnostics carry the configured bound rather
than a generic message.

## Writes

`vault-write`/`vault-patch` go through the mandatory `SchemaValidationStore` boundary
(always immediately above `DiskStore`, wrapping it even with no integration configured).
On write it:

1. Reads the existing note (if any) and the candidate's `schema` field. Removing a schema
   from a note that already declares one is rejected.
2. Rejects an unsafe schema id (empty, absolute, `..`, or non-alpha-numeric segments).
3. Determines the mode — `create` (no existing note), `migration` (existing note that had
   no schema, or a different one), or `update`.
4. Refreshes `updated` to the current local time on any update, before validation.
5. Loads and validates the schema document, then validates the note against it — loading
   whichever `<stem>.conf` vocabulary files the schema's own rules actually reference (see
   [Schema rule language](synapse-schema-rules.md#vocabularies-resolved-by-reference-not-declared))
   and scanning the vault for a colliding identity on create/migration, only when the schema
   references `id_is_unique` in the first place.
6. Persists through the inner store only if every check passes; otherwise returns a
   422-style rejection with the diagnostic.

So a rejected write never reaches disk or Git — validation is a correctness
boundary, not a configurable integration.

## `vault-check`

```sh
synapse vault-check
```

A **read-only** conformance audit: lists the vault, and for every note that declares a
`schema` field resolves, validates, and interprets the schema, printing one
`note <TAB> message` line per violation. It summarizes at the end:

```
244 notes: 0 schema-declaring (0 conformant, 0 violations), 244 legacy
```

It exits `0` when every schema-declaring note conforms (or there are none), `1` when any
declared note has a violation. Legacy notes are only counted — an audit over the schema
contract has nothing to say about notes that opted out of it. This is the command a
migration or a review runs when it wants the whole vault's conformance in one pass rather
than a write-by-write yes.

## The YAML subset

Schema documents are parsed by a strict, small YAML reader (`core/schema_yaml`), not a
general-purpose one. It accepts mappings, lists, strings, decimal integers, booleans, and
comments — and **refuses** what makes YAML stateful or surprising: anchors/aliases, tags,
block scalars, flow maps, multiple documents, tabs for indentation, and implicit scalar
typing. A schema file is trusted, internal input and must parse deterministically to the
letter.

## The pattern dialect

`pattern` (on fields, and section `title_pattern`/preamble `pattern`) uses a bounded
regular-expression dialect (`core/schema_pattern`) — the extra power that
`regex_lite` deliberately lacks. Supported: literals, `.`, character classes (including
ranges and negation), `*`/`+`/`?`, counted repetition `{n}`/`{n,}`/`{n,m}`, and `^`/`$`
anchors. **Not** supported: groups, alternation, captures, backreferences. Matches
anywhere in the value unless anchored with `^`.