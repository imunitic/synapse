--  A JsonLogic evaluator for the operators the vault search and the note
--  schemas use: var, and, or, !, ==, !=, in, <, <=, >, >=, glob, regexp,
--  all, xor, starts_with. It follows the published JsonLogic language except
--  where noted: `all` over an empty array is true, string-to-number coercion
--  accepts digit-only strings alone, and xor, starts_with, glob and regexp
--  are additions.
--
--  A rule is a single-key object naming an operator, such as
--  {"==": [a, b]}; anything else is a literal and evaluates to itself.
--  Evaluating allocates only the argument lists: every result is a value
--  that already existed in the rule or the data, or a new boolean.

with Synapse.Core.JSON;

package Synapse.Core.JSON_Logic with SPARK_Mode => Off is

   package JSON renames Synapse.Core.JSON;

   --  What a rule is evaluated against: the data tree and, inside `all`, the
   --  element being tested. `{"var": ""}` reads Item when Has_Item is set and
   --  the whole data tree otherwise.
   type Scope is record
      Data     : JSON.Value;
      Item     : JSON.Value := JSON.Null_Value;
      Has_Item : Boolean := False;
   end record;

   --  Operators beyond the built-in ones. An implementation may call
   --  Evaluate again, passing itself, to evaluate its own arguments.
   type Operator_Set is limited interface;

   function Has_Operator (Set : Operator_Set; Name : String) return Boolean
   is abstract;

   function Apply
     (Set   : Operator_Set;
      Name  : String;
      Args  : JSON.Value_Array;
      Where : Scope) return JSON.Value
   is abstract;

   type No_Operators_Set is new Operator_Set with null record;

   overriding
   function Has_Operator (Set : No_Operators_Set; Name : String) return Boolean;

   overriding
   function Apply
     (Set   : No_Operators_Set;
      Name  : String;
      Args  : JSON.Value_Array;
      Where : Scope) return JSON.Value;

   No_Operators : constant No_Operators_Set := (null record);

   --  A single-key object whose key is neither built in nor in the extra
   --  operators. The message is the key.
   Unknown_Operator : exception;

   --  An operator given too few arguments.
   Invalid_Arguments : exception;

   --  A regexp pattern that exhausted its step budget. The message is the
   --  pattern.
   Pattern_Too_Complex : exception;

   function Evaluate
     (Rule  : JSON.Value;
      Where : Scope;
      Ops   : Operator_Set'Class := No_Operators) return JSON.Value;

   --  JsonLogic truthiness: false, 0, "", null and [] are falsy; everything
   --  else, an empty object included, is truthy.
   function Truthy (V : JSON.Value) return Boolean;

   --  Equality as `==` sees it: an integer, a float, a digit-only string and a
   --  number string compare by numeric value; arrays compare element by
   --  element; objects ignore member order.
   function Loosely_Equal (A, B : JSON.Value) return Boolean;

   Built_In_Count : constant := 16;

   --  The name of each built-in operator, kept next to the dispatch so a
   --  caller checking an operator name has one list to consult.
   function Built_In_Name (Index : Positive) return String
   with Pre => Index <= Built_In_Count;

   function Is_Built_In (Name : String) return Boolean;

end Synapse.Core.JSON_Logic;
