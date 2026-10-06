with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.Graph_Model;

package body Synapse.Core.Symbol.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Graph_Model.Role;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Sample return String is
      Tags : Tag_Payload.Tag_Vectors.Vector;
   begin
      Tags.Append
        (Graph_Model.Tag'
           (Name => To_Unbounded_String ("Token"),
            Kind => To_Unbounded_String ("class"), Which => Graph_Model.Def,
            Line => 15, Expression => To_Unbounded_String ("class Token {")));
      Tags.Append
        (Graph_Model.Tag'
           (Name       => To_Unbounded_String ("Tokenizer"),
            Kind => To_Unbounded_String ("class"), Which => Graph_Model.Def,
            Line       => 20,
            Expression => To_Unbounded_String ("class Tokenizer {")));
      Tags.Append
        (Graph_Model.Tag'
           (Name => To_Unbounded_String ("Token"),
            Kind => To_Unbounded_String ("method"), Which => Graph_Model.Ref,
            Line => 31, Expression => To_Unbounded_String ("new Token();")));
      return Tag_Payload.Encode (Tags);
   end Sample;

   procedure A_Match_Yields_The_Tag_Itself_Every_Field_Intact
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Found : constant Tag_Payload.Tag_Vectors.Vector :=
        Matches (Sample, "Token");
   begin
      Assert (Natural (Found.Length) = 2, "a definition and a reference");
      Assert
        (Found (1).Which = Graph_Model.Def and then Found (1).Line = 15
         and then To_String (Found (1).Expression) = "class Token {",
         "the first, intact");
      Assert
        (Found (2).Which = Graph_Model.Ref and then Found (2).Line = 31,
         "the second, in cache order");
   end A_Match_Yields_The_Tag_Itself_Every_Field_Intact;

   procedure The_Name_Matches_Exactly (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      for Item of Matches (Sample, "Token") loop
         Assert (To_String (Item.Name) /= "Tokenizer", "not a longer name");
      end loop;
      Assert
        (Matches (Sample, "Tokeniz").Is_Empty,
         "a prefix of a real name matches nothing");
      Assert (Matches (Sample, "token").Is_Empty, "case matters");
      Assert (Matches ("", "Token").Is_Empty, "an empty payload");
   end The_Name_Matches_Exactly;

   procedure The_Three_Answers_Stay_Distinct (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Outcome_For (False, False, "").Kind = Not_Cached, "not cached");
      Assert (Outcome_For (True, True, "").Kind = Unsupported, "unsupported");
      Assert
        (Outcome_For (False, True, "x").Kind = Not_Cached,
         "not cached wins over the other fields");
      declare
         Checked_Empty : constant Outcome := Outcome_For (True, False, "");
      begin
         Assert
           (Checked_Empty.Kind = Checked
            and then Ada.Strings.Unbounded.Length (Checked_Empty.Tags) = 0,
            "checked with no tags is not unchecked");
      end;
   end The_Three_Answers_Stay_Distinct;

   function Joined (V : Text_Lists.Vector) return String is
      Result : Ada.Strings.Unbounded.Unbounded_String;
   begin
      for Item of V loop
         Ada.Strings.Unbounded.Append (Result, Item);
         Ada.Strings.Unbounded.Append (Result, ";");
      end loop;
      return Ada.Strings.Unbounded.To_String (Result);
   end Joined;

   procedure Requested_Order_Is_The_Nodes_And_Blank_Lines_Are_Not_Paths
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      LF : constant Character := Character'Val (10);
      CR : constant Character := Character'Val (13);
   begin
      Assert
        (Joined
           (Requested_Paths
              ("b.wdg" & LF & LF & "a.wdg" & LF & "c.wdg" & LF)) =
         "b.wdg;a.wdg;c.wdg;",
         "the node's order, blanks skipped");
      Assert
        (Joined (Requested_Paths ("only.wdg")) = "only.wdg;",
         "no trailing line feed");
      Assert
        (Joined
           (Requested_Paths
              ("a.wdg" & CR & LF & CR & LF & "b.wdg" & CR & LF)) =
         "a.wdg;b.wdg;",
         "a carriage return ends no path");
      Assert (Joined (Requested_Paths ("")) = "", "empty");
      Assert
        (Joined (Requested_Paths (" " & LF)) = " ;",
         "a line of blanks is a path of blanks, as listed");
   end Requested_Order_Is_The_Nodes_And_Blank_Lines_Are_Not_Paths;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Symbol");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Match_Yields_The_Tag_Itself_Every_Field_Intact'Access,
         "A match yields the tag itself, every field intact");
      Register_Routine
        (T, The_Name_Matches_Exactly'Access, "The name matches exactly");
      Register_Routine
        (T, The_Three_Answers_Stay_Distinct'Access,
         "The three answers stay distinct");
      Register_Routine
        (T, Requested_Order_Is_The_Nodes_And_Blank_Lines_Are_Not_Paths'Access,
         "Requested order is the node's and blank lines are not paths");
   end Register_Tests;

end Synapse.Core.Symbol.Tests;
