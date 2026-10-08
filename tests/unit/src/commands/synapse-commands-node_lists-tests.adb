with Ada.Directories;
with Ada.Strings.Unbounded;
with Synapse.Adapters.File_Bytes;
with Synapse.Test_Scratch;
with AUnit.Assertions;

package body Synapse.Commands.Node_Lists.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Ada.Strings.Unbounded;
   use Synapse.Test_Scratch;

   LF : constant Character := Character'Val (10);

   procedure Put (Dir : Scratch; Name, Text : String) is
   begin
      Synapse.Adapters.File_Bytes.Write (Path (Dir, Name), Text);
   end Put;

   procedure Slug_Pads_To_Three_Digits (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Slug (1) = "001", "one");
      Assert (Slug (42) = "042", "two digits");
      Assert (Slug (200) = "200", "three");
      Assert (Slug (1_000) = "1000", "never cut");
   end Slug_Pads_To_Three_Digits;

   procedure A_Node_Needs_A_Title_And_A_List (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Put (Dir, "001.title", "Core" & LF);
      Put (Dir, "001.txt", "a.ext" & LF);
      Put (Dir, "002.txt", "orphan.ext" & LF);
      Put (Dir, "003.title", "No list" & LF);
      declare
         Nodes : constant Node_Vectors.Vector := Read (Path (Dir));
      begin
         Assert (Natural (Nodes.Length) = 1, "only the first is a node");
         Assert
           (Nodes (1).Number = 1 and then To_String (Nodes (1).Title) = "Core",
            "its title");
         Assert
           (To_String (Nodes (1).Txt_Path) = Path (Dir, "001.txt"),
            "its list");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Node_Needs_A_Title_And_A_List;

   procedure The_Title_Is_The_First_Line_Without_Its_Blanks
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Put
        (Dir, "001.title",
         "  Core engine " & ASCII.CR & LF & "second line" & LF);
      Put (Dir, "001.txt", "a" & LF);
      Put (Dir, "002.title", "   " & LF);
      Put (Dir, "002.txt", "b" & LF);
      declare
         Nodes : constant Node_Vectors.Vector := Read (Path (Dir));
      begin
         Assert (Natural (Nodes.Length) = 1, "a title of blanks is none");
         Assert
           (To_String (Nodes (1).Title) = "Core engine",
            "trimmed: " & To_String (Nodes (1).Title));
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Title_Is_The_First_Line_Without_Its_Blanks;

   procedure Paths_And_Files_Count_Lines_Differently
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Put (Dir, "001.title", "Core" & LF);
      Put
        (Dir, "001.txt", "a.ext" & ASCII.CR & LF & LF & "   " & LF & "b.ext");
      declare
         Nodes : constant Node_Vectors.Vector := Read (Path (Dir));
      begin
         Assert
           (Natural (Nodes (1).Paths.Length) = 3,
            "every non empty line, a blank one too");
         Assert
           (To_String (Nodes (1).Paths (1)) = "a.ext",
            "without the carriage return");
         Assert
           (To_String (Nodes (1).Paths (2)) = "   ",
            "a line of blanks is kept");
         Assert
           (Nodes (1).Files = 2, "files are lines with something in them");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Paths_And_Files_Count_Lines_Differently;

   procedure Nodes_Come_In_Order_And_None_Past_The_Limit
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Put (Dir, "010.title", "Ten" & LF);
      Put (Dir, "010.txt", "x" & LF);
      Put (Dir, "002.title", "Two" & LF);
      Put (Dir, "002.txt", "y" & LF);
      Put (Dir, "201.title", "Past" & LF);
      Put (Dir, "201.txt", "z" & LF);
      declare
         Nodes : constant Node_Vectors.Vector := Read (Path (Dir));
      begin
         Assert (Natural (Nodes.Length) = 2, "two nodes");
         Assert
           (Nodes (1).Number = 2 and then Nodes (2).Number = 10, "ascending");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Nodes_Come_In_Order_And_None_Past_The_Limit;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Node_Lists");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Slug_Pads_To_Three_Digits'Access, "Slug pads to three digits");
      Register_Routine
        (T, A_Node_Needs_A_Title_And_A_List'Access,
         "A node needs a title and a list");
      Register_Routine
        (T, The_Title_Is_The_First_Line_Without_Its_Blanks'Access,
         "The title is the first line without its blanks");
      Register_Routine
        (T, Paths_And_Files_Count_Lines_Differently'Access,
         "Paths and files count lines differently");
      Register_Routine
        (T, Nodes_Come_In_Order_And_None_Past_The_Limit'Access,
         "Nodes come in order and none past the limit");
   end Register_Tests;

end Synapse.Commands.Node_Lists.Tests;
