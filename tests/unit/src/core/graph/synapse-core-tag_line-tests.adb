with Ada.Numerics.Discrete_Random;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.Graph_Model;

package body Synapse.Core.Tag_Line.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Synapse.Core.Graph_Model.Role;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   HT : constant Character := Character'Val (9);

   function Real_Def return String is
     ("Token     " & HT & " | class   " & HT &
      "def (15, 13) - (15, 18) `public class Token {`");

   procedure A_Real_Def_Line (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Got : constant Maybe_Tag := Parse (Real_Def);
   begin
      Assert (Got.Found, "found");
      Assert (To_String (Got.Value.Name) = "Token", "name");
      Assert (Got.Value.Which = Graph_Model.Def, "role");
      Assert (To_String (Got.Value.Kind) = "class", "kind");
      Assert (Got.Value.Line = 15, "line");
      Assert
        (To_String (Got.Value.Expression) = "public class Token {",
         "expression");
   end A_Real_Def_Line;

   procedure A_Real_Ref_Line_With_An_Apostrophe (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Got : constant Maybe_Tag :=
        Parse
          ("IllegalArgumentException" & HT & " | class   " & HT &
           "ref (30, 19) - (30, 43) " &
           "`throw new IllegalArgumentException(""can't parse"" + t);`");
   begin
      Assert (Got.Found and then Got.Value.Which = Graph_Model.Ref, "a ref");
      Assert (To_String (Got.Value.Name) = "IllegalArgumentException", "name");
      Assert
        (To_String (Got.Value.Expression) =
         "throw new IllegalArgumentException(""can't parse"" + t);",
         "the apostrophe survives");
   end A_Real_Ref_Line_With_An_Apostrophe;

   procedure The_Padded_Name_Is_Trimmed (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (To_String
           (Parse
              ("execute   " & HT & " | call    " & HT &
               "ref (7, 1) - (7, 8) `execute();`")
              .Value
              .Name) =
         "execute",
         "an exact lookup depends on it");
      Assert
        (To_String
           (Parse ("| a " & HT & "  | k  " & HT & "def (1, 1) - (1, 2) `x`")
              .Value
              .Name) =
         "a",
         "leading pipes go too");
      Assert
        (To_String
           (Parse ("a" & HT & "|| \| k  " & HT & "def (1, 1) - (1, 2) `x`")
              .Value
              .Kind) =
         "\| k",
         "the kind loses its prefix and padding only");
   end The_Padded_Name_Is_Trimmed;

   procedure Lines_That_Are_Not_Tags_Are_Skipped (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (not Parse ("no tabs here at all").Found, "no tabs");
      Assert (not Parse ("a" & HT & "b").Found, "two fields");
      Assert
        (not Parse
           ("name" & HT & " | kind" & HT & "definition (1, 2) - (1, 3) `x`")
           .Found,
         "a bad role");
      Assert
        (not Parse ("name" & HT & " | kind" & HT & "def no span here `x`")
           .Found,
         "no span");
      Assert
        (not Parse ("name" & HT & " | kind" & HT & "def (x, 2) - (1, 3) `x`")
           .Found,
         "a row that is not a number");
      Assert
        (not Parse ("name" & HT & " | kind" & HT & "def (+5, 2) - (1, 3) `x`")
           .Found,
         "a sign");
      Assert
        (not Parse ("name" & HT & " | kind" & HT & "def (, 2) - (1, 3) `x`")
           .Found,
         "no row");
      Assert
        (not Parse
           ("name" & HT & " | kind" & HT & "def (99999999999, 2) - (1, 3) `x`")
           .Found,
         "a row that is not a line number");
      Assert
        (not Parse ("   " & HT & " | kind" & HT & "def (1, 2) - (1, 3) `x`")
           .Found,
         "an empty name");
      Assert (not Parse ("").Found, "empty");
   end Lines_That_Are_Not_Tags_Are_Skipped;

   procedure Row_Zero_Is_A_Row (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Got : constant Maybe_Tag :=
        Parse ("f" & HT & " | call    " & HT & "ref (0, 0) - (0, 1) `x`");
   begin
      Assert
        (Got.Found and then Got.Value.Line = 0,
         "row zero, as tree-sitter numbers it");
   end Row_Zero_Is_A_Row;

   procedure Backticks_Decide_The_Expression (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (To_String
           (Parse
              ("f" & HT & " | call    " & HT &
               "ref (2, 0) - (2, 1) `unterminated")
              .Value
              .Expression) =
         "unterminated",
         "a single backtick keeps the remainder");
      Assert
        (To_String
           (Parse ("f" & HT & " | call    " & HT & "ref (2, 0) - (2, 1) ")
              .Value
              .Expression) =
         "",
         "no backtick yields an empty expression and not a skip");
      Assert
        (To_String
           (Parse
              ("f" & HT & " | call    " & HT & "ref (2, 0) - (2, 1) `a `b` c`")
              .Value
              .Expression) =
         "a `b` c",
         "the first and the last");
   end Backticks_Decide_The_Expression;

   procedure A_Tab_In_The_Source_Line_Cuts_It (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (To_String
           (Parse
              ("f" & HT & " | call    " & HT & "ref (2, 0) - (2, 1) `a" & HT &
               "b`")
              .Value
              .Expression) =
         "a",
         "only the first three fields count, so the closing backtick is lost");
   end A_Tab_In_The_Source_Line_Cuts_It;

   procedure A_Refs_Row_Is_Tab_Separated_In_Search_Order
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Refs_Row ("src/Token.ext", Parse (Real_Def).Value) =
         "Token" & HT & "def" & HT & "class" & HT & "src/Token.ext:15" & HT &
         "public class Token {" & Character'Val (10),
         "the row");
   end A_Refs_Row_Is_Tab_Separated_In_Search_Order;

   package Byte_Random is new Ada.Numerics.Discrete_Random (Character);
   package Small_Random is new Ada.Numerics.Discrete_Random (Natural);

   procedure Parse_Never_Fails_On_Arbitrary_Bytes (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Bytes          : Byte_Random.Generator;
      Sizes          : Small_Random.Generator;
      Skipped, Taken : Natural := 0;
   begin
      Byte_Random.Reset (Bytes, 7);
      Small_Random.Reset (Sizes, 11);
      for Round in 1 .. 5_000 loop
         declare
            Length : constant Natural := Small_Random.Random (Sizes) mod 81;
            Line   : String (1 .. Length);
         begin
            for C of Line loop
               C := Byte_Random.Random (Bytes);
            end loop;
            if Parse (Line).Found then
               Taken := Taken + 1;
            else
               Skipped := Skipped + 1;
            end if;
         end;
      end loop;
      Assert (Skipped + Taken = 5_000, "every line was answered");
   end Parse_Never_Fails_On_Arbitrary_Bytes;

   procedure Embedded_Backticks_Never_Break_The_Recovery
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Gen : Small_Random.Generator;

      function Pick (Low, High : Natural) return Natural is
        (Low + Small_Random.Random (Gen) mod (High - Low + 1));
   begin
      Small_Random.Reset (Gen, 5);
      for Round in 1 .. 3_000 loop
         declare
            Name_Length : constant Natural := Pick (1, 10);
            Name        : String (1 .. Name_Length);
            Expr_Length : constant Natural := Pick (0, 60);
            Expression  : String (1 .. Expr_Length);
            Is_Def      : constant Boolean := Pick (0, 1) = 1;
            Row         : constant Natural := Pick (0, 10_000_000);
            Row_Text    : constant String  := Natural'Image (Row);
            Role_Text   : constant String := (if Is_Def then "def" else "ref");
         begin
            for C of Name loop
               C :=
                 Character'Val
                   (Pick (Character'Pos ('a'), Character'Pos ('z')));
            end loop;
            --  Printable bytes, backticks included, no tab.
            for C of Expression loop
               C :=
                 Character'Val
                   (Pick (Character'Pos ('!'), Character'Pos ('~')));
            end loop;
            declare
               Line : constant String    :=
                 Name & HT & " | kind" & HT & Role_Text & " (" &
                 Row_Text (Row_Text'First + 1 .. Row_Text'Last) & ", 0) - (" &
                 Row_Text (Row_Text'First + 1 .. Row_Text'Last) & ", 1) `" &
                 Expression & "`";
               Got  : constant Maybe_Tag := Parse (Line);
            begin
               Assert (Got.Found, "found: " & Line);
               Assert (To_String (Got.Value.Name) = Name, "name");
               Assert (Got.Value.Line = Row, "row");
               Assert ((Got.Value.Which = Graph_Model.Def) = Is_Def, "role");
               Assert
                 (To_String (Got.Value.Expression) = Expression,
                  "expression: " & Line);
            end;
         end;
      end loop;
   end Embedded_Backticks_Never_Break_The_Recovery;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Tag_Line");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine (T, A_Real_Def_Line'Access, "A real def line");
      Register_Routine
        (T, A_Real_Ref_Line_With_An_Apostrophe'Access,
         "A real ref line with an apostrophe");
      Register_Routine
        (T, The_Padded_Name_Is_Trimmed'Access, "The padded name is trimmed");
      Register_Routine
        (T, Lines_That_Are_Not_Tags_Are_Skipped'Access,
         "Lines that are not tags are skipped");
      Register_Routine (T, Row_Zero_Is_A_Row'Access, "Row zero is a row");
      Register_Routine
        (T, Backticks_Decide_The_Expression'Access,
         "Backticks decide the expression");
      Register_Routine
        (T, A_Tab_In_The_Source_Line_Cuts_It'Access,
         "A tab in the source line cuts it");
      Register_Routine
        (T, A_Refs_Row_Is_Tab_Separated_In_Search_Order'Access,
         "A refs row is tab-separated in search order");
      Register_Routine
        (T, Parse_Never_Fails_On_Arbitrary_Bytes'Access,
         "Parse never fails on arbitrary bytes");
      Register_Routine
        (T, Embedded_Backticks_Never_Break_The_Recovery'Access,
         "Embedded backticks never break the recovery");
   end Register_Tests;

end Synapse.Core.Tag_Line.Tests;
