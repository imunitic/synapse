--  JSON values, a strict RFC 8259 parser and a compact writer.
--
--  A Value is immutable and cheap to copy: copies share one reference-counted
--  tree. Object members are kept in source order, which only shows when a
--  value is printed; lookup and equality ignore it. Not thread-safe: share
--  a Value between tasks only after the last copy has been made.

with Ada.Containers.Vectors;
with Ada.Finalization;
with Ada.Strings.Unbounded;

with Synapse.Core.UTF8;

package Synapse.Core.JSON with SPARK_Mode => Off is

   type Kind is
     (JSON_Null,
      JSON_Boolean,
      JSON_Integer,
      JSON_Float,
      JSON_Number_String,
      JSON_String,
      JSON_Array,
      JSON_Object);

   --  The default value is JSON_Null.
   type Value is private;

   Null_Value : constant Value;

   type Value_Array is array (Positive range <>) of Value;

   type Member is record
      Key  : Ada.Strings.Unbounded.Unbounded_String;
      Item : Value;
   end record;

   type Member_Array is array (Positive range <>) of Member;

   --  Nesting limit of arrays and objects, enforced by Parse.
   Max_Depth : constant := 512;

   ---------------------------------------------------------------------------
   --  Construction
   ---------------------------------------------------------------------------

   function Make_Boolean (B : Boolean) return Value;

   function Make_Integer (I : Long_Long_Integer) return Value;

   function Make_Float (F : Long_Float) return Value
   with Pre => F'Valid;

   --  An integer too large for Long_Long_Integer, or a float outside
   --  Long_Float's range, kept as the digits it was written with.
   function Make_Number_String (Text : String) return Value
   with Pre => Text'Length > 0;

   function Make_String (S : String) return Value
   with Pre => S'Last < Positive'Last and then UTF8.Is_Valid (S);

   function Make_Array (Items : Value_Array) return Value;

   --  A repeated key replaces the earlier member's value, in place.
   function Make_Object (Members : Member_Array) return Value;

   ---------------------------------------------------------------------------
   --  Inspection
   ---------------------------------------------------------------------------

   function Kind_Of (V : Value) return Kind;

   function As_Boolean (V : Value) return Boolean
   with Pre => Kind_Of (V) = JSON_Boolean;

   function As_Integer (V : Value) return Long_Long_Integer
   with Pre => Kind_Of (V) = JSON_Integer;

   function As_Float (V : Value) return Long_Float
   with Pre => Kind_Of (V) = JSON_Float;

   --  The text of a JSON_String, or the digits of a JSON_Number_String.
   function As_String (V : Value) return String
   with Pre => Kind_Of (V) in JSON_String | JSON_Number_String;

   --  Elements of an array, members of an object.
   function Length (V : Value) return Natural
   with Pre => Kind_Of (V) in JSON_Array | JSON_Object;

   function Element (V : Value; Index : Positive) return Value
   with Pre => Kind_Of (V) = JSON_Array and then Index <= Length (V);

   function Has_Member (V : Value; Key : String) return Boolean
   with Pre => Kind_Of (V) = JSON_Object;

   function Member_Value (V : Value; Key : String) return Value
   with Pre => Kind_Of (V) = JSON_Object and then Has_Member (V, Key);

   --  The Index-th member in source order.
   function Member_Key (V : Value; Index : Positive) return String
   with Pre => Kind_Of (V) = JSON_Object and then Index <= Length (V);

   function Member_At (V : Value; Index : Positive) return Value
   with Pre => Kind_Of (V) = JSON_Object and then Index <= Length (V);

   --  Structural equality. Object member order is ignored, and values of
   --  different kinds are never equal (an integer is not equal to a float).
   overriding
   function "=" (L, R : Value) return Boolean;

   ---------------------------------------------------------------------------
   --  Parsing and writing
   ---------------------------------------------------------------------------

   type Parse_Error_Kind is
     (Unexpected_Character,
      Unexpected_End,
      Invalid_Escape,
      Invalid_UTF8,
      Invalid_Number,
      Trailing_Data,
      Too_Deep);

   type Parse_Result (Ok : Boolean := False) is record
      case Ok is
         when True =>
            Item : Value;

         when False =>
            Error  : Parse_Error_Kind;
            Offset : Natural;  --  byte offset into Text, from 0
      end case;
   end record;

   --  Exactly one JSON value with optional whitespace around it. Strings are
   --  unescaped to UTF-8; input that is not valid UTF-8 is rejected. A number
   --  without fraction or exponent that fits Long_Long_Integer is an
   --  integer; one that does not fit keeps its digits; anything else is a
   --  float, and a float outside Long_Float's range keeps its digits too.
   function Parse (Text : String) return Parse_Result
   with Pre => Text'Last < Positive'Last;

   --  Compact JSON text: no whitespace; `"` and `\` escaped, \b \f \n \r \t
   --  in short form, other control characters as \u00XX, all else as is. A
   --  float is written with the fewest digits that read back identically and
   --  always has a fraction or an exponent.
   function To_String (V : Value) return String;

private

   type Node;
   type Node_Access is access Node;

   type Value is new Ada.Finalization.Controlled with record
      Ref : Node_Access := null;
   end record;

   overriding
   procedure Adjust (V : in out Value);

   overriding
   procedure Finalize (V : in out Value);

   Null_Value : constant Value :=
     (Ada.Finalization.Controlled with Ref => null);

   package Value_Vectors is new Ada.Containers.Vectors (Positive, Value);

   package Member_Vectors is new Ada.Containers.Vectors (Positive, Member);

   type Node (K : Kind) is record
      Count : Natural := 1;
      case K is
         when JSON_Null =>
            null;

         when JSON_Boolean =>
            Flag : Boolean;

         when JSON_Integer =>
            Int : Long_Long_Integer;

         when JSON_Float =>
            Flt : Long_Float;

         when JSON_Number_String | JSON_String =>
            Text : Ada.Strings.Unbounded.Unbounded_String;

         when JSON_Array =>
            Items : Value_Vectors.Vector;

         when JSON_Object =>
            Members : Member_Vectors.Vector;
      end case;
   end record;

end Synapse.Core.JSON;
