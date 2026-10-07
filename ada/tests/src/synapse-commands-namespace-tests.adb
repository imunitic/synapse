with Ada.Directories;

with AUnit.Assertions;

with Synapse.Core.Identity;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;

package body Synapse.Commands.Namespace.Tests is

   use AUnit.Assertions;
   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   --  A repository named `widget` on branch `feature/x`, whose remote is a
   --  made up host.
   procedure Make_Repo (Dir : Scratch; Branch : String := "feature/x") is
      Repo : constant String := Path (Dir, "widget");
   begin
      Ada.Directories.Create_Path (Repo);
      Init_Repo (Repo);
      Git
        (Repo, "remote", "add", "origin",
         "https://host.example/org/widget.git");
      Git (Repo, "checkout", "-q", "-b", Branch);
   end Make_Repo;

   procedure The_Namespace_Is_Repo_At_Sanitized_Branch
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Make_Repo (Dir);
      Assert
        (Run (Env (F), Args ("--repo", Path (Dir, "widget"))) = 0, "success");
      Assert
        (F.Console.Out_Text = "widget@feature-x",
         "repo@branch, the slash made safe, no line feed");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Namespace_Is_Repo_At_Sanitized_Branch;

   procedure Each_Half_Can_Be_Asked_For_On_Its_Own
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Make_Repo (Dir);
      Assert
        (Run (Env (F), Args ("--repo", Path (Dir, "widget"), "--branch")) = 0
         and then F.Console.Out_Text = "feature-x",
         "the branch");
      declare
         G : aliased Fixture;
      begin
         Assert
           (Run
              (Env (G), Args ("--repo", Path (Dir, "widget"), "--repo-name")) =
            0
            and then G.Console.Out_Text = "widget",
            "the repository");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Each_Half_Can_Be_Asked_For_On_Its_Own;

   procedure Outside_A_Repository_It_Exits_One_And_Says_So
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make_Outside_Git;
      F   : aliased Fixture;
   begin
      Assert (Run (Env (F), Args ("--repo", Path (Dir))) = 1, "code 1");
      Assert (F.Console.Out_Text = "", "nothing on standard output");
      Assert
        (F.Console.Err_Text =
         "synapse-namespace: not inside a git repo" & Character'Val (10),
         "and why");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Outside_A_Repository_It_Exits_One_And_Says_So;

   procedure A_Detached_Head_Has_No_Namespace (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Make_Repo (Dir, "main");
      Git (Path (Dir, "widget"), "commit", "-q", "--allow-empty", "-m", "x");
      Git (Path (Dir, "widget"), "checkout", "-q", "--detach");
      Assert
        (Run (Env (F), Args ("--repo", Path (Dir, "widget"))) = 1, "code 1");
      Assert
        (F.Console.Err_Text =
         Synapse.Core.Identity.Detached_Message & Character'Val (10),
         "the detached message");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Detached_Head_Has_No_Namespace;

   procedure Bad_Arguments_Are_Usage_Errors (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Assert (Run (Env (F), Args ("--repo")) = 2, "--repo with no value");
      Assert
        (Run (Env (F), Args ("--repo", "--branch")) = 2,
         "--repo whose value looks like a flag");
      Assert (Run (Env (F), Args ("--wat")) = 2, "an unknown flag");
      Assert (F.Console.Out_Text = "", "nothing on standard output");
   end Bad_Arguments_Are_Usage_Errors;

   procedure Help_Succeeds_On_Standard_Error (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Assert (Run (Env (F), Args ("--help")) = 0, "success");
      Assert
        (F.Console.Out_Text = "" and then F.Console.Err_Text'Length > 0,
         "usage on standard error");
   end Help_Succeeds_On_Standard_Error;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Namespace");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, The_Namespace_Is_Repo_At_Sanitized_Branch'Access,
         "The namespace is repo at sanitized branch");
      Register_Routine
        (T, Each_Half_Can_Be_Asked_For_On_Its_Own'Access,
         "Each half can be asked for on its own");
      Register_Routine
        (T, Outside_A_Repository_It_Exits_One_And_Says_So'Access,
         "Outside a repository it exits one and says so");
      Register_Routine
        (T, A_Detached_Head_Has_No_Namespace'Access,
         "A detached head has no namespace");
      Register_Routine
        (T, Bad_Arguments_Are_Usage_Errors'Access,
         "Bad arguments are usage errors");
      Register_Routine
        (T, Help_Succeeds_On_Standard_Error'Access,
         "Help succeeds on standard error");
   end Register_Tests;

end Synapse.Commands.Namespace.Tests;
