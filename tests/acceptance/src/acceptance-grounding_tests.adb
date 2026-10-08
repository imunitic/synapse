with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Acceptance.Fixtures;

package body Acceptance.Grounding_Tests is

   use Acceptance.Fixtures;
   use Ada.Strings.Unbounded;
   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   function Line_Starts_With (Text, Prefix : String) return Boolean is
   begin
      for Item of Lines (Text) loop
         declare
            Line : constant String := To_String (Item);
         begin
            if Line'Length >= Prefix'Length
              and then Line (Line'First .. Line'First + Prefix'Length - 1) =
                Prefix
            then
               return True;
            end if;
         end;
      end loop;
      return False;
   end Line_Starts_With;

   --  A node grounded in a two-line doc comment at the top of calc.aa.
   procedure Build_Grounded_Node (F : Fixture) is
      Calc : Unbounded_String :=
        To_Unbounded_String
          ("(* Computes the premium for a contract." & LF &
           "   Rounds half-up at two decimals. *)" & LF);
   begin
      Make_Repo (F);
      for I in 3 .. 12 loop
         declare
            Number : constant String :=
              Ada.Strings.Fixed.Trim (Integer'Image (I), Ada.Strings.Left);
         begin
            Append
              (Calc,
               "let line" & (if I < 10 then "0" else "") & Number & " = " &
               Number & LF);
         end;
      end loop;
      Write_Repo_File (F, "lib/calc.aa", To_String (Calc));
      Commit_All (F, "calc");

      Write_Root_File (F, "paths.txt", "src/foo.aa" & LF & "lib/calc.aa" & LF);
      Write_Root_File
        (F, "body.md",
         "## Summary" & LF & "Rounds half-up at two decimals." & LF &
         "<!-- grounded_in: lib/calc.aa 1-2 -->" & LF);
      Assert_Exit
        (Run_Fake
           (F, "write-node", "--title", "Premium", "--summary",
            "Premium calc.", "--paths", Root (F) & "/paths.txt", "--body",
            Root (F) & "/body.md"),
         0, "write-node");

      Write_Synapse_Index (F, Repo_Name (F), Repo_Remote_Or_Path (F));
      Write_Index_Bin
        (F, Default_Work_Dir (F),
         "lib/calc.aa" & ASCII.HT & "Premium.md" & LF & "src/foo.aa" &
         ASCII.HT & "Premium.md" & LF);
   end Build_Grounded_Node;

   procedure Round_Trip_Preserves_Groundings (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Use_Schema_Content_Root (F);
      Build_Grounded_Node (F);
      declare
         Node      : constant String :=
           Vault (F) & "/synapse/" & Repo_Name (F) & "/Premium.md";
         Paths     : constant String := Root (F) & "/paths.txt";
         Body_Read : constant Result :=
           Run_Fake (F, "query", "body", "Premium", "--full");
         Recovered : constant String :=
           Prose_Before_Sources (To_String (Body_Read.Output));

         function Rewrite (Body_File : String) return Result is
           (Run_Fake
              (F, "write-node", "--title", "Premium", "--summary",
               "Premium calc.", "--paths", Paths, "--body", Body_File));
      begin
         Assert_Exit (Body_Read, 0, "query body");
         Assert_Lacks (Recovered, "grounded_in", "the recovered prose");
         Write_Root_File (F, "recovered.md", Recovered);

         --  (a) writing the recovered body back as it is drops the
         --  provenance, silently.
         Assert_Exit (Rewrite (Root (F) & "/recovered.md"), 0, "rewrite (a)");
         Assert
           (not Line_Starts_With (Read_File (Node), "grounded_in:"),
            "provenance is dropped");

         --  (b) re-emitting the directive from `--list` restores it exactly,
         --  which is what `--list` is for.
         Write_Root_File
           (F, "reemit.md",
            Recovered & "<!-- grounded_in: lib/calc.aa 1-2 -->" & LF);
         Assert_Exit (Rewrite (Root (F) & "/reemit.md"), 0, "rewrite (b)");
         declare
            After : constant String := Read_File (Node);
         begin
            Assert_Contains (After, "  - path: lib/calc.aa" & LF, "path");
            Assert_Contains (After, "    lines: ""1-2""" & LF, "lines");
         end;
         Assert_Equal
           (To_String (Run_Fake (F, "query", "grounding").Output), "",
            "the groundings still match");
      end;
   end Round_Trip_Preserves_Groundings;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Acceptance: grounding");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Round_Trip_Preserves_Groundings'Access,
         "round trip: re-emitting from --list preserves groundings");
   end Register_Tests;

end Acceptance.Grounding_Tests;
