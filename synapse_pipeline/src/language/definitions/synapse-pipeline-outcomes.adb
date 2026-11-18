with Ada.Strings.Unbounded;

with Synapse.Pipeline.Syntax;

package body Synapse.Pipeline.Outcomes is

   use Ada.Strings.Unbounded;
   use type JSON.Kind;

   function Is_Letter (C : Character) return Boolean is
     (C in 'A' .. 'Z' or else C in 'a' .. 'z');

   function Is_Word (Text : String) return Boolean is
   begin
      if Text'Length = 0
        or else not Is_Letter (Text (Text'First))
        or else Syntax.Is_Reserved (Text)
      then
         return False;
      end if;
      for C of Text loop
         if not (Is_Letter (C) or else C in '0' .. '9' or else C = '_') then
            return False;
         end if;
      end loop;
      return True;
   end Is_Word;

   function Is_Declared (Declared : JSON.Value) return Boolean is
     (JSON.Kind_Of (Declared) = JSON.JSON_Object);

   function Problem (Declared : JSON.Value)
      return Synapse.Core.Optional_Text.Option
   is
      function Found (Text : String) return Synapse.Core.Optional_Text.Option
      is (Synapse.Core.Optional_Text.Of_Value (To_Unbounded_String (Text)));
   begin
      if JSON.Kind_Of (Declared) /= JSON.JSON_Object then
         return Found
           ("'Outcomes' is an object from each outcome to what it means");
      elsif JSON.Length (Declared) = 0 then
         return Found ("'Outcomes' declares no outcome");
      end if;
      for I in 1 .. JSON.Length (Declared) loop
         declare
            Word    : constant String := JSON.Member_Key (Declared, I);
            Meaning : constant JSON.Value := JSON.Member_At (Declared, I);
         begin
            if not Is_Word (Word) then
               return Found
                 ("'" & Word & "' is not an outcome: a letter and then "
                  & "letters, digits and underscores, and not a keyword");
            elsif JSON.Kind_Of (Meaning) /= JSON.JSON_String
              or else JSON.As_String (Meaning)'Length = 0
              or else (for some C of JSON.As_String (Meaning) =>
                         C = Character'Val (10))
            then
               return Found
                 ("the meaning of '" & Word & "' is one line of text");
            end if;
         end;
      end loop;
      return Synapse.Core.Optional_Text.None;
   end Problem;

   function Has_Word (Declared : JSON.Value; Word : String) return Boolean is
   begin
      if JSON.Kind_Of (Declared) /= JSON.JSON_Object then
         return False;
      end if;
      for I in 1 .. JSON.Length (Declared) loop
         if JSON.Member_Key (Declared, I) = Word then
            return True;
         end if;
      end loop;
      return False;
   end Has_Word;

   function Violation (Declared : JSON.Value; Word : String)
      return Synapse.Core.Optional_Text.Option
   is
      Words : Unbounded_String;
   begin
      if not Is_Declared (Declared) or else Has_Word (Declared, Word) then
         return Synapse.Core.Optional_Text.None;
      end if;
      for I in 1 .. JSON.Length (Declared) loop
         if I > 1 then
            Append (Words, ", ");
         end if;
         Append (Words, JSON.Member_Key (Declared, I));
      end loop;
      return Synapse.Core.Optional_Text.Of_Value
        (To_Unbounded_String
           ("the outcome '" & Word & "' is not one this step declares: "
            & To_String (Words)));
   end Violation;

   function Test_For (Word : String) return JSON.Value is
      Variable : constant JSON.Value :=
        JSON.Make_Object
          ([1 => (Key  => To_Unbounded_String ("var"),
                  Item => JSON.Make_String ("outcome"))]);
   begin
      return JSON.Make_Object
        ([1 => (Key  => To_Unbounded_String ("=="),
                Item => JSON.Make_Array
                          ([1 => Variable, 2 => JSON.Make_String (Word)]))]);
   end Test_For;

   function Tested_Word (Guard : JSON.Value)
      return Synapse.Core.Optional_Text.Option
   is
   begin
      if JSON.Kind_Of (Guard) = JSON.JSON_Object
        and then JSON.Length (Guard) = 1
        and then JSON.Member_Key (Guard, 1) = "=="
        and then JSON.Kind_Of (JSON.Member_At (Guard, 1)) = JSON.JSON_Array
        and then JSON.Length (JSON.Member_At (Guard, 1)) = 2
      then
         declare
            Operands : constant JSON.Value := JSON.Member_At (Guard, 1);
            Left     : constant JSON.Value := JSON.Element (Operands, 1);
            Right    : constant JSON.Value := JSON.Element (Operands, 2);
         begin
            if JSON.Kind_Of (Left) = JSON.JSON_Object
              and then JSON.Length (Left) = 1
              and then JSON.Member_Key (Left, 1) = "var"
              and then JSON.Kind_Of (JSON.Member_At (Left, 1)) =
                       JSON.JSON_String
              and then JSON.As_String (JSON.Member_At (Left, 1)) = "outcome"
              and then JSON.Kind_Of (Right) = JSON.JSON_String
            then
               return Synapse.Core.Optional_Text.Of_Value
                 (To_Unbounded_String (JSON.As_String (Right)));
            end if;
         end;
      end if;
      return Synapse.Core.Optional_Text.None;
   end Tested_Word;

end Synapse.Pipeline.Outcomes;
