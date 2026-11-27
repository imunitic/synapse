with Synapse.Core.JSON;
with Synapse.Pipeline.Configs;
with Synapse.Pipeline.Resolved;

--  A pipeline described as one JSON document, for a client that wants to
--  draw it or understand a run of it: the steps with the settings each will
--  run with, the edges between them and the limits that apply. The socket of
--  a running pipeline and `synapse-pipeline show` both answer with it, and
--  this is the only place it is built, so they cannot differ.
--
--    format   Format
--    name     the pipeline's name
--    input    the pipeline's `Input` declaration, or null when it declares
--             none: fields (in the order declared: name, type, required,
--             description, and min_length, const, pattern, enum and items
--             when written), checks (as written, [] when none) and
--             single_text_field (the field a plain string fills, or null)
--    steps    in the order declared: name, harness, model, permissions (the
--             level in effect), timeout_seconds (the limit in
--             effect), retries, role, assignment, origins
--    edges    in the order declared: index, from, to, guard, max_iterations
--    limits   default_timeout_seconds, step_ceiling, runner
--
--  `role` and `assignment` are {"kind": "prompt", "text": ...} or null; the
--  text of a named Prompt definition is given as its text, and the prompt is
--  one of the step's `origins`, whose `kind` is "system", "agent" or
--  "prompt". An edge's `index` counts from 0
--  and is its position in `state.fired`; `guard` is null for an edge without
--  one and `max_iterations` null for an edge that is not bounded. The
--  configuration's environment is not part of the document. A field's
--  `items` is a type name, or {"fields": [...]} with fields in the same
--  shape.
--
--  The members are fixed names: a change to them is a new Format.

package Synapse.Pipeline.Descriptions is

   Format : constant String := "synapse-pipeline-description/v1";

   function Describe
     (Pipeline : Resolved.Pipeline; Settings : Configs.Config)
      return Synapse.Core.JSON.Value;

end Synapse.Pipeline.Descriptions;
