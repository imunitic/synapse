with Ada.Directories;
with Ada.Strings.Fixed;
with Synapse.Adapters.File_Bytes;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Repo;
with Synapse.Test_Vault;
with AUnit.Assertions;

package body Synapse.Commands.Graph_Wipe.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Repo;
   use Synapse.Test_Vault;

   LF : constant Character := Character'Val (10);
   HT : constant Character := ASCII.HT;

   Notes_Node : constant String :=
     "---" & LF & "title: ""Node A""" & LF & "node_type: synapse-node" & LF &
     "---" & LF & LF & "# Node A" & LF & "<!-- synapse:generated:start -->" &
     LF & "body" & LF & "<!-- synapse:generated:end -->" & LF & LF &
     "## Notes" & LF & "Hand-written thought." & LF;

   Empty_Node : constant String :=
     "---" & LF & "title: ""Node B""" & LF & "node_type: synapse-node" & LF &
     "---" & LF & LF & "# Node B" & LF & "<!-- synapse:generated:start -->" &
     LF & "body" & LF & "<!-- synapse:generated:end -->" & LF & LF &
     "## Notes" & LF;

   procedure Namespace (Dir : Scratch; Name, Branch : String) is
   begin
      Put
        (Dir, "synapse/" & Name & "/Index.md",
         "---" & LF & "title: Index" & LF &
         (if Branch = "" then "" else "branch: """ & Branch & """" & LF) &
         "---" & LF);
      Put (Dir, "synapse/" & Name & "/Node A.md", Notes_Node);
      Put (Dir, "synapse/" & Name & "/Node B.md", Empty_Node);
   end Namespace;

   function Exists (Dir : Scratch; Name : String) return Boolean is
     (Ada.Directories.Exists (Path (Dir, "vault/synapse/" & Name)));

   --  A repository on `main` with the context pinned to it and a vault.
   procedure Setup (F : aliased in out Fixture; Dir : Scratch) is
   begin
      Use_Vault (F, Dir);
      Put_File (Dir, "a.txt", "a");
      Commit_All (Dir);
      F.Vars.Set ("SYNAPSE_NAMESPACE", "widget@main");
      F.Vars.Set ("SYNAPSE_REPO_ROOT", Repo (Dir));
      F.Vars.Set ("SYNAPSE_BRANCH", "main");
   end Setup;

   --  A remote of its own whose `feature` branch was pushed and deleted
   --  again, so the checkout's tracking ref for it is gone once it fetches.
   procedure With_Remote (Dir : Scratch) is
      Remote : constant String := Path (Dir, "remote.git");
   begin
      Git (Path (Dir), "init", "-q", "--bare", "-b", "main", Remote);
      Git (Repo (Dir), "remote", "add", "origin", Remote);
      Git (Repo (Dir), "push", "-q", "-u", "origin", "main");
      Git (Repo (Dir), "checkout", "-q", "-b", "feature");
      Git (Repo (Dir), "commit", "-q", "--allow-empty", "-m", "f");
      Git (Repo (Dir), "push", "-q", "-u", "origin", "feature");
      Git (Repo (Dir), "checkout", "-q", "main");
      Git (Repo (Dir), "branch", "-q", "-D", "feature");
      Git (Remote, "branch", "-q", "-D", "feature");
   end With_Remote;

   procedure Wipe_Stages_Hand_Written_Notes_And_Removes_The_Namespace
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Namespace (Dir, "widget@main", "main");
      Namespace (Dir, "widget@other", "other");
      Assert (Run (Env (F), Args) = 0, "success: " & F.Console.Err_Text);
      Assert
        (F.Console.Out_Text =
         "at-risk" & HT & "Node A" & HT & "has hand-written ## Notes content" &
         LF &
         "namespace: synapse/widget@main (2 nodes, 1 with ## Notes content)" &
         LF & "preserved -> scratchpad/widget@main " & Character'Val (16#E2#) &
         Character'Val (16#80#) & Character'Val (16#94#) &
         " preserved notes before full rebuild.md" & LF &
         "removed synapse/widget@main" & LF,
         "the report: " & F.Console.Out_Text);
      Assert (not Exists (Dir, "widget@main"), "removed");
      Assert (Exists (Dir, "widget@other"), "the other kept");
      declare
         Staged : constant String :=
           Synapse.Adapters.File_Bytes.Read
             (Path
                (Dir,
                 "vault/scratchpad/widget@main " & Character'Val (16#E2#) &
                 Character'Val (16#80#) & Character'Val (16#94#) &
                 " preserved notes before full rebuild.md"),
              100_000);
      begin
         Assert
           (Ada.Strings.Fixed.Index
              (Staged,
               "## Node A" & LF & LF & "Hand-written thought." & LF & LF) >
            0,
            "the note: " & Staged);
         Assert
           (Ada.Strings.Fixed.Index (Staged, "Node B") = 0,
            "only the written ones");
         Assert
           (Ada.Strings.Fixed.Index (Staged, "created: """) > 0, "stamped");
      end;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Wipe_Stages_Hand_Written_Notes_And_Removes_The_Namespace;

   procedure Wipe_Of_Nothing_At_Risk_Stages_Nothing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Put
        (Dir, "synapse/widget@main/Index.md",
         "---" & LF & "title: Index" & LF & "---" & LF);
      Put (Dir, "synapse/widget@main/Node B.md", Empty_Node);
      Assert (Run (Env (F), Args) = 0, "success");
      Assert
        (F.Console.Out_Text =
         "namespace: synapse/widget@main (1 nodes, 0 with ## Notes content)" &
         LF & "removed synapse/widget@main" & LF,
         "the report: " & F.Console.Out_Text);
      Assert
        (not Ada.Directories.Exists (Path (Dir, "vault/scratchpad")),
         "nothing staged");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Wipe_Of_Nothing_At_Risk_Stages_Nothing;

   procedure Wipe_Dry_Run_Changes_Nothing (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Namespace (Dir, "widget@main", "main");
      Assert (Run (Env (F), Args ("--dry-run")) = 0, "success");
      Assert
        (Ada.Strings.Fixed.Index
           (F.Console.Out_Text, "would-remove synapse/widget@main" & LF) >
         0,
         "would: " & F.Console.Out_Text);
      Assert (Exists (Dir, "widget@main"), "still there");
      Assert
        (not Ada.Directories.Exists (Path (Dir, "vault/scratchpad")),
         "nothing staged");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Wipe_Dry_Run_Changes_Nothing;

   procedure Wipe_Of_A_Namespace_That_Is_Not_There_Fails
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert (Run (Env (F), Args) = 1, "nothing to wipe");
      Assert
        (F.Console.Err_Text =
         "synapse-graph-wipe: no namespace at synapse/widget@main -- nothing to wipe (first build? use /synapse-init)" &
         LF,
         "says so: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Wipe_Of_A_Namespace_That_Is_Not_There_Fails;

   procedure Wipe_Arguments (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Assert (Run (Env (F), Args ("x")) = 2, "unknown");
      F.Console.Clear;
      Assert (Run (Env (F), Args ("--help")) = 0, "help");
      Assert
        (F.Console.Err_Text = "usage: synapse graph-wipe [--dry-run]" & LF,
         "usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Wipe_Arguments;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Graph_Wipe");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Wipe_Stages_Hand_Written_Notes_And_Removes_The_Namespace'Access,
         "Wipe stages hand written notes and removes the namespace");
      Register_Routine
        (T, Wipe_Of_Nothing_At_Risk_Stages_Nothing'Access,
         "Wipe of nothing at risk stages nothing");
      Register_Routine
        (T, Wipe_Dry_Run_Changes_Nothing'Access,
         "Wipe dry run changes nothing");
      Register_Routine
        (T, Wipe_Of_A_Namespace_That_Is_Not_There_Fails'Access,
         "Wipe of a namespace that is not there fails");
      Register_Routine (T, Wipe_Arguments'Access, "Wipe arguments");
   end Register_Tests;

end Synapse.Commands.Graph_Wipe.Tests;
