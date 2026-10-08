with Ada.Strings.Unbounded;

with Acceptance.Fixtures;

package body Acceptance.Cli_Usage_Tests is

   use Acceptance.Fixtures;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure Brief_Usage_Errors (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Assert_Exit (Run_Fake (F, "brief"), 2, "brief");
      Assert_Exit (Run_Fake (F, "brief", "--nope"), 2, "brief --nope");
   end Brief_Usage_Errors;

   procedure Build_Refs_Help_And_Bad_Flag (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Assert_Exit (Run_Fake (F, "build-refs", "--help"), 0, "--help");
      Assert_Exit (Run_Fake (F, "build-refs", "--nonsense"), 2, "bad flag");
   end Build_Refs_Help_And_Bad_Flag;

   procedure Doctor_Help_Needs_No_Environment (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Keep_Only_Path (F);
      declare
         R : constant Result :=
           Run (F, Synapse_Bin, Args ("doctor", "--help"), Root (F));
      begin
         Assert_Exit (R, 0, "doctor --help");
         Assert_Contains (Both (R), "usage: synapse doctor", "usage");
      end;
   end Doctor_Help_Needs_No_Environment;

   procedure Gate_Usage_Errors (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Write_Repo_File (F, "groupwords.tsv", "");
      declare
         Vocab : constant String := Repo (F) & "/groupwords.tsv";
      begin
         Assert_Exit (Run_Fake (F, "gate"), 2, "no arguments");
         Assert_Exit
           (Run_Fake (F, "gate", "--vocab", Vocab, "--top", "zero"), 2,
            "--top zero");
         Assert_Exit (Run_Fake (F, "gate", "--nope"), 2, "bad flag");
      end;
   end Gate_Usage_Errors;

   procedure Graph_Clean_Outside_A_Repo (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Assert_Exit
        (Run_Synapse_Outside_Repo (F, "graph-clean"), 1, "outside a repo");
      Make_Repo (F);
      Assert_Exit (Run_Fake (F, "graph-clean", "--bogus"), 2, "unknown flag");
   end Graph_Clean_Outside_A_Repo;

   procedure Link_Graph_Usage_Errors (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Write_Repo_File (F, "_refs.tsv", "");
      Write_Repo_File (F, "lists/.keep", "");
      declare
         Lists : constant String := Repo (F) & "/lists";
      begin
         Assert_Exit (Run_Fake (F, "link-graph"), 2, "no arguments");
         Assert_Exit
           (Run_Fake (F, "link-graph", "--lists", Lists, "--top", "bogus"), 2,
            "--top bogus");
         Assert_Exit (Run_Fake (F, "link-graph", "--nope"), 2, "bad flag");
      end;
   end Link_Graph_Usage_Errors;

   procedure Rank_Usage_Errors (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Make_Repo (F);
      Write_Repo_File (F, "sources.txt", "");
      declare
         Src       : constant String := Repo (F) & "/sources.txt";
         Out_Dir   : constant String := Repo (F) & "/out";
         Out_Lists : constant String := Out_Dir & "/lists";
      begin
         Assert_Exit (Run_Fake (F, "rank"), 2, "no arguments");
         Assert_Exit
           (Run_Fake (F, "rank", "--sources", Src, "--tier", "bogus"), 2,
            "--tier bogus");
         --  --lists and --sources pick two input modes: giving both is a
         --  usage error and not a silent pick of one.
         Assert_Exit
           (Run_Fake
              (F, "rank", "--sources", Src, "--lists", Out_Lists, "--repo",
               Repo (F), "--out", Out_Dir),
            2, "--sources with --lists");
         --  --pool and --tier select one pool or tier of a single stream;
         --  --lists writes both pools per node, so either is a usage error.
         Assert_Exit
           (Run_Fake
              (F, "rank", "--lists", Out_Lists, "--repo", Repo (F), "--out",
               Out_Dir, "--pool", "crux"),
            2, "--lists with --pool");
         Assert_Exit
           (Run_Fake
              (F, "rank", "--lists", Out_Lists, "--repo", Repo (F), "--out",
               Out_Dir, "--tier", "code"),
            2, "--lists with --tier");
      end;
   end Rank_Usage_Errors;

   --  A subcommand missing from the dispatch table falls through to
   --  "unknown subcommand", exit 2: the same code a bad flag gives. Only help
   --  exits 0, and only once dispatch reaches the command itself.
   procedure Vault_Commands_Are_Reachable (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;

      procedure Reaches (Command : String) is
         R : constant Result := Run_Fake (F, Command, "--help");
      begin
         Assert_Exit (R, 0, Command & " --help");
         Assert_Lacks (Both (R), "unknown subcommand", Command);
      end Reaches;
   begin
      Reaches ("vault-check");
      Reaches ("vault-ambiguous");
      Reaches ("vault-rename");
   end Vault_Commands_Are_Reachable;

   procedure Tags_Cache_Without_Arguments (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Make_Repo (F);
      Assert_Exit
        (Run_Fake (F, "tags-cache", "--repo-root", Repo (F)), 2,
         "missing --cache and --paths");
   end Tags_Cache_Without_Arguments;

   procedure Callers_Without_A_Name (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fixture;
      R : constant Result := Run_Fake (F, "callers");
   begin
      Assert_Exit (R, 2, "callers");
      Assert_Contains
        (To_String (R.Errors), "`synapse callers <name> --all`",
         "the question-to-command entries");
   end Callers_Without_A_Name;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Acceptance: usage and exit codes");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Brief_Usage_Errors'Access, "brief: usage and environment errors");
      Register_Routine
        (T, Build_Refs_Help_And_Bad_Flag'Access,
         "build-refs: --help is exit 0, a bad flag is exit 2");
      Register_Routine
        (T, Doctor_Help_Needs_No_Environment'Access,
         "doctor: --help works outside a repo with no environment");
      Register_Routine
        (T, Gate_Usage_Errors'Access, "gate: usage errors exit 2");
      Register_Routine
        (T, Graph_Clean_Outside_A_Repo'Access,
         "graph-clean: outside a repo exits 1, an unknown flag exits 2");
      Register_Routine
        (T, Link_Graph_Usage_Errors'Access, "link-graph: usage errors");
      Register_Routine (T, Rank_Usage_Errors'Access, "rank: usage errors");
      Register_Routine
        (T, Vault_Commands_Are_Reachable'Access,
         "vault-check, vault-ambiguous, vault-rename are reachable");
      Register_Routine
        (T, Tags_Cache_Without_Arguments'Access,
         "tags-cache: missing arguments is exit 2");
      Register_Routine
        (T, Callers_Without_A_Name'Access,
         "callers with no name exits 2 and prints the map entries");
   end Register_Tests;

end Acceptance.Cli_Usage_Tests;
