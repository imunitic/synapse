with Ada.Directories;
with Ada.Strings.Fixed;
with Synapse.Adapters.File_Bytes;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Vault;
with Ada.Strings.Unbounded;
with AUnit.Assertions;

package body Synapse.Commands.Project_Index.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Vault;

   LF : constant Character := Character'Val (10);

   procedure Pin (F : aliased in out Fixture; Dir : Scratch) is
   begin
      Use_Vault (F, Dir);
      F.Vars.Set ("SYNAPSE_WORK_DIR", Path (Dir, "work"));
      F.Vars.Set ("SYNAPSE_NAMESPACE", "widget@main");
      F.Vars.Set ("SYNAPSE_REPO_ROOT", "/r");
      F.Vars.Set ("SYNAPSE_BRANCH", "main");
      F.Vars.Set ("SYNAPSE_REMOTE", "https://h/o/widget.git");
      F.Clock.Now :=
        Ada.Strings.Unbounded.To_Unbounded_String
          ("2026-10-07T14:32:05+02:00");
      Put
        (Dir, "synapse/widget@main/Index.md",
         "---" & LF & "branch: main" & LF & "remote: https://h/o/widget.git" &
         LF & "---" & LF & "# old" & LF);
   end Pin;

   procedure List (Dir : Scratch; Stem, Title, Paths : String) is
   begin
      Ada.Directories.Create_Path (Path (Dir, "work/lists"));
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "work/lists/" & Stem & ".title"), Title & LF);
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "work/lists/" & Stem & ".txt"), Paths);
   end List;

   procedure Node (Dir : Scratch; File, Title, Summary : String) is
   begin
      Put
        (Dir, "synapse/widget@main/" & File & ".md",
         "---" & LF & "title: """ & Title & """" & LF &
         (if Summary = "" then "" else "summary: """ & Summary & """" & LF) &
         "---" & LF & "body" & LF);
   end Node;

   function Index_Text (Dir : Scratch) return String is
     (Synapse.Adapters.File_Bytes.Read
        (Path (Dir, "vault/synapse/widget@main/Index.md"), 100_000));

   procedure Build_Project_Index_Writes_A_Bullet_Per_Node_And_Says_What_It_Wrote
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Pin (F, Dir);
      List (Dir, "001", "Core", "a" & LF & "b" & LF);
      List (Dir, "002", "Bee/Two", "c" & LF);
      Node (Dir, "Core", "Core", "The core.");
      Node (Dir, "Bee_Two", "Bee/Two", "Bee two.");
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "work/all.txt"),
         "a" & LF & "b" & LF & "c" & LF & "d" & LF);
      Assert (Run (Env (F), Args) = 0, "success: " & F.Console.Err_Text);
      Assert
        (F.Console.Out_Text =
         "Index.md written: 2 nodes, 4 tracked files, remote=https://h/o/widget.git" &
         LF,
         "the line: " & F.Console.Out_Text);
      Assert
        (Ada.Strings.Fixed.Index
           (Index_Text (Dir), "built_at: ""2026-10-07 14:32""") >
         0,
         "built_at");
      Assert
        (Ada.Strings.Fixed.Index (Index_Text (Dir), "[[Bee_Two]]") > 0,
         "a bullet");
      Assert
        (Ada.Strings.Fixed.Index (Index_Text (Dir), "[[Bee_Two]]") <
         Ada.Strings.Fixed.Index (Index_Text (Dir), "[[Core]]"),
         "in byte order of the link");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Project_Index_Writes_A_Bullet_Per_Node_And_Says_What_It_Wrote;

   procedure Build_Project_Index_Counts_The_Union_Of_The_Lists_Without_All_Txt
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Pin (F, Dir);
      List (Dir, "001", "Core", "a" & LF & "b" & LF);
      List (Dir, "002", "Z", "a" & LF & "c" & LF);
      Node (Dir, "Core", "Core", "Core.");
      Node (Dir, "Z", "Z", "Zed.");
      Assert (Run (Env (F), Args) = 0, "success");
      Assert
        (Ada.Strings.Fixed.Index (F.Console.Out_Text, "3 tracked files") > 0,
         "distinct paths: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Project_Index_Counts_The_Union_Of_The_Lists_Without_All_Txt;

   procedure Build_Project_Index_Ignores_An_Empty_All_Txt
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Pin (F, Dir);
      List (Dir, "001", "Core", "a" & LF & "b" & LF);
      Node (Dir, "Core", "Core", "Core.");
      Synapse.Adapters.File_Bytes.Write (Path (Dir, "work/all.txt"), "");
      Assert (Run (Env (F), Args) = 0, "success");
      Assert
        (Ada.Strings.Fixed.Index (F.Console.Out_Text, "2 tracked files") > 0,
         "the lists' own paths: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Project_Index_Ignores_An_Empty_All_Txt;

   procedure Build_Project_Index_Squashes_Tabs_In_A_Summary
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Pin (F, Dir);
      List (Dir, "001", "Core", "a" & LF);
      Node (Dir, "Core", "Core", "one" & ASCII.HT & "two");
      Assert (Run (Env (F), Args) = 0, "success");
      Assert
        (Ada.Strings.Fixed.Index (Index_Text (Dir), "one two") > 0, "a space");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Project_Index_Squashes_Tabs_In_A_Summary;

   procedure Build_Project_Index_Needs_Each_Node_And_Its_Summary
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Pin (F, Dir);
      List (Dir, "001", "Core", "a" & LF);
      Assert (Run (Env (F), Args) = 1, "no node");
      Node (Dir, "Core", "Core", "");
      Assert (Run (Env (F), Args) = 1, "no summary");
      Assert
        (F.Console.Err_Text =
         "synapse-build-project-index: node not in the vault: Core.md" & LF &
         "  the index is built from the nodes, so write them first" & LF &
         "synapse-build-project-index: no summary field on Core.md" & LF,
         "the advice for each: " & F.Console.Err_Text);
      Assert
        (Ada.Strings.Fixed.Index (Index_Text (Dir), "# old") > 0,
         "the old index stays");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Project_Index_Needs_Each_Node_And_Its_Summary;

   procedure Build_Project_Index_Needs_Lists (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Pin (F, Dir);
      Assert (Run (Env (F), Args) = 1, "no lists");
      Assert
        (F.Console.Err_Text =
         "synapse-build-project-index: no lists/NN.title in " &
         Path (Dir, "work") & LF,
         "the message");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Project_Index_Needs_Lists;

   procedure Build_Project_Index_Arguments (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Assert (Run (Env (F), Args ("x")) = 2, "an argument");
      Assert (Run (Env (F), Args ("--help")) = 0, "help");
      Assert
        (F.Console.Err_Text =
         "usage: synapse build-project-index" & LF &
         "usage: synapse build-project-index" & LF,
         "the usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Project_Index_Arguments;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Project_Index");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T,
         Build_Project_Index_Writes_A_Bullet_Per_Node_And_Says_What_It_Wrote'
           Access,
         "Build project index writes a bullet per node and says what it wrote");
      Register_Routine
        (T,
         Build_Project_Index_Counts_The_Union_Of_The_Lists_Without_All_Txt'
           Access,
         "Build project index counts the union of the lists without all.txt");
      Register_Routine
        (T, Build_Project_Index_Ignores_An_Empty_All_Txt'Access,
         "Build project index ignores an empty all.txt");
      Register_Routine
        (T, Build_Project_Index_Squashes_Tabs_In_A_Summary'Access,
         "Build project index squashes tabs in a summary");
      Register_Routine
        (T, Build_Project_Index_Needs_Each_Node_And_Its_Summary'Access,
         "Build project index needs each node and its summary");
      Register_Routine
        (T, Build_Project_Index_Needs_Lists'Access,
         "Build project index needs lists");
      Register_Routine
        (T, Build_Project_Index_Arguments'Access,
         "Build project index arguments");
   end Register_Tests;

end Synapse.Commands.Project_Index.Tests;
