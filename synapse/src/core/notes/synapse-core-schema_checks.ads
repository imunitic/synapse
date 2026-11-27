--  Rule checks a schema validator shares: the small JSON accessors, the
--  checks on one optional key (a boolean, an integer bound, a string list,
--  the allowed keys of a mapping, a pattern), and the check on one `checks:`
--  or `lints:` entry. Each reports its problem under the prefix it is given,
--  so the messages read the same wherever they are used.

with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Core.JSON_Logic;
with Synapse.Core.Note_Schema;
with Synapse.Core.Unit;

package Synapse.Core.Schema_Checks is

   package JSON renames Synapse.Core.JSON;

   use type JSON.Kind;

   subtype Check_Result is Note_Schema.Check_Result;

   Fine : constant Check_Result;

   function Bad (Message : String) return Check_Result;

   function Has (V : JSON.Value; Key : String) return Boolean is
     (JSON.Kind_Of (V) = JSON.JSON_Object and then JSON.Has_Member (V, Key));

   function Child (V : JSON.Value; Key : String) return JSON.Value is
     (JSON.Member_Value (V, Key)) with
     Pre => Has (V, Key);

   --  A string under Key.
   function String_At (V : JSON.Value; Key : String) return Boolean is
     (Has (V, Key) and then JSON.Kind_Of (Child (V, Key)) = JSON.JSON_String);

   function Text_At (V : JSON.Value; Key : String) return String is
     (JSON.As_String (Child (V, Key))) with
     Pre => String_At (V, Key);

   function Is_String_List (V : JSON.Value) return Boolean;

   --  The first key of V that Allowed (space-separated names) does not list;
   --  a value that is not a mapping has the key `<non-mapping>`.
   function Unknown_Key
     (V   : JSON.Value; Allowed : String;
      Key : out Ada.Strings.Unbounded.Unbounded_String) return Boolean;

   --  The fault of a pattern, or "" when it is valid.
   function Pattern_Fault (Pattern : String) return String;

   --  Checks an optional boolean under Key, with the message prefix.
   function Boolean_Rule
     (V : JSON.Value; Key, Prefix : String) return Check_Result;

   --  An optional integer bound under Key: an integer, at least Lowest.
   function Integer_Rule
     (V       : JSON.Value; Key, Prefix : String; Lowest : Long_Long_Integer;
      Too_Low : String) return Check_Result;

   --  One `checks:` or `lints:` entry: one rule, an optional string message,
   --  no stray null, no unknown operator, and a severity With_Severity.
   --  Problems are reported under "schema.<Section>[<Index>]".
   function Entry_Rule
     (Item : JSON.Value; Section : String; Index : Natural;
      Ops  : JSON_Logic.Operator_Set'Class; With_Severity : Boolean)
      return Check_Result;

private

   Fine : constant Check_Result :=
     Note_Schema.Check_Results.Success (Synapse.Core.Unit.Nothing);

end Synapse.Core.Schema_Checks;
