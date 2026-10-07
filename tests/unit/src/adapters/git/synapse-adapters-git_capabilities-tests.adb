with Ada.Directories;

with AUnit.Assertions;

with Synapse.Adapters.Disk_Deleter;
with Synapse.Adapters.Disk_Renamer;
with Synapse.Adapters.File_Bytes;
with Synapse.Adapters.System_Process;
with Synapse.Test_Scratch;

package body Synapse.Adapters.Git_Capabilities.Tests is

   use AUnit.Assertions;
   use Synapse.Test_Scratch;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   procedure Renaming_And_Deleting_Commit (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir   : constant Scratch := Make;
      Vault : constant String := Path (Dir, "vault");
      Run   : aliased System_Process.System_Runner;
      Mover : aliased Disk_Renamer.Disk_Renamer := Disk_Renamer.Create (Vault);
      Gone  : aliased Disk_Deleter.Disk_Deleter := Disk_Deleter.Create (Vault);
   begin
      Init_Repo (Vault);
      File_Bytes.Write (Vault & "/A.md", "[[B]]");
      File_Bytes.Write (Vault & "/B.md", "b");
      Git (Vault, "add", "-A");
      Git (Vault, "commit", "-q", "-m", "seed");
      Assert (Commit_Count (Vault) = 1, "seeded");

      declare
         R : Git_Renamer := Create (Mover'Access, Run'Access, Vault);
      begin
         R.Rename ("B.md", "C.md");
      end;
      Assert (Commit_Count (Vault) = 2, "the rename is committed");
      --  Git reports a rename as the new name alone.
      Assert (Head_Subject (Vault) = "vault: A.md, C.md",
              "naming what changed: " & Head_Subject (Vault));
      Assert (Git (Vault, "status", "--porcelain") = "", "nothing left dirty");

      declare
         D : Git_Deleter := Create (Gone'Access, Run'Access, Vault);
      begin
         D.Delete ("C.md");
      end;
      Assert (Commit_Count (Vault) = 3, "the delete is committed");
      Assert (Git (Vault, "status", "--porcelain") = "", "clean again");
      Assert (not Ada.Directories.Exists (Vault & "/C.md"), "and gone");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Renaming_And_Deleting_Commit;

   procedure A_Lock_Held_Elsewhere_Skips_The_Commit
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir   : constant Scratch := Make;
      Vault : constant String := Path (Dir, "vault");
      Run   : aliased System_Process.System_Runner;
      Mover : aliased Disk_Renamer.Disk_Renamer := Disk_Renamer.Create (Vault);
   begin
      Init_Repo (Vault);
      File_Bytes.Write (Vault & "/A.md", "a");
      Git (Vault, "add", "-A");
      Git (Vault, "commit", "-q", "-m", "seed");
      Ada.Directories.Create_Directory (Vault & "/.git/synapse-sync.lock");
      declare
         R : Git_Renamer := Create (Mover'Access, Run'Access, Vault);
      begin
         R.Rename ("A.md", "B.md");
      end;
      Assert (Ada.Directories.Exists (Vault & "/B.md"), "the move happened");
      Assert (Commit_Count (Vault) = 1, "but is not committed");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Lock_Held_Elsewhere_Skips_The_Commit;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Git_Capabilities");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Renaming_And_Deleting_Commit'Access,
         "Renaming and deleting commit");
      Register_Routine
        (T, A_Lock_Held_Elsewhere_Skips_The_Commit'Access,
         "A lock held elsewhere skips the commit");
   end Register_Tests;

end Synapse.Adapters.Git_Capabilities.Tests;
