with Ada.Strings.Unbounded;

with Acceptance.Fixtures;

package body Acceptance.Index_Namespace_Tests is

   use Acceptance.Fixtures;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   Other : constant String := "other-repo@main";

   --  Another namespace's index, with one path in one node. No vault is
   --  configured and the repository is never made a git repository.
   procedure Seed_Other (F : in out Fixture) is
   begin
      Make_Dir (Home (F) & "/.cache/synapse/work/" & Other);
      Write_Index_Bin
        (F, Home (F) & "/.cache/synapse/work/" & Other,
         "src/Foo.java" & ASCII.HT & "Foo concept.md" & LF);
      Unset_Env (F, "SYNAPSE_VAULT_DIR");
   end Seed_Other;

   procedure Lookup_Reads_Another_Checkouts_Index (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Seed_Other (F);
      declare
         R : constant Result :=
           Run_Fake
             (F, "index", "lookup", "src/Foo.java", "--namespace", Other);
      begin
         Assert_Exit (R, 0, "index lookup");
         Assert_Contains (To_String (R.Output), "Foo concept", "the node");
      end;
   end Lookup_Reads_Another_Checkouts_Index;

   procedure Every_Read_Form_Resolves_The_Same_Index
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Seed_Other (F);
      declare
         Nodes      : constant Result :=
           Run_Fake (F, "index", "nodes", "--namespace", Other);
         Paths      : constant Result :=
           Run_Fake (F, "index", "paths", "--namespace", Other);
         Unassigned : constant Result :=
           Run_Fake (F, "index", "unassigned", "--namespace", Other);
      begin
         Assert_Exit (Nodes, 0, "index nodes");
         Assert_Contains (To_String (Nodes.Output), "Foo concept", "nodes");
         Assert_Exit (Paths, 0, "index paths");
         Assert_Contains (To_String (Paths.Output), "src/Foo.java", "paths");
         Assert_Exit (Unassigned, 0, "index unassigned");
         Assert_Equal (To_String (Unassigned.Output), "", "unassigned");
      end;
   end Every_Read_Form_Resolves_The_Same_Index;

   procedure Build_With_A_Namespace_Is_A_Usage_Error
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Unset_Env (F, "SYNAPSE_VAULT_DIR");
      Assert_Exit
        (Run_Fake
           (F, "index", "build", "--unassigned", "/nonexistent/unassigned.txt",
            "--namespace", Other),
         2, "--namespace is read-only");
   end Build_With_A_Namespace_Is_A_Usage_Error;

   procedure File_With_Namespace_Is_A_Usage_Error (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fixture;
   begin
      Unset_Env (F, "SYNAPSE_VAULT_DIR");
      Assert_Exit
        (Run_Fake
           (F, "index", "lookup", "src/Foo.java", "--file",
            "/nonexistent/_index.bin", "--namespace", Other),
         2, "--file with --namespace");
   end File_With_Namespace_Is_A_Usage_Error;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Acceptance: index --namespace");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Lookup_Reads_Another_Checkouts_Index'Access,
         "index lookup --namespace reads another checkout's index");
      Register_Routine
        (T, Every_Read_Form_Resolves_The_Same_Index'Access,
         "unassigned, nodes and paths resolve the same other index");
      Register_Routine
        (T, Build_With_A_Namespace_Is_A_Usage_Error'Access,
         "index build --namespace is a usage error");
      Register_Routine
        (T, File_With_Namespace_Is_A_Usage_Error'Access,
         "index lookup --file with --namespace is a usage error");
   end Register_Tests;

end Acceptance.Index_Namespace_Tests;
