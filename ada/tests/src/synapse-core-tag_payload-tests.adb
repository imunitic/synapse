with Ada.Numerics.Discrete_Random;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Test_Bytes;

package body Synapse.Core.Tag_Payload.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Graph_Model.Role;
   use type Ada.Containers.Count_Type;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Make
     (Name, Kind : String; Which : Graph_Model.Role; Line : Natural;
      Expression : String) return Graph_Model.Tag is
     (Name => To_Unbounded_String (Name), Kind => To_Unbounded_String (Kind),
      Which      => Which, Line => Line,
      Expression => To_Unbounded_String (Expression));

   function Same (A, B : Graph_Model.Tag) return Boolean is
     (A.Name = B.Name and then A.Kind = B.Kind and then A.Which = B.Which
      and then A.Line = B.Line and then A.Expression = B.Expression);

   function One (Item : Graph_Model.Tag) return Tag_Vectors.Vector is
      Result : Tag_Vectors.Vector;
   begin
      Result.Append (Item);
      return Result;
   end One;

   procedure One_Tag_Is_Exactly_The_Bytes_The_Layout_Gives
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Expected : constant String :=
        Test_Bytes.From_Hex
          ("00" & "00000000" & "0500" & "416c706861" & "0500" & "636c617373" &
           "0d000000" & "636c617373" & "20416c7068" & "61207b");
   begin
      Assert
        (Encode_One
           (Make ("Alpha", "class", Graph_Model.Def, 0, "class Alpha {")) =
         Expected,
         "the record, field by field");
   end One_Tag_Is_Exactly_The_Bytes_The_Layout_Gives;

   procedure A_Tag_Round_Trips_With_Every_Field_Intact
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Item : constant Graph_Model.Tag    :=
        Make ("Token", "class", Graph_Model.Def, 15, "public class Token {");
      Got  : constant Tag_Vectors.Vector := Decode (Encode (One (Item)));
   begin
      Assert
        (Natural (Got.Length) = 1 and then Same (Got (1), Item), "intact");
   end A_Tag_Round_Trips_With_Every_Field_Intact;

   procedure Several_Tags_Come_Back_In_Order (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Tags : Tag_Vectors.Vector;
   begin
      Tags.Append (Make ("Ay", "class", Graph_Model.Def, 0, "class Ay {"));
      Tags.Append (Make ("call", "call", Graph_Model.Ref, 3, "call();"));
      declare
         Got : constant Tag_Vectors.Vector := Decode (Encode (Tags));
      begin
         Assert (Natural (Got.Length) = 2, "two");
         Assert
           (Same (Got (1), Tags (1)) and then Same (Got (2), Tags (2)),
            "in order");
         Assert (Got (2).Which = Graph_Model.Ref, "the role of the second");
      end;
   end Several_Tags_Come_Back_In_Order;

   procedure A_Long_Expression_Survives_Whole (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Long : constant String             := [1 .. 400 => 'x'];
      Got  : constant Tag_Vectors.Vector :=
        Decode (Encode (One (Make ("n", "call", Graph_Model.Ref, 1, Long))));
   begin
      Assert (To_String (Got (1).Expression) = Long, "no cap");
   end A_Long_Expression_Survives_Whole;

   procedure No_Tags_Are_No_Bytes (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      None : Tag_Vectors.Vector;
   begin
      Assert (Encode (None) = "", "zero bytes");
      Assert (Decode ("").Is_Empty, "and nothing back");
   end No_Tags_Are_No_Bytes;

   procedure Delimiters_In_A_Field_Do_Not_Matter (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      HT   : constant Character          := Character'Val (9);
      LF   : constant Character          := Character'Val (10);
      Item : constant Graph_Model.Tag    :=
        Make
          ("weird" & HT & "name", "kind" & LF & "with" & LF & "lines",
           Graph_Model.Def, 7,
           "has `backticks` and " & HT & " tabs" & LF & "and lines" &
           Character'Val (0));
      Got  : constant Tag_Vectors.Vector := Decode (Encode (One (Item)));
   begin
      Assert
        (Natural (Got.Length) = 1 and then Same (Got (1), Item),
         "a name, kind or expression with a tab, line feed, backtick or" &
         " NUL round-trips exactly");
   end Delimiters_In_A_Field_Do_Not_Matter;

   procedure A_Truncated_Payload_Decodes_As_Far_As_It_Can
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Tags : Tag_Vectors.Vector;
   begin
      Tags.Append (Make ("First", "class", Graph_Model.Def, 1, "e"));
      Tags.Append (Make ("Second", "call", Graph_Model.Ref, 2, "f"));
      declare
         Whole     : constant String  := Encode (Tags);
         First_End : constant Natural := Encode_One (Tags (1))'Length;
      begin
         for Cut in First_End + 1 .. Whole'Last - 1 loop
            declare
               Got : constant Tag_Vectors.Vector :=
                 Decode (Whole (Whole'First .. Cut));
            begin
               Assert
                 (Natural (Got.Length) = 1
                  and then To_String (Got (1).Name) = "First",
                  "cut at" & Cut'Image);
            end;
         end loop;
         Assert (Natural (Decode (Whole).Length) = 2, "whole is whole");
      end;
   end A_Truncated_Payload_Decodes_As_Far_As_It_Can;

   procedure A_Bad_Role_Or_An_Overlong_Length_Stops_Reading
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Good     : constant String :=
        Encode_One (Make ("a", "k", Graph_Model.Def, 1, "x"));
      Bad_Role : String          := Good;
   begin
      Bad_Role (Bad_Role'First) := Character'Val (2);
      Assert (Decode (Bad_Role).Is_Empty, "an unknown role");
      Assert
        (Natural (Decode (Good & Bad_Role).Length) = 1,
         "stops at it, keeping what came before");
      declare
         Overlong : String := Good;
      begin
         --  The name length, claiming more bytes than there are.
         Overlong (Overlong'First + 5) := Character'Val (200);
         Assert (Decode (Overlong).Is_Empty, "a length past the end");
      end;
      Assert (Decode ("x").Is_Empty, "too short for a record");
   end A_Bad_Role_Or_An_Overlong_Length_Stops_Reading;

   package Draw is new Ada.Numerics.Discrete_Random (Natural);

   procedure Random_Tags_Round_Trip_And_Garbage_Never_Fails
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Gen : Draw.Generator;

      function Pick (Limit : Positive) return Natural is
        (Draw.Random (Gen) mod Limit);

      function Bytes (Count : Natural) return String is
         Result : String (1 .. Count);
      begin
         for C of Result loop
            C := Character'Val (Pick (256));
         end loop;
         return Result;
      end Bytes;
   begin
      Draw.Reset (Gen, 21);
      for Round in 1 .. 300 loop
         declare
            Tags : Tag_Vectors.Vector;
         begin
            for I in 1 .. Pick (6) loop
               Tags.Append
                 (Make
                    (Bytes (Pick (20)), Bytes (Pick (12)),
                     (if Pick (2) = 0 then Graph_Model.Def
                      else Graph_Model.Ref),
                     Pick (1_000_000), Bytes (Pick (80))));
            end loop;
            declare
               Got : constant Tag_Vectors.Vector := Decode (Encode (Tags));
            begin
               Assert (Got.Length = Tags.Length, "the same number");
               for I in 1 .. Natural (Tags.Length) loop
                  Assert (Same (Got (I), Tags (I)), "the same tag");
               end loop;
            end;
         end;
         declare
            Garbage : constant String             := Bytes (Pick (120));
            Ignore  : constant Tag_Vectors.Vector := Decode (Garbage);
         begin
            null;
         end;
      end loop;
   end Random_Tags_Round_Trip_And_Garbage_Never_Fails;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Tag_Payload");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, One_Tag_Is_Exactly_The_Bytes_The_Layout_Gives'Access,
         "One tag is exactly the bytes the layout gives");
      Register_Routine
        (T, A_Tag_Round_Trips_With_Every_Field_Intact'Access,
         "A tag round-trips with every field intact");
      Register_Routine
        (T, Several_Tags_Come_Back_In_Order'Access,
         "Several tags come back in order");
      Register_Routine
        (T, A_Long_Expression_Survives_Whole'Access,
         "A long expression survives whole");
      Register_Routine
        (T, No_Tags_Are_No_Bytes'Access, "No tags are no bytes");
      Register_Routine
        (T, Delimiters_In_A_Field_Do_Not_Matter'Access,
         "Delimiters in a field do not matter");
      Register_Routine
        (T, A_Truncated_Payload_Decodes_As_Far_As_It_Can'Access,
         "A truncated payload decodes as far as it can");
      Register_Routine
        (T, A_Bad_Role_Or_An_Overlong_Length_Stops_Reading'Access,
         "A bad role or an overlong length stops reading");
      Register_Routine
        (T, Random_Tags_Round_Trip_And_Garbage_Never_Fails'Access,
         "Random tags round-trip and garbage never fails");
   end Register_Tests;

end Synapse.Core.Tag_Payload.Tests;
