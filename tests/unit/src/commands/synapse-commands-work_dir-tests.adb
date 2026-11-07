with Ada.Strings.Fixed;

with Ada.Directories;

with AUnit.Assertions;

with Synapse.Adapters.File_Bytes;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;

package body Synapse.Commands.Work_Dir.Tests is

   use AUnit.Assertions;
   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   procedure Root_Prints_The_Root (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Assert (Run (Env (F), Args ("--root")) = 1, "no home, no root");
      Assert (Has (F.Console.Err_Text, "no HOME"), "and it says so");
      F.Vars.Set ("HOME", "/home/u");
      Assert
        (Run (Env (F), Args ("--root")) = 0
         and then F.Console.Out_Text = "/home/u/.cache/synapse/work" & LF,
         "the default root: " & F.Console.Out_Text);
   end Root_Prints_The_Root;

   procedure A_Named_Root_And_A_Namespace_Give_The_Folder
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      F.Vars.Set ("HOME", "/home/u");
      F.Vars.Set ("SYNAPSE_WORK_DIR", "/r");
      Assert
        (Run (Env (F), Args ("--root")) = 0
         and then F.Console.Out_Text = "/r" & LF,
         "the variable is the root");
      Assert
        (Run (Env (F), Args ("--namespace", "repo@main")) = 0
         and then F.Console.Out_Text = "/r" & LF & "/r/repo@main" & LF,
         "a namespace is a folder of it: " & F.Console.Out_Text);
   end A_Named_Root_And_A_Namespace_Give_The_Folder;

   procedure The_Namespace_Of_The_Environment_Gives_The_Folder
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      F.Vars.Set ("HOME", "/home/u");
      F.Vars.Set ("SYNAPSE_NAMESPACE", "widget@main");
      Assert
        (Run (Env (F), Args) = 0
         and then F.Console.Out_Text =
                  "/home/u/.cache/synapse/work/widget@main" & LF,
         "with no argument, the namespace the environment names: "
         & F.Console.Out_Text);
   end The_Namespace_Of_The_Environment_Gives_The_Folder;

   procedure Put (Dir : Scratch; Name : String) is
   begin
      Ada.Directories.Create_Path
        (Ada.Directories.Containing_Directory (Path (Dir, Name)));
      Synapse.Adapters.File_Bytes.Write (Path (Dir, Name), "x");
   end Put;

   procedure List_Names_The_Namespaces_That_Have_Local_Files
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      F.Vars.Set ("HOME", Path (Dir, "home"));
      F.Vars.Set ("SYNAPSE_WORK_DIR", Path (Dir, "root"));
      Assert
        (Run (Env (F), Args ("--list")) = 0 and then F.Console.Out_Text = "",
         "no root folder, no namespaces");
      Put (Dir, "root/zeta@main/_index.bin");
      Put (Dir, "root/zeta@main/_refs.tsv");
      Put (Dir, "root/zeta@main/_tags_cache.bin");
      Put (Dir, "root/alpha@dev/_refs.tsv");
      Put (Dir, "root/alpha@dev/_tags_cache.bin");
      Put (Dir, "root/beta@main/_index.bin");
      --  Not namespaces: no @, no local files, a file and the pipelines.
      Put (Dir, "root/plain/_index.bin");
      Put (Dir, "root/empty@main/notes.txt");
      Put (Dir, "root/pipelines/exec-1/execution.json");
      Put (Dir, "root/loose@file");
      Assert (Run (Env (F), Args ("--list")) = 0, "it succeeds");
      Assert
        (F.Console.Out_Text =
         "alpha@dev" & ASCII.HT & "refs,tags" & LF
         & "beta@main" & ASCII.HT & "index" & LF
         & "zeta@main" & ASCII.HT & "index,refs,tags" & LF,
         "the namespaces, sorted, with what each has: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end List_Names_The_Namespaces_That_Have_Local_Files;

   procedure Bad_Arguments_Are_A_Usage_Error_And_Help_Is_Not
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Assert (Run (Env (F), Args ("--bogus")) = 2, "an unknown flag");
      Assert (Run (Env (F), Args ("--namespace")) = 2, "a missing value");
      Assert (Run (Env (F), Args ("--root", "x")) = 2, "an extra argument");
      Assert
        (Run (Env (F), Args ("--namespace", "nobranch")) = 1
         and then Has (F.Console.Err_Text, "expects <repo>@<branch>"),
         "a namespace without an @");
      Assert
        (Run (Env (F), Args ("--help")) = 0
         and then Has (F.Console.Out_Text, "usage: synapse work-dir"),
         "help");
   end Bad_Arguments_Are_A_Usage_Error_And_Help_Is_Not;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Work_Dir");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Root_Prints_The_Root'Access, "Root prints the root");
      Register_Routine
        (T, A_Named_Root_And_A_Namespace_Give_The_Folder'Access,
         "A named root and a namespace give the folder");
      Register_Routine
        (T, The_Namespace_Of_The_Environment_Gives_The_Folder'Access,
         "The namespace of the environment gives the folder");
      Register_Routine
        (T, List_Names_The_Namespaces_That_Have_Local_Files'Access,
         "List names the namespaces that have local files");
      Register_Routine
        (T, Bad_Arguments_Are_A_Usage_Error_And_Help_Is_Not'Access,
         "Bad arguments are a usage error and help is not");
   end Register_Tests;

end Synapse.Commands.Work_Dir.Tests;
