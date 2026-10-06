--  What a note schema's rules go through when the schema is loaded: the
--  conversion from the word aliases a YAML key can hold to the symbols the
--  JsonLogic evaluator knows, and scans for the vocabulary files and
--  precomputed fields a schema's rules use.
--
--  A schema's `checks:` and `lints:` entries are written with `eq`, `lte`,
--  `not` and so on, because `==` and `<=` cannot be YAML keys.

with Ada.Strings.Unbounded;

with Synapse.Core.JSON;

package Synapse.Core.Schema_Rules is

   package JSON renames Synapse.Core.JSON;

   type String_Array is
     array (Positive range <>) of Ada.Strings.Unbounded.Unbounded_String;

   --  Not Ok: the rule contains a bare `null`, which is only meaningful in a
   --  schema override document, where it deletes a key.
   type Rule_Result (Ok : Boolean := False) is record
      case Ok is
         when True =>
            Rule : JSON.Value;

         when False =>
            null;
      end case;
   end record;

   --  The tree the evaluator takes. An object with exactly one key has that
   --  key renamed when it is a word alias (eq, ne, lt, lte, gt, gte, not); an
   --  object with several keys is data and keeps its keys. Scalars and arrays
   --  pass through, with their elements converted.
   function To_Rule (Value : JSON.Value) return Rule_Result;

   --  Each distinct `<stem>` of a `{"var": "vocabularies.<stem>"}` in Rule, in
   --  the order first seen. Only a one-key object is a `var` call.
   function Vocabulary_Stems (Rule : JSON.Value) return String_Array;

   --  Whether `{"var": Path}` occurs anywhere in Rule, as an exact match.
   function References_Var (Rule : JSON.Value; Path : String) return Boolean;

   --  The shape of one `checks:` or `lints:` entry: exactly one key that
   --  defines the rule (any operator name) besides the optional `message` and
   --  `severity`.
   type Entry_Shape (Is_Rule : Boolean := False) is record
      case Is_Rule is
         when True =>
            Key             : Ada.Strings.Unbounded.Unbounded_String;
            Rule            : JSON.Value;
            Message_Present : Boolean;
            --  `message` was there but is not a string.
            Message_Invalid : Boolean;

         when False =>
            null;
      end case;
   end record;

   --  Not Is_Rule when Entry is not a mapping, or has no rule key, or more
   --  than one.
   function Shape_Of (Entry_Value : JSON.Value) return Entry_Shape;

   --  The entry's rule key and value as the one-key object To_Rule converts.
   function Rule_Object (Shape : Entry_Shape) return JSON.Value
   with Pre => Shape.Is_Rule;

   --  The vocabulary stems referenced by a schema's `checks:` and `lints:`,
   --  so a caller reads only the vocabulary files the schema uses.
   function Needed_Vocabulary_Stems (Schema : JSON.Value) return String_Array;

   --  Whether a `checks:` entry references `id_is_unique`, so a caller can
   --  skip a vault-wide identity scan for a schema that never asks.
   function Needs_Identity_Scan (Schema : JSON.Value) return Boolean;

end Synapse.Core.Schema_Rules;
