with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Adapters.Dynamic_Libraries;
with Synapse.Adapters.File_Bytes;
with Synapse.Adapters.System_Process;
with Synapse.Core.Grammar_Registry;
with Synapse.Test_Grammar_Repos;
with Synapse.Test_Scratch;

package body Synapse.Adapters.Tree_Sitter.Resolution.Tests is

   use AUnit.Assertions;
   use Synapse.Test_Scratch;
   use type Core.Grammar_Registry.Query_Source;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   Real_Runner : Adapters.System_Process.System_Runner;
   Loader      : Dynamic_Libraries.System_Loader;

   function Registry_For
     (Entry_Json : String) return Core.Grammar_Registry.Registry is
     (Core.Grammar_Registry.Parse ("{" & Entry_Json & "}"));

   function Entry_For
     (Dir : Scratch; Extension, Name, Extra : String) return String is
     ("""" & Extension & """:{""repo"":""" & Path (Dir, Name) &
      """,""scope"":""source.x""" & Extra & "}");

   function Resolved_As
     (Dir : Scratch; Registry : Core.Grammar_Registry.Registry; Ext : String)
      return Resolution is
     (Resolve (Real_Runner, Loader, Registry, Path (Dir, "grammars"), Ext, 5));

   procedure An_Extension_With_No_Entry_Is_Not_Registered
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Assert
        (Resolved_As (Dir, Core.Grammar_Registry.Parse ("{}"), "zz").Which =
         Not_Registered,
         "no entry");
      Assert
        (not Ada.Directories.Exists (Path (Dir, "grammars")),
         "nothing is cloned or built for it");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end An_Extension_With_No_Entry_Is_Not_Registered;

   procedure An_Unsupported_Or_Incomplete_Entry_Is_Not_Usable
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch                        := Make;
      R   : constant Core.Grammar_Registry.Registry :=
        Core.Grammar_Registry.Parse
          ("{""a"":{""unsupported"":true},""b"":{""repo"":""r""}}");
   begin
      Assert (Resolved_As (Dir, R, "a").Which = Not_Usable, "marked");
      Assert (Resolved_As (Dir, R, "b").Which = Not_Usable, "no scope");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end An_Unsupported_Or_Incomplete_Entry_Is_Not_Usable;

   procedure A_Registered_Grammar_Is_Cloned_Built_And_Loaded
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Test_Grammar_Repos.Make (Path (Dir), "tree-sitter-fake3", "fake3");
      declare
         Got : constant Resolution :=
           Resolved_As
             (Dir,
              Registry_For (Entry_For (Dir, "f3", "tree-sitter-fake3", "")),
              "f3");
      begin
         Assert (Got.Which = Resolved, "resolved");
         Assert
           (Ada.Strings.Unbounded.To_String (Got.Scope) = "source.x",
            "with its scope");
         Assert
           (Got.Source = Core.Grammar_Registry.Tags, "and its query source");
         Assert
           (Ada.Directories.Exists
              (Ada.Strings.Unbounded.To_String (Got.Repo_Dir) &
               "/src/parser.c"),
            "the clone");
         Assert (not Is_Null (Got.Lang), "a language");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Registered_Grammar_Is_Cloned_Built_And_Loaded;

   procedure The_Query_Source_Of_The_Entry_Comes_Through
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Test_Grammar_Repos.Make (Path (Dir), "tree-sitter-fake3", "fake3");
      Assert
        (Resolved_As
           (Dir,
            Registry_For
              (Entry_For
                 (Dir, "f3", "tree-sitter-fake3",
                  ",""queries"":""generated""")),
            "f3")
           .Source =
         Core.Grammar_Registry.Generated,
         "generated");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Query_Source_Of_The_Entry_Comes_Through;

   procedure A_Repository_That_Cannot_Be_Cloned_Fails_With_The_Reason
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch    := Make;
      Got : constant Resolution :=
        Resolved_As
          (Dir, Registry_For (Entry_For (Dir, "f3", "tree-sitter-absent", "")),
           "f3");
   begin
      Assert (Got.Which = Failed, "failed");
      Assert
        (Ada.Strings.Fixed.Index
           (Ada.Strings.Unbounded.To_String (Got.Detail), "CLONE_FAILED") >
         0,
         "naming the step");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Repository_That_Cannot_Be_Cloned_Fails_With_The_Reason;

   procedure A_Missing_Parser_And_A_Wrong_Symbol_Both_Fail
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Ada.Directories.Create_Path (Path (Dir, "tree-sitter-empty"));
      Init_Repo (Path (Dir, "tree-sitter-empty"));
      Adapters.File_Bytes.Write (Path (Dir, "tree-sitter-empty/README"), "x");
      Git (Path (Dir, "tree-sitter-empty"), "add", "-A");
      Git (Path (Dir, "tree-sitter-empty"), "commit", "-q", "-m", "x");
      Test_Grammar_Repos.Make (Path (Dir), "tree-sitter-fake3", "fake3");
      declare
         R : constant Core.Grammar_Registry.Registry :=
           Registry_For
             (Entry_For (Dir, "e", "tree-sitter-empty", "") & "," &
              Entry_For
                (Dir, "w", "tree-sitter-fake3",
                 ",""symbol"":""tree_sitter_absent"""));
      begin
         Assert (Resolved_As (Dir, R, "e").Which = Failed, "no parser.c");
         declare
            Got : constant Resolution := Resolved_As (Dir, R, "w");
         begin
            Assert
              (Got.Which = Failed
               and then
                 Ada.Strings.Fixed.Index
                   (Ada.Strings.Unbounded.To_String (Got.Detail),
                    "SYMBOL_NOT_FOUND") >
                 0,
               "a symbol the library has not");
         end;
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Missing_Parser_And_A_Wrong_Symbol_Both_Fail;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Tree_Sitter.Resolution");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, An_Extension_With_No_Entry_Is_Not_Registered'Access,
         "An extension with no entry is not registered");
      Register_Routine
        (T, An_Unsupported_Or_Incomplete_Entry_Is_Not_Usable'Access,
         "An unsupported or incomplete entry is not usable");
      Register_Routine
        (T, A_Registered_Grammar_Is_Cloned_Built_And_Loaded'Access,
         "A registered grammar is cloned, built and loaded");
      Register_Routine
        (T, The_Query_Source_Of_The_Entry_Comes_Through'Access,
         "The query source of the entry comes through");
      Register_Routine
        (T, A_Repository_That_Cannot_Be_Cloned_Fails_With_The_Reason'Access,
         "A repository that cannot be cloned fails with the reason");
      Register_Routine
        (T, A_Missing_Parser_And_A_Wrong_Symbol_Both_Fail'Access,
         "A repository with no parser fails, and so does a wrong symbol");
   end Register_Tests;

end Synapse.Adapters.Tree_Sitter.Resolution.Tests;
