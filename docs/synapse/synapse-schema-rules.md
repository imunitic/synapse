# Schema rule language (`checks:`/`lints:`)

A schema's `checks:` and `lints:` lists (see [Note Schemas](synapse-note-schema.md)) are each
made of entries written in one small, composable expression language — the same
[JsonLogic](https://jsonlogic.com/)-shaped evaluator `vault-search` itself uses to filter notes,
extended with a handful of note-specific operators. One evaluator, one syntax, two call sites.

```yaml
checks:
  - eq:
      - var: filename.stem
      - var: frontmatter.title
    message: 'filename.stem: must equal frontmatter.title'
```

An entry is a single-key mapping naming an operator, whose value is that operator's argument(s).
Operators compose: any operator's argument can itself be another operator, nested as deep as the
rule needs. `eq`/`in`/`and`/`or`/etc. are exactly the built-ins `vault-search`'s own JsonLogic
queries already use — a rule referencing `frontmatter`/`body` here reads the same way a
`vault-search` query does.

## Block YAML only

Every argument that itself contains an operator or a `var` reference is written in block form, one
key per line — never JSON's inline flow-map form:

```yaml
# Right: block form.
- eq:
    - var: frontmatter.status
    - REVIEW

# Wrong: schema documents refuse this outright (error.FlowMap).
- eq: [{var: frontmatter.status}, REVIEW]
```

Schema documents are parsed by a strict YAML subset (see
[the YAML subset](synapse-note-schema.md#the-yaml-subset)) that refuses flow-map syntax
(`{a: b}`) entirely — a deliberate, pre-existing restriction, not something this rule language
loosens. A rule with several `var` references is more vertical than the JSON-flavored examples
JsonLogic's own site shows, but it's the same tree either way.

## Word-alias operators

That same strict parser also refuses a mapping key built from symbol characters — `==`, `!=`,
`<`, `<=`, `>`, `>=`, and `!` can't be written as YAML keys at all. A schema instead uses a
MongoDB-style word alias, renamed to the real operator during schema load:

| Word alias | Operator |
|---|---|
| `eq` | `==` |
| `ne` | `!=` |
| `lt` | `<` |
| `lte` | `<=` |
| `gt` | `>` |
| `gte` | `>=` |
| `not` | `!` |

`and`, `or`, `in`, `var`, `glob`, `regexp`, `all`, and `xor` are already alphabetic and appear
exactly as named below.

## Built-in operators

| Operator | Meaning |
|---|---|
| `var` | Looks up a dotted path in the data tree (see [The data tree](#the-data-tree)) — `{var: frontmatter.title}`. An empty path (`{var: ""}`) resolves to the current element inside `all` (see below), or the whole data tree everywhere else. A missing path resolves to `null`, not an error. |
| `and` / `or` | True iff every / any operand is truthy. |
| `not` (`!`) | Negates one operand. |
| `eq` (`==`) / `ne` (`!=`) | Deep equality (or its negation) between two operands. `null == null` is `true` — a rule that must also require both sides present composes that separately (e.g. `ne: [{var: frontmatter.a}, null]`). |
| `in` | `[needle, haystack]` — true if `needle` appears in a `haystack` array (deep-equal membership) or as a substring of a `haystack` string. |
| `lt` / `lte` / `gt` / `gte` (`<` / `<=` / `>` / `>=`) | Numeric or lexicographic comparison, whichever both operands agree on. Two digit-only *strings* compare lexicographically (`"9" < "10"` is `false`); a string against a number coerces. |
| `glob` / `regexp` | Pattern-match a string value: `[pattern, value]`. |
| `all` | `[array, condition]` — true iff `condition` holds for every element of `array` (vacuously true on an empty array). Inside `condition`, `{var: ""}` is the current element; every other `var` path still resolves against the full data tree, not the element — see [Iterating a list](#iterating-a-list-all). |
| `xor` | True iff exactly one operand is truthy (not "an odd count truthy"). |

## Custom operators

A handful of note-specific checks can't be expressed by composing the built-ins above — each is
one statically-registered function, taking the same shape as a built-in (no plugin/dynamic-loading
mechanism of any kind):

| Operator | Arguments | Meaning |
|---|---|---|
| `on_create` | one sub-expression | Short-circuits to `true` without evaluating its argument when the note isn't being created (`is_create` is `false`); otherwise evaluates and returns its argument. The way every create-only rule in the shipped schemas is written. |
| `no_hard_wrap` | `[text]` | True unless some paragraph in `text` is wrapped across two or more consecutive lines instead of written as one line for Obsidian to soft-wrap. Table rows, list continuations, and fenced code never count toward a wrapped run. |
| `no_id_prefix_in_title` | `[title, id]` | True unless `title` starts with `id` — flags a title that redundantly repeats its own identity prefix (e.g. `sb-908 — Something` when `task_id: sb-908`). |
| `hard_wrap` | `[text, max_chars]` | True only if every paragraph in `text` is filled toward `max_chars` the way a greedy nearest-fit word-wrap would produce it — the positive check, for a schema that wants to *require* wrapping rather than forbid it. |
| `no_stray_frontmatter` | `[text]` | True unless `text` contains a line shaped like a stray frontmatter key (`key: value` at column zero) outside the note's real frontmatter block — catches a copy-pasted block that looks like it belongs in the header. |

Every operator, built-in or custom, returns only a boolean — none of them can allocate or do I/O,
and a custom operator can't produce its own diagnostic text (see [Diagnostic
messages](#diagnostic-messages) for where that text actually comes from).

## The data tree

Every rule evaluates against one tree, built fresh per note:

```
{
  frontmatter: { <field>: string | [string, ...] },
  body: {
    prose: "<body text after frontmatter>",
    section_names: ["<heading title>", ...]
  },
  path: "<repo-relative path>",
  filename: { stem: "<path's filename, extension and directory stripped>" },
  is_create: bool,
  id_is_unique: bool | null,      // null on an ordinary update -- never computed
  created_epoch: number | null,   // parsed from frontmatter.created; null if missing/malformed
  updated_epoch: number | null,   // parsed from frontmatter.updated; null if missing/malformed
  vocabularies: { "<conf-file stem>": [item, ...] }
}
```

- **`frontmatter`** projects every declared frontmatter field. A list-valued field resolves to a
  JSON array regardless of which YAML list style the note itself uses — flow (`tags: [a, b]`) and
  block (`tags:` / `  - a` / `  - b`) both produce the same value here.
- **`body.section_names`** is a flat list of heading titles, presence-only — no position, no
  content. It's what lets a rule span frontmatter *and* body structure in one expression, e.g. "a
  task note whose `status` is `REVIEW` must have a `Notes` section":
  `{"or": [{"ne": [{"var": "frontmatter.status"}, "REVIEW"]}, {"in": ["Notes", {"var": "body.section_names"}]}]}`.
- **`id_is_unique`** is precomputed by the write path itself, not by any operator's own logic: on
  creation (or a schema migration), the write path scans the vault for another note whose
  `note_id`/`task_id` collides with the candidate's, but only when the schema's own `checks:`
  actually reference `id_is_unique` in the first place — a schema with no identity check triggers
  no scan at all. On an ordinary update it's `null`, not `false`, so `on_create: {var: id_is_unique}`
  reads correctly either way.
- **`created_epoch`**/**`updated_epoch`** turn `frontmatter.created`/`frontmatter.updated` into
  real Unix instants, so a comparison like `lte: [{var: created_epoch}, {var: updated_epoch}]`
  compares actual elapsed time rather than doing a lexical string compare — the naive approach gets
  a DST transition backwards, since `"+01:00"` sorts before `"+02:00"` even when it names the later
  instant.

## Vocabularies: resolved by reference, not declared

`vocabularies` is keyed by a conf file's name with its extension stripped (`synapse-tag-vocabulary`,
not `synapse-tag-vocabulary.conf`) — the key can't contain a literal `.`, since `var`'s dotted-path
resolution has no way to escape one. A schema never declares which vocabulary files it needs in a
separate field: the write path scans a schema's own `checks:`/`lints:` once at load time for every
`{"var": "vocabularies.<stem>"}` reference and loads exactly those files, wherever they resolve
through the standard tiered config cascade (see
[synapse-config.md](synapse-config.md#where-a-conf-file-actually-lives)). Drop a new
`<stem>.conf` file where the cascade looks, reference it from a rule, and it just resolves — no
second place to register it.

A conf file's own shape decides what its vocabulary items are: a `key=value` line (`synapse-projects.conf`'s
shape) contributes the value side; a plain line (`synapse-tag-vocabulary.conf`'s shape) contributes
itself whole.

### Iterating a list (`all`)

"Every tag must be in the allow-list" needs one quantifier plus two built-ins already documented
above, not a dedicated vocabulary operator:

```yaml
- all:
    - var: frontmatter.tags
    - in:
        - var: ''
        - var: vocabularies.synapse-tag-vocabulary
```

`all`'s condition sees `{"var": ""}` as the tag currently being tested, while `{"var":
"vocabularies.synapse-tag-vocabulary"}` still resolves against the full data tree — both stay
reachable in the same expression because `all` threads the current element alongside the data
tree rather than replacing it.

## Diagnostic messages

An operator's own return value is a bare boolean, so the text a failing entry reports comes from
an optional `message:` sibling key instead:

```yaml
- eq:
    - var: filename.stem
    - var: frontmatter.title
  message: 'filename.stem: must equal frontmatter.title'
```

Omitting `message:` is valid — a failing entry with none falls back to a diagnostic built from the
rule's own JSON shape (e.g. `rule failed: {"in":[{"var":"frontmatter.project"},{"var":"vocabularies.synapse-projects"}]}`),
which is legible for debugging but names no note-specific values. Every check in the shipped
schemas carries an explicit `message:` for exactly that reason.

## Severity (`lints:` only)

A `lints:` entry additionally carries `severity`, deciding what happens when it fails — see [the
`lints:` section of Note Schemas](synapse-note-schema.md#lints) for the `ignore`/`warn`/`error`
table. `checks:` has no severity: every entry there blocks the write outright.

## Composing a named operator

Because a custom operator sits in the same dispatch table as every built-in, it composes with
`and`/`or`/`xor` instead of having to be an entire entry on its own:

```yaml
lints:
  - no_hard_wrap:                  # a named rule alone
      var: body.prose
    severity: warn

checks:
  - and:                           # a named rule composed with a primitive
      - no_hard_wrap:
          var: body.prose
      - eq:
          - var: frontmatter.status
          - Ready
    message: 'body: must be wrap-clean once status reaches Ready'
```

Both forms dispatch through the same evaluator — a schema author reaches for the bare form when
the whole entry is one rule, and drops it inside a composition the moment it needs to combine with
something else.

## Worked examples from the shipped schemas

`on_create` guarding a one-time check:

```yaml
- on_create:
    eq:
      - var: created_epoch
      - var: updated_epoch
  message: 'frontmatter.created: must equal frontmatter.updated on creation'
```

`on_create` wrapping the precomputed identity scan:

```yaml
- on_create:
    var: id_is_unique
  message: 'frontmatter.note_id: identity already exists'
```

A membership check against a vocabulary file, for a single-string field (not wrapped in `all`,
since `frontmatter.project` is one scalar, not a list):

```yaml
- in:
    - var: frontmatter.project
    - var: vocabularies.synapse-projects
  message: 'frontmatter.project: not in synapse-projects.conf'
```

A positional-argument custom operator as a lint:

```yaml
lints:
  - no_id_prefix_in_title:
      - var: frontmatter.title
      - var: frontmatter.task_id
    severity: warn
```
