with Synapse.Core.JSON;
with Synapse.Core.JSON_Logic;

--  The operators a schema's `checks:` and `lints:` may use beyond JsonLogic's
--  built-ins:
--
--    on_create: RULE                  RULE on a create or migration, true
--                                     otherwise
--    no_hard_wrap: TEXT               no paragraph of TEXT is wrapped by hand
--    hard_wrap: [TEXT, WIDTH]         every paragraph is greedily wrapped at
--                                     WIDTH
--    no_stray_frontmatter: TEXT       TEXT holds no second frontmatter block
--
--  Arguments are rules, evaluated here. A TEXT that is not a string is
--  vacuously fine.

package Synapse.Core.Note_Operators is

   type Note_Operators is new JSON_Logic.Operator_Set with null record;

   overriding
   function Has_Operator (Set : Note_Operators; Name : String) return Boolean;

   --  Invalid_Arguments for too few arguments, and for a hard_wrap width that
   --  is not a positive integer.
   overriding
   function Apply
     (Set   : Note_Operators;
      Name  : String;
      Args  : JSON.Value_Array;
      Where : JSON_Logic.Scope) return JSON.Value;

   Operators : constant Note_Operators := (null record);

end Synapse.Core.Note_Operators;
