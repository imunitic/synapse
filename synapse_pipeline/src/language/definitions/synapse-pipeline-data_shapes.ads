with Synapse.Core.JSON;
with Synapse.Core.Text_Lists;

--  Data a step names instead of writing it inline. A pipeline may declare
--  the shapes of its steps' data once, in its `Data`: `{"fields": {...}}` in
--  the field shape of an object schema (see Synapse.Core.Object_Schema),
--  with no `checks` and no values. A step's `Data`, or its system's, and an
--  outcome's `data` may then be a list of the names the pipeline declares,
--  `["task_note", "remaining"]`, the named form, instead of the inline form.
--
--  Shapes is always the pipeline's `Data` as written, or null when it
--  declares none. Resolution replaces each name by its declaration, so a
--  resolved step holds inline fields only.

package Synapse.Pipeline.Data_Shapes is

   package JSON renames Synapse.Core.JSON;

   --  Whether Value is the named form: a JSON array.
   function Is_Named (Value : JSON.Value) return Boolean;

   --  The strings of the named form Value, in order; empty for anything
   --  else, and without the items that are not strings.
   function Names_Of (Value : JSON.Value)
      return Synapse.Core.Text_Lists.Vector;

   --  Every problem with the named form Value, with Root in front of each:
   --  the list is empty, an item (counted from 1) is not a non-empty string,
   --  or a name is given twice. Empty when Value is not a list.
   function Name_List_Problems (Value : JSON.Value; Root : String)
      return Synapse.Core.Text_Lists.Vector;

   --  Whether Shapes declares the field Name.
   function Declares (Shapes : JSON.Value; Name : String) return Boolean;

   --  The field mapping of the names in Names, each with its declaration in
   --  Shapes, in the list's order. A name Shapes does not declare is skipped.
   function Named_Fields (Shapes, Names : JSON.Value) return JSON.Value;

   --  A step's `Data` with its names replaced: `{"fields": Named_Fields}`
   --  for the named form, Data unchanged for anything else.
   function Resolve_Data (Shapes, Data : JSON.Value) return JSON.Value;

   --  Outcomes with the named `data` of every object outcome replaced by its
   --  Named_Fields. String outcomes, inline `data` and a value that is not
   --  an object are left unchanged.
   function Resolve_Outcomes (Shapes, Outcomes : JSON.Value)
      return JSON.Value;

   --  The names of the named form Value that Shapes does not declare, in
   --  order; every name when Shapes is null.
   function Undeclared (Shapes, Value : JSON.Value)
      return Synapse.Core.Text_Lists.Vector;

end Synapse.Pipeline.Data_Shapes;
