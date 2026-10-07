with Ada.Directories;
with Ada.Strings.Fixed;

with AUnit.Assertions;

with Synapse.Adapters.File_Bytes;
with Synapse.Core.Command_Map;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;

package body Synapse.Commands.Show_Context.Tests is

   use AUnit.Assertions;
   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   procedure Pin (F : in out Fixture; Dir : Scratch) is
   begin
      F.Vars.Set ("SYNAPSE_VAULT_DIR", Path (Dir, "vault"));
      F.Vars.Set ("HOME", Path (Dir, "home"));
      F.Vars.Set ("SYNAPSE_NAMESPACE", "widget@main");
      F.Vars.Set ("SYNAPSE_REPO_ROOT", "/work/widget");
      F.Vars.Set ("SYNAPSE_BRANCH", "main");
      F.Vars.Set ("SYNAPSE_REMOTE", "https://host.example/org/widget.git");
   end Pin;

   procedure Write_Index (Dir : Scratch; Branch : String) is
   begin
      Ada.Directories.Create_Path (Path (Dir, "vault/synapse/widget@main"));
      Adapters.File_Bytes.Write
        (Path (Dir, "vault/synapse/widget@main/Index.md"),
         "---" & LF & "branch: " & Branch & LF &
         "remote: https://host.example/org/widget.git" & LF & "---" & LF);
   end Write_Index;

   procedure It_Names_The_Graph_Directory_And_Every_Map_Entry
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Pin (F, Dir);
      Write_Index (Dir, "main");
      Assert (Run (Env (F), Args) = 0, "success");
      declare
         Shown : constant String := F.Console.Out_Text;
         Graph : constant String := Path (Dir, "vault/synapse/widget@main");
      begin
         Assert
           (Ada.Strings.Fixed.Index
              (Shown,
               "Synapse graph for this repo and branch: " & Graph &
               "/ (map: " & Graph & "/Index.md)" & LF) =
            1,
            "the graph line, first");
         for I in Core.Command_Map.Entry_Index loop
            Assert
              (Ada.Strings.Fixed.Index
                 (Shown, Core.Command_Map.Command_Of (I)) >
               0,
               Core.Command_Map.Command_Of (I));
         end loop;
         Assert (Shown = Text (Graph), "it is exactly Text");
      end;
      Assert (F.Console.Err_Text = "", "nothing on standard error");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end It_Names_The_Graph_Directory_And_Every_Map_Entry;

   procedure A_Branch_With_No_Graph_Exits_One (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Pin (F, Dir);
      Assert (Run (Env (F), Args) = 1, "code 1");
      Assert (F.Console.Out_Text = "", "nothing on standard output");
      Assert
        (F.Console.Err_Text =
         "synapse-context: no namespace covers synapse/widget@main/ -- " &
         "this branch has no graph" & LF,
         "and why");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Branch_With_No_Graph_Exits_One;

   procedure A_Folder_Recording_Another_Branch_Exits_One
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Pin (F, Dir);
      Write_Index (Dir, "dev");
      Assert (Run (Env (F), Args) = 1, "code 1");
      Assert (F.Console.Out_Text = "", "nothing on standard output");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Folder_Recording_Another_Branch_Exits_One;

   procedure No_Vault_Exits_One (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      F.Vars.Set ("HOME", "/nonexistent-home");
      Assert (Run (Env (F), Args) = 1, "code 1");
      Assert (F.Console.Err_Text = "synapse-context: no vault" & LF, "why");
   end No_Vault_Exits_One;

   procedure Arguments_Print_Usage_And_Help_Succeeds
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Assert (Run (Env (F), Args ("--help")) = 0, "help succeeds");
      Assert (Run (Env (F), Args ("-h")) = 0, "-h too");
      Assert (Run (Env (F), Args ("extra")) = 2, "anything else is usage");
      Assert (F.Console.Out_Text = "", "nothing on standard output");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text, "usage: synapse context") =
         1,
         "the usage");
   end Arguments_Print_Usage_And_Help_Succeeds;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Show_Context");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, It_Names_The_Graph_Directory_And_Every_Map_Entry'Access,
         "It names the graph directory and every map entry");
      Register_Routine
        (T, A_Branch_With_No_Graph_Exits_One'Access,
         "A branch with no graph exits one");
      Register_Routine
        (T, A_Folder_Recording_Another_Branch_Exits_One'Access,
         "A folder recording another branch exits one");
      Register_Routine (T, No_Vault_Exits_One'Access, "No vault exits one");
      Register_Routine
        (T, Arguments_Print_Usage_And_Help_Succeeds'Access,
         "Arguments print usage and help succeeds");
   end Register_Tests;

end Synapse.Commands.Show_Context.Tests;
