with Ada.Directories;
with Ada.Strings.Fixed;
with Synapse.Adapters.File_Bytes;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Repo;
with Synapse.Test_Vault;
with AUnit.Assertions;

package body Synapse.Commands.Declared.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Repo;
   use Synapse.Test_Vault;

   LF : constant Character := Character'Val (10);
   HT : constant Character := ASCII.HT;

   Deps_Rules : constant String :=
     "{""xx"": {""kind"": ""build-file"", ""file"": ""build.deps"", " &
     """prefix"": ""depends ""}}";

   Namespace_Rules : constant String :=
     "{""yy"": {""kind"": ""in-file"", ""prefix"": ""package "", " &
     """terminator"": "";""}}";

   procedure Sample (Dir : Scratch) is
   begin
      Put_File
        (Dir, "widget/src/build.deps",
         "name widget" & LF & "depends gadget str" & LF);
      Put_File (Dir, "widget/src/main.xx", "run" & LF);
      Put_File (Dir, "gadget/a.yy", "package alpha.beta;" & LF);
      Put_File (Dir, "docs/guide.md", "# guide" & LF);
      Commit_All (Dir);
   end Sample;

   function Out_Path (Dir : Scratch) return String is
     (Path (Dir, "work/out.tsv"));

   procedure Build_Deps_Writes_An_Edge_For_Each_Declared_Dependency
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Put_Config (Dir, "synapse-dependency-rules.conf", Deps_Rules);
      Sample (Dir);
      Assert
        (Run_Deps
           (Env (F), Args ("--repo", Repo (Dir), "--out", Out_Path (Dir))) =
         0,
         "success: " & F.Console.Err_Text);
      Assert
        (Synapse.Adapters.File_Bytes.Read (Out_Path (Dir), 10_000) =
         "widget/src/main.xx" & HT & "gadget" & LF & "widget/src/main.xx" &
         HT & "str" & LF,
         "the edges");
      Assert
        (F.Console.Err_Text =
         "synapse-build-deps: 2 edge(s) -> " & Out_Path (Dir) & LF,
         "the report: " & F.Console.Err_Text);
      Assert (F.Console.Out_Text = "", "on standard error only");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Deps_Writes_An_Edge_For_Each_Declared_Dependency;

   procedure Build_Deps_Defaults_The_Output_To_The_Work_Directory
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Put_Config (Dir, "synapse-dependency-rules.conf", Deps_Rules);
      Sample (Dir);
      Assert (Run_Deps (Env (F), Args ("--repo", Repo (Dir))) = 0, "success");
      Assert
        (Ada.Directories.Exists (Path (Dir, "work/_deps.tsv")),
         "written there");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Deps_Defaults_The_Output_To_The_Work_Directory;

   procedure Build_Deps_With_No_Rules_Writes_An_Empty_File
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Sample (Dir);
      Assert
        (Run_Deps
           (Env (F), Args ("--repo", Repo (Dir), "--out", Out_Path (Dir))) =
         0,
         "success");
      Assert
        (Synapse.Adapters.File_Bytes.Read (Out_Path (Dir), 100) = "", "empty");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Deps_With_No_Rules_Writes_An_Empty_File;

   procedure Build_Deps_Leaves_Out_What_The_Ignore_Patterns_Exclude
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Put_Config (Dir, "synapse-dependency-rules.conf", Deps_Rules);
      Put_Config (Dir, "synapse-ignore-files.conf", "\.xx$" & LF);
      Sample (Dir);
      Assert
        (Run_Deps
           (Env (F), Args ("--repo", Repo (Dir), "--out", Out_Path (Dir))) =
         0,
         "success");
      Assert
        (Synapse.Adapters.File_Bytes.Read (Out_Path (Dir), 100) = "",
         "no source left to declare");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Deps_Leaves_Out_What_The_Ignore_Patterns_Exclude;

   procedure Build_Deps_Says_Why_It_Cannot (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Sample (Dir);
      Put_Config (Dir, "synapse-dependency-rules.conf", "not json");
      Assert
        (Run_Deps (Env (F), Args ("--repo", Repo (Dir))) = 1, "bad rules");
      Assert
        (Run_Deps (Env (F), Args ("--repo", Path (Dir, "vault"))) = 1,
         "no repository");
      Assert
        (F.Console.Err_Text =
         "synapse-build-deps: cannot read the dependency-rules registry" & LF &
         "synapse-build-deps: not inside a git repo" & LF,
         "the messages: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Deps_Says_Why_It_Cannot;

   procedure Build_Deps_And_Namespaces_Do_Nothing_Without_A_Home
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Sample (Dir);
      Assert
        (Run_Deps
           (Env (F), Args ("--repo", Repo (Dir), "--out", Out_Path (Dir))) =
         1,
         "deps");
      Assert
        (Run_Namespaces
           (Env (F), Args ("--repo", Repo (Dir), "--out", Out_Path (Dir))) =
         1,
         "namespaces");
      Assert
        (F.Console.Err_Text = "" and then F.Console.Out_Text = "", "silently");
      Assert (not Ada.Directories.Exists (Out_Path (Dir)), "nothing written");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Deps_And_Namespaces_Do_Nothing_Without_A_Home;

   procedure Build_Deps_Arguments (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Assert (Run_Deps (Env (F), Args ("--wat")) = 2, "unknown");
      Assert (Run_Deps (Env (F), Args ("--repo")) = 2, "dangling");
      Assert
        (Run_Deps (Env (F), Args ("--repo", "--out")) = 2,
         "a flag is not a value");
      F.Console.Clear;
      Assert (Run_Deps (Env (F), Args ("--help")) = 0, "help");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Err_Text, "usage: synapse build-deps [--repo <path>]") =
         1,
         "usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Deps_Arguments;

   procedure Build_Namespaces_Writes_The_Declared_Namespace_Of_Each_File
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Put_Config (Dir, "synapse-namespace-rules.conf", Namespace_Rules);
      Sample (Dir);
      Assert
        (Run_Namespaces
           (Env (F), Args ("--repo", Repo (Dir), "--out", Out_Path (Dir))) =
         0,
         "success: " & F.Console.Err_Text);
      Assert
        (Synapse.Adapters.File_Bytes.Read (Out_Path (Dir), 10_000) =
         "gadget/a.yy" & HT & "alpha.beta" & LF,
         "the one declaration");
      Assert
        (F.Console.Err_Text =
         "synapse-build-namespaces: 1 row(s) -> " & Out_Path (Dir) & LF,
         "the report");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Namespaces_Writes_The_Declared_Namespace_Of_Each_File;

   procedure Build_Namespaces_Says_Why_It_Cannot (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Work (F, Dir);
      Sample (Dir);
      Put_Config (Dir, "synapse-namespace-rules.conf", "x");
      Assert
        (Run_Namespaces (Env (F), Args ("--repo", Repo (Dir))) = 1,
         "bad rules");
      Assert
        (F.Console.Err_Text =
         "synapse-build-namespaces: cannot read the namespace-rules registry" &
         LF,
         "the message");
      Assert (Run_Namespaces (Env (F), Args ("-x")) = 2, "usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Build_Namespaces_Says_Why_It_Cannot;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Declared");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Build_Deps_Writes_An_Edge_For_Each_Declared_Dependency'Access,
         "Build deps writes an edge for each declared dependency");
      Register_Routine
        (T, Build_Deps_Defaults_The_Output_To_The_Work_Directory'Access,
         "Build deps defaults the output to the work directory");
      Register_Routine
        (T, Build_Deps_With_No_Rules_Writes_An_Empty_File'Access,
         "Build deps with no rules writes an empty file");
      Register_Routine
        (T, Build_Deps_Leaves_Out_What_The_Ignore_Patterns_Exclude'Access,
         "Build deps leaves out what the ignore patterns exclude");
      Register_Routine
        (T, Build_Deps_Says_Why_It_Cannot'Access,
         "Build deps says why it cannot");
      Register_Routine
        (T, Build_Deps_And_Namespaces_Do_Nothing_Without_A_Home'Access,
         "Build deps and namespaces do nothing without a home");
      Register_Routine
        (T, Build_Deps_Arguments'Access, "Build deps arguments");
      Register_Routine
        (T, Build_Namespaces_Writes_The_Declared_Namespace_Of_Each_File'Access,
         "Build namespaces writes the declared namespace of each file");
      Register_Routine
        (T, Build_Namespaces_Says_Why_It_Cannot'Access,
         "Build namespaces says why it cannot");
   end Register_Tests;

end Synapse.Commands.Declared.Tests;
