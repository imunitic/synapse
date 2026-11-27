with Synapse.Core.JSON;
with Synapse.Core.Text_Lists;

--  Object schemas: a declaration of named fields, in the note schema's field
--  vocabulary, and a JSON object checked against it. A pipeline's `Input`
--  is one.
--
--  A declaration is `{"fields": {...}, "checks": [...]}`. `fields` is a
--  non-empty mapping from a name (`^[a-z][a-z0-9_]*$`) to a rule with the
--  keys `type required min_length const pattern enum items description`;
--  `description` is required. `type` is `string`, `integer`, `boolean`,
--  `timestamp` or `list`, and a `list` names its `items`: a type name, or
--  `{"fields": {...}}` with the same rules. `checks` is the note schema's
--  `checks:` list, with the built-in operators only, evaluated over the
--  object itself. Both functions report every problem, not only the first,
--  each as "<path>: <problem>" with paths under `input`.

package Synapse.Core.Object_Schema is

   package JSON renames Synapse.Core.JSON;

   --  Every problem with Declared as an input declaration; empty when valid.
   function Validate_Declaration
     (Declared : JSON.Value) return Synapse.Core.Text_Lists.Vector;

   --  Every problem with Given under Declared (valid per
   --  Validate_Declaration); empty when Given is accepted. An optional field
   --  given as "" or [] counts as not given. List items are numbered from 1,
   --  as in `input.files[1].path`. The `checks` run only when no field has a
   --  problem; a failing check gives its `message`, or "rule failed: " and
   --  the rule.
   function Validate_Object
     (Declared, Given : JSON.Value) return Synapse.Core.Text_Lists.Vector;

end Synapse.Core.Object_Schema;
