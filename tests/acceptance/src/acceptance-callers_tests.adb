with Ada.Strings.Unbounded;

with Acceptance.Fixtures;

package body Acceptance.Callers_Tests is

   use Acceptance.Fixtures;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);
   HT : constant Character := ASCII.HT;

   Hash : constant String := "1111111111111111111111111111111111111111";

   --  One `def` tag for `doThing`, in the exact `--dump` and `--load` format.
   Dump : constant String :=
     "H" & HT & "src/A.bb" & HT & Hash & LF & "T" & HT & "src/A.bb" & HT &
     "doThing   " & HT & " | method " & HT &
     "def (10, 13) - (10, 39) `public void doThing() {`" & LF;

   --  The tags cache and the reference index built from it, in Dir.
   procedure Seed_Index (F : Fixture; Dir : String) is
      Cache : constant String := Dir & "/_tags_cache.bin";
   begin
      Make_Dir (Dir);
      Assert_Exit
        (Run_Fake_Stdin (F, Dump, "tags-cache", "--load", Cache), 0,
         "tags-cache --load");
      Assert_Exit
        (Run_Fake
           (F, "build-refs", "--cache", Cache, "--out", Dir & "/_refs.tsv"),
         0, "build-refs");
   end Seed_Index;

   procedure Callers_Needs_No_Vault_Namespace_Or_Nodes
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Make_Repo (F, "ssh://git@example.invalid/x/repo.git");
      Set_Env (F, "SYNAPSE_WORK_DIR", Work (F));
      Seed_Index (F, Work (F));

      --  No vault is configured, and no vault directory exists.
      Unset_Env (F, "SYNAPSE_VAULT_DIR");
      Delete_Tree (Vault (F));
      Assert_Exit (Run_Fake (F, "callers", "doThing"), 0, "callers");
   end Callers_Needs_No_Vault_Namespace_Or_Nodes;

   procedure Namespace_Reads_Another_Index_Directly
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F     : Fixture;
      Other : constant String := "other-repo@main";
   begin
      Seed_Index (F, Home (F) & "/.cache/synapse/work/" & Other);

      --  No vault, and the repository (the default working directory) is
      --  never made a git repository: `--namespace` addresses the other
      --  namespace's index and nothing about the working directory's own
      --  identity is consulted.
      Unset_Env (F, "SYNAPSE_VAULT_DIR");

      --  `--all`, not the default view of calls: the seeded tag is a `def`,
      --  which the default view never reports.
      declare
         R : constant Result :=
           Run_Fake (F, "callers", "--namespace", Other, "--all", "doThing");
      begin
         Assert_Exit (R, 0, "callers --namespace");
         Assert_Contains (To_String (R.Output), "src/A.bb:10", "the site");
      end;
   end Namespace_Reads_Another_Index_Directly;

   procedure Refs_With_Namespace_Is_A_Usage_Error (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Unset_Env (F, "SYNAPSE_VAULT_DIR");
      Assert_Exit
        (Run_Fake
           (F, "callers", "doThing", "--refs", "/nonexistent/_refs.tsv",
            "--namespace", "other-repo@main"),
         2, "--refs with --namespace");
   end Refs_With_Namespace_Is_A_Usage_Error;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Acceptance: callers");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Callers_Needs_No_Vault_Namespace_Or_Nodes'Access,
         "callers: needs no vault, no namespace and no nodes");
      Register_Routine
        (T, Namespace_Reads_Another_Index_Directly'Access,
         "callers --namespace reads another checkout's index directly");
      Register_Routine
        (T, Refs_With_Namespace_Is_A_Usage_Error'Access,
         "callers: --refs with --namespace is a usage error");
   end Register_Tests;

end Acceptance.Callers_Tests;
