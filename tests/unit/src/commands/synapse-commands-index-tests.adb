with Ada.Directories;
with Ada.Strings.Fixed;
with Synapse.Adapters.File_Bytes;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Repo;
with AUnit.Assertions;

package body Synapse.Commands.Index.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Repo;

   LF : constant Character := Character'Val (10);
   HT : constant Character := ASCII.HT;

   Pairs : constant String :=
     "src/a.ext" & HT & "Core.md" & LF & "src/b.ext" & HT & "Bee.md" & LF &
     "src/a.ext" & HT & "Bee.md" & LF;

   procedure Put_Work (Dir : Scratch; Name, Text : String) is
   begin
      Ada.Directories.Create_Path
        (Ada.Directories.Containing_Directory (Path (Dir, "work/" & Name)));
      Synapse.Adapters.File_Bytes.Write (Path (Dir, "work/" & Name), Text);
   end Put_Work;

   --  An index of the work directory with three claimed paths and one that
   --  nothing claims.
   procedure Built (F : aliased in out Fixture; Dir : Scratch) is
   begin
      Use_Work (F, Dir);
      Put_Work (Dir, "un.txt", "loose.txt" & LF);
      F.Console.Set_Stdin (Pairs);
      Assert
        (Run
           (Env (F),
            Args ("build", "--unassigned", Path (Dir, "work/un.txt"))) =
         0,
         "the index builds: " & F.Console.Err_Text);
      F.Console.Clear;
   end Built;

   procedure Build_From_Pairs_On_Standard_Input_Prints_The_Counts
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Put_Work (Dir, "un.txt", "loose.txt" & LF);
      F.Console.Set_Stdin (Pairs);
      Assert
        (Run
           (Env (F),
            Args ("build", "--unassigned", Path (Dir, "work/un.txt"))) =
         0,
         "success: " & F.Console.Err_Text);
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Out_Text, "keys=2 unassigned=1 bytes=") =
         1
         and then F.Console.Out_Text (F.Console.Out_Text'Last) = LF,
         "the counts: " & F.Console.Out_Text);
      Assert
        (Ada.Directories.Exists (Path (Dir, "work/_index.bin")), "written");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_From_Pairs_On_Standard_Input_Prints_The_Counts;

   procedure Build_Takes_The_Last_Tab_Of_A_Line_And_Skips_Lines_It_Cannot_Use
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      F.Console.Set_Stdin
        ("a" & HT & "b" & HT & "N.md" & ASCII.CR & LF & HT & "x" & LF & "p" &
         HT & LF & "no tab" & LF);
      Assert
        (Run (Env (F), Args ("build", "--out", Path (Dir, "work/i.bin"))) = 0,
         "success");
      F.Console.Clear;
      Assert
        (Run (Env (F), Args ("paths", "--file", Path (Dir, "work/i.bin"))) = 0,
         "paths");
      Assert
        (F.Console.Out_Text = "a" & HT & "b" & LF,
         "only the usable line: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Takes_The_Last_Tab_Of_A_Line_And_Skips_Lines_It_Cannot_Use;

   procedure Build_From_Lists_Names_Each_Node_After_Its_Title
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Put_Work (Dir, "lists/001.title", "Core" & LF);
      Put_Work
        (Dir, "lists/001.txt", "src/a.ext" & LF & " docs/x.md " & LF & LF);
      Put_Work (Dir, "lists/002.title", "Bee/Two: x" & LF);
      Put_Work (Dir, "lists/002.txt", "src/a.ext" & LF);
      Put_Work (Dir, "lists/003.txt", "no/title.ext" & LF);
      Assert
        (Run (Env (F), Args ("build", "--lists", Path (Dir, "work/lists"))) =
         0,
         "success: " & F.Console.Err_Text);
      F.Console.Clear;
      Assert (Run (Env (F), Args ("nodes")) = 0, "nodes");
      Assert
        (F.Console.Out_Text = "Bee_Two_ x.md" & LF & "Core.md" & LF,
         "titles as file names: " & F.Console.Out_Text);
      F.Console.Clear;
      Assert (Run (Env (F), Args ("paths")) = 0, "paths");
      Assert
        (F.Console.Out_Text = "docs/x.md" & LF & "src/a.ext" & LF,
         "the list with no title is left out");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_From_Lists_Names_Each_Node_After_Its_Title;

   procedure Build_With_Nothing_To_Claim_Or_No_Lists_Fails
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Put_Work (Dir, "lists/003.txt", "no/title.ext" & LF);
      Assert
        (Run (Env (F), Args ("build", "--lists", Path (Dir, "work/lists"))) =
         1,
         "no pairs");
      Assert
        (Run (Env (F), Args ("build", "--lists", Path (Dir, "work/none"))) = 1,
         "no directory");
      Assert
        (F.Console.Err_Text =
         "synapse-index: no (path, node) pairs" & LF &
         "synapse-index: cannot read --lists " & Path (Dir, "work/none") & LF &
         "synapse-index: no (path, node) pairs" & LF,
         "the messages: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_With_Nothing_To_Claim_Or_No_Lists_Fails;

   procedure Build_Says_When_The_Unassigned_File_Cannot_Be_Read
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      F.Console.Set_Stdin (Pairs);
      Assert
        (Run
           (Env (F),
            Args ("build", "--unassigned", Path (Dir, "work/gone.txt"))) =
         1,
         "code 1");
      Assert
        (F.Console.Err_Text =
         "synapse-index: cannot read --unassigned " &
         Path (Dir, "work/gone.txt") & LF,
         "the message");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Says_When_The_Unassigned_File_Cannot_Be_Read;

   procedure Build_Says_When_The_Index_Cannot_Be_Built
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      F.Console.Set_Stdin ([1 .. 70_000 => 'p'] & HT & "N.md" & LF);
      Assert (Run (Env (F), Args ("build")) = 1, "code 1");
      Assert
        (F.Console.Err_Text =
         "synapse-index: cannot build index (PathTooLong)" & LF,
         "named: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Says_When_The_Index_Cannot_Be_Built;

   procedure Lookup_Prints_The_Nodes_That_Claim_A_Path
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Built (F, Dir);
      Assert (Run (Env (F), Args ("lookup", "src/a.ext")) = 0, "claimed");
      Assert
        (F.Console.Out_Text = "Bee.md" & LF & "Core.md" & LF,
         "ascending: " & F.Console.Out_Text);
      F.Console.Clear;
      Assert (Run (Env (F), Args ("lookup", "nothere")) = 1, "unclaimed");
      Assert (F.Console.Out_Text = "", "nothing printed");
      Assert (Run (Env (F), Args ("lookup")) = 2, "no path");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Lookup_Prints_The_Nodes_That_Claim_A_Path;

   procedure Nodes_Paths_And_Unassigned_List_The_Index
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Built (F, Dir);
      Assert (Run (Env (F), Args ("nodes")) = 0, "nodes");
      Assert (Run (Env (F), Args ("paths")) = 0, "paths");
      Assert (Run (Env (F), Args ("unassigned")) = 0, "unassigned");
      Assert
        (F.Console.Out_Text =
         "Bee.md" & LF & "Core.md" & LF & "src/a.ext" & LF & "src/b.ext" & LF &
         "loose.txt" & LF,
         "in turn: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Nodes_Paths_And_Unassigned_List_The_Index;

   procedure Add_Unassigned_Queues_A_Path_Once (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Built (F, Dir);
      Assert (Run (Env (F), Args ("add-unassigned", "new.txt")) = 0, "added");
      Assert (Run (Env (F), Args ("add-unassigned", "new.txt")) = 0, "again");
      Assert (Run (Env (F), Args ("unassigned")) = 0, "listed");
      Assert
        (F.Console.Out_Text = "loose.txt" & LF & "new.txt" & LF,
         "once: " & F.Console.Out_Text);
      Assert (Run (Env (F), Args ("add-unassigned")) = 2, "no path");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Add_Unassigned_Queues_A_Path_Once;

   procedure Add_Unassigned_Is_Silent_Without_An_Index
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Assert
        (Run (Env (F), Args ("add-unassigned", "new.txt")) = 0, "success");
      Assert
        (not Ada.Directories.Exists (Path (Dir, "work/_index.bin")),
         "nothing created");
      Assert
        (F.Console.Out_Text = "" and then F.Console.Err_Text = "", "silent");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Add_Unassigned_Is_Silent_Without_An_Index;

   procedure A_Read_Form_Says_When_The_Index_Will_Not_Read
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Put_Work (Dir, "_index.bin", [1 .. 100 => 'x']);
      Assert (Run (Env (F), Args ("nodes")) = 1, "code 1");
      Assert
        (F.Console.Err_Text =
         "synapse-index: unreadable index (NotAnIndex): " &
         Path (Dir, "work/_index.bin") & LF,
         "named: " & F.Console.Err_Text);
      F.Console.Clear;
      Assert
        (Run (Env (F), Args ("add-unassigned", "x")) = 0,
         "a write form leaves it alone");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Read_Form_Says_When_The_Index_Will_Not_Read;

   procedure Namespace_Names_Another_Checkout_S_Index
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      F.Vars.Set ("HOME", Path (Dir, "home"));
      Put_Work (Dir, "unused.txt", "");
      Ada.Directories.Create_Path
        (Path (Dir, "home/.cache/synapse/work/widget@main"));
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "home/.cache/synapse/work/widget@main/_index.bin"),
         Synapse.Adapters.File_Bytes.Read (Path (Dir, "work/unused.txt"), 10));
      Assert
        (Run (Env (F), Args ("nodes", "--namespace", "widget@main")) = 0,
         "an empty index reads");
      Assert
        (Run (Env (F), Args ("nodes", "--namespace", "widget")) = 1, "no @");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text,
            "--namespace expects <repo>@<branch>, got 'widget'") >
         0,
         "the message: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Namespace_Names_Another_Checkout_S_Index;

   procedure Namespace_Is_For_A_Read_Form_Only (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Assert
        (Run (Env (F), Args ("build", "--namespace", "a@b")) = 2, "build");
      Assert
        (Run (Env (F), Args ("add-unassigned", "x", "--namespace", "a@b")) = 2,
         "add");
      Assert
        (Run (Env (F), Args ("nodes", "--namespace", "a@b", "--file", "x")) =
         2,
         "with a file");
      Assert
        (F.Console.Err_Text =
         "synapse-index: --namespace only applies to a read form (unassigned/lookup/nodes/paths)" &
         LF &
         "synapse-index: --namespace only applies to a read form (unassigned/lookup/nodes/paths)" &
         LF &
         "synapse-index: --file/--out already names the index directly -- --namespace has nothing to do" &
         LF,
         "the messages: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Namespace_Is_For_A_Read_Form_Only;

   procedure Without_A_Work_Directory_Or_A_File_It_Says_So
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      F.Vars.Set ("SYNAPSE_NAMESPACE", "widget@main");
      Assert (Run (Env (F), Args ("nodes")) = 1, "code 1");
      Assert
        (F.Console.Err_Text =
         "synapse-index: no HOME, so no default work dir" & LF &
         "synapse-index: no SYNAPSE_WORK_DIR and no --out/--file" & LF,
         "both messages: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Without_A_Work_Directory_Or_A_File_It_Says_So;

   procedure Index_Arguments_It_Does_Not_Know_Are_A_Usage_Error
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Assert (Run (Env (F), Args) = 2, "no form");
      Assert (Run (Env (F), Args ("nodes", "--wat")) = 2, "unknown flag");
      Assert (Run (Env (F), Args ("nodes", "--file")) = 2, "dangling");
      Assert (Run (Env (F), Args ("nodes", "a", "b")) = 2, "two words");
      Assert (Run (Env (F), Args ("wat")) = 2, "unknown form");
      F.Console.Clear;
      Assert (Run (Env (F), Args ("--help")) = 0, "help");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text, "usage: synapse index build") =
         1,
         "its usage");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text, "synapse index lookup <path>") >
         0,
         "every form");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Index_Arguments_It_Does_Not_Know_Are_A_Usage_Error;

   procedure Build_Index_Writes_The_Index_Of_The_Work_Directory
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      F.Vars.Set ("SYNAPSE_VAULT_DIR", Path (Dir, "vault"));
      F.Vars.Set ("SYNAPSE_NAMESPACE", "widget@main");
      F.Vars.Set ("SYNAPSE_REPO_ROOT", "/r");
      F.Vars.Set ("SYNAPSE_BRANCH", "main");
      Put_Work (Dir, "lists/001.title", "Core" & LF);
      Put_Work (Dir, "lists/001.txt", "src/a.ext" & LF);
      Put_Work (Dir, "unassigned.txt", "loose.txt" & LF);
      Assert
        (Run_Build_Index (Env (F), Args) = 0,
         "success: " & F.Console.Err_Text);
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Out_Text,
            "_index.bin written: keys=1 unassigned=1 bytes=") =
         1,
         "the line: " & F.Console.Out_Text);
      Assert
        (Ada.Directories.Exists (Path (Dir, "work/_index.bin")), "written");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Index_Writes_The_Index_Of_The_Work_Directory;

   procedure Build_Index_Needs_The_Lists_And_The_Unassigned_File
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      F.Vars.Set ("SYNAPSE_VAULT_DIR", Path (Dir, "vault"));
      F.Vars.Set ("SYNAPSE_NAMESPACE", "widget@main");
      F.Vars.Set ("SYNAPSE_REPO_ROOT", "/r");
      F.Vars.Set ("SYNAPSE_BRANCH", "main");
      Ada.Directories.Create_Path (Path (Dir, "work"));
      Assert (Run_Build_Index (Env (F), Args) = 1, "no lists");
      Ada.Directories.Create_Path (Path (Dir, "work/lists"));
      Assert (Run_Build_Index (Env (F), Args) = 1, "no unassigned");
      Assert
        (F.Console.Err_Text =
         "synapse-build-index: no lists/ in " & Path (Dir, "work") & LF &
         "synapse-build-index: no unassigned.txt in " & Path (Dir, "work") &
         LF,
         "the messages: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Index_Needs_The_Lists_And_The_Unassigned_File;

   procedure Build_Index_Arguments (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Assert (Run_Build_Index (Env (F), Args ("x")) = 2, "an argument");
      Assert (Run_Build_Index (Env (F), Args ("--help")) = 0, "help");
      Assert
        (F.Console.Err_Text =
         "usage: synapse build-index" & LF & "usage: synapse build-index" & LF,
         "the usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Index_Arguments;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Index");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Build_From_Pairs_On_Standard_Input_Prints_The_Counts'Access,
         "Build from pairs on standard input prints the counts");
      Register_Routine
        (T,
         Build_Takes_The_Last_Tab_Of_A_Line_And_Skips_Lines_It_Cannot_Use'
           Access,
         "Build takes the last tab of a line and skips lines it cannot use");
      Register_Routine
        (T, Build_From_Lists_Names_Each_Node_After_Its_Title'Access,
         "Build from lists names each node after its title");
      Register_Routine
        (T, Build_With_Nothing_To_Claim_Or_No_Lists_Fails'Access,
         "Build with nothing to claim or no lists fails");
      Register_Routine
        (T, Build_Says_When_The_Unassigned_File_Cannot_Be_Read'Access,
         "Build says when the unassigned file cannot be read");
      Register_Routine
        (T, Build_Says_When_The_Index_Cannot_Be_Built'Access,
         "Build says when the index cannot be built");
      Register_Routine
        (T, Lookup_Prints_The_Nodes_That_Claim_A_Path'Access,
         "Lookup prints the nodes that claim a path");
      Register_Routine
        (T, Nodes_Paths_And_Unassigned_List_The_Index'Access,
         "Nodes paths and unassigned list the index");
      Register_Routine
        (T, Add_Unassigned_Queues_A_Path_Once'Access,
         "Add unassigned queues a path once");
      Register_Routine
        (T, Add_Unassigned_Is_Silent_Without_An_Index'Access,
         "Add unassigned is silent without an index");
      Register_Routine
        (T, A_Read_Form_Says_When_The_Index_Will_Not_Read'Access,
         "A read form says when the index will not read");
      Register_Routine
        (T, Namespace_Names_Another_Checkout_S_Index'Access,
         "Namespace names another checkout's index");
      Register_Routine
        (T, Namespace_Is_For_A_Read_Form_Only'Access,
         "Namespace is for a read form only");
      Register_Routine
        (T, Without_A_Work_Directory_Or_A_File_It_Says_So'Access,
         "Without a work directory or a file it says so");
      Register_Routine
        (T, Index_Arguments_It_Does_Not_Know_Are_A_Usage_Error'Access,
         "Index arguments it does not know are a usage error");
      Register_Routine
        (T, Build_Index_Writes_The_Index_Of_The_Work_Directory'Access,
         "Build index writes the index of the work directory");
      Register_Routine
        (T, Build_Index_Needs_The_Lists_And_The_Unassigned_File'Access,
         "Build index needs the lists and the unassigned file");
      Register_Routine
        (T, Build_Index_Arguments'Access, "Build index arguments");
   end Register_Tests;

end Synapse.Commands.Index.Tests;
