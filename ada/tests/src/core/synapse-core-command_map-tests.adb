with Ada.Strings.Fixed;

with AUnit.Assertions;

package body Synapse.Core.Command_Map.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   function Occurrences (Text, Part : String) return Natural is
      Found : Natural  := 0;
      From  : Positive := Text'First;
      At_I  : Natural;
   begin
      while From <= Text'Last loop
         At_I := Ada.Strings.Fixed.Index (Text (From .. Text'Last), Part);
         exit when At_I = 0;
         Found := Found + 1;
         From  := At_I + Part'Length;
      end loop;
      return Found;
   end Occurrences;

   procedure The_Map_Opens_With_A_Heading_And_Has_A_Line_Per_Entry
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Text : constant String := Render;
   begin
      Assert
        (Text (Text'First .. Text'First + 28) =
         "Synapse commands by question:",
         "the heading");
      Assert (Occurrences (Text, "" & LF) = 1 + Count, "one line per entry");
      Assert (Occurrences (Text, "- ") = Count, "each a bullet");
   end The_Map_Opens_With_A_Heading_And_Has_A_Line_Per_Entry;

   procedure Every_Command_Is_Rendered_Exactly_Once
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Text : constant String := Render;
   begin
      --  Backtick delimited, as rendered: `synapse callers <name>` is
      --  otherwise a substring of `synapse callers <name> --all`.
      for I in Entry_Index loop
         Assert
           (Occurrences (Text, "`" & Command_Of (I) & "`") = 1,
            Command_Of (I));
      end loop;
   end Every_Command_Is_Rendered_Exactly_Once;

   procedure Render_For_Keeps_Only_The_Entries_For_That_Subcommand
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Text : constant String := Render_For ("callers");
   begin
      Assert
        (Ada.Strings.Fixed.Index (Text, "synapse callers <name> --all") > 0,
         "a callers entry");
      Assert
        (Ada.Strings.Fixed.Index (Text, "synapse query") = 0,
         "and no query entry");
      Assert (Occurrences (Text, "" & LF) = 2, "the two of them");
   end Render_For_Keeps_Only_The_Entries_For_That_Subcommand;

   procedure Render_For_Writes_Nothing_For_A_Subcommand_The_Map_Does_Not_Cover
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Render_For ("vault-list") = "", "no entry");
   end Render_For_Writes_Nothing_For_A_Subcommand_The_Map_Does_Not_Cover;

   procedure Every_Entry_Names_A_Subcommand_Its_Command_Runs
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      for I in Entry_Index loop
         Assert
           (Sub_Of (I) /= "" and then Question_Of (I) /= "",
            "an entry is complete");
         Assert
           (Ada.Strings.Fixed.Index (Command_Of (I), "synapse " & Sub_Of (I)) =
            1
            or else Sub_Of (I) = "query",
            "the command starts with its subcommand: " & Command_Of (I));
      end loop;
   end Every_Entry_Names_A_Subcommand_Its_Command_Runs;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Core.Command_Map");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, The_Map_Opens_With_A_Heading_And_Has_A_Line_Per_Entry'Access,
         "The map opens with a heading and has a line per entry");
      Register_Routine
        (T, Every_Command_Is_Rendered_Exactly_Once'Access,
         "Every command is rendered exactly once");
      Register_Routine
        (T, Render_For_Keeps_Only_The_Entries_For_That_Subcommand'Access,
         "Render_For keeps only the entries for that subcommand");
      Register_Routine
        (T,
         Render_For_Writes_Nothing_For_A_Subcommand_The_Map_Does_Not_Cover'
           Access,
         "Render_For writes nothing for a subcommand the map does not cover");
      Register_Routine
        (T, Every_Entry_Names_A_Subcommand_Its_Command_Runs'Access,
         "Every entry names a subcommand its command runs");
   end Register_Tests;

end Synapse.Core.Command_Map.Tests;
