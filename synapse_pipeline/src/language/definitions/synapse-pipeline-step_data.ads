with Synapse.Core.JSON;
with Synapse.Core.Text_Lists;
with Synapse.Pipeline.Resolved;

--  The data a step's result hands on, and the check of a result's `data`
--  against what the step declares. A step's data is the next step's input;
--  nothing is kept for the whole run.
--
--  A step declares its data in `Data`, the fields it puts in `data` whatever
--  its outcome, and in the `data` of an outcome, the fields that hold with
--  that outcome only. Both use the field shape of an object schema (see
--  Synapse.Core.Object_Schema).

package Synapse.Pipeline.Step_Data is

   package JSON renames Synapse.Core.JSON;

   --  The declaration a result of Item that ends with Outcome is checked
   --  against: the fields of Item's `Data` and of Outcome's `data`, in that
   --  order, in one `{"fields", "checks"}`, with the checks of `Data`. Null
   --  when Item declares no `Data` and Outcome has no `data`.
   function Declaration_For
     (Item : Resolved.Step; Outcome : String) return JSON.Value;

   --  Every problem with the `data` of Output, a result of Item, under the
   --  declaration for its outcome, with paths under `data`. Empty when that
   --  declaration is null; "data: expected an object" when `data` is not an
   --  object.
   function Problems
     (Item : Resolved.Step; Output : JSON.Value)
      return Synapse.Core.Text_Lists.Vector;

end Synapse.Pipeline.Step_Data;
