with Ada.Directories;
with Ada.Strings.Fixed;
with Synapse.Adapters.File_Bytes;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Repo;
with Synapse.Test_Vault;
with AUnit.Assertions;

package body Synapse.Commands.Graph_Clean.Tests is

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

   procedure Clean_Keeps_What_Is_Alive_And_Reports_What_It_Cannot_Tell
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Namespace (Dir, "widget@main", "main");
      Namespace (Dir, "widget@gone", "gone-branch");
      Namespace (Dir, "widget@nobranch", "");
      Namespace (Dir, "other@main", "main");
      Assert (Run (Env (F), Args) = 0, "success: " & F.Console.Err_Text);
      Assert
        (F.Console.Out_Text =
         "report" & HT & "widget@gone" & HT &
         "branch gone-branch is gone and the repo has no remote" & LF &
         "report" & HT & "widget@nobranch" & HT &
         "no branch field -- cannot tell which branch it describes" & LF,
         "the reports: " & F.Console.Out_Text);
      Assert
        (Exists (Dir, "widget@main") and then Exists (Dir, "widget@gone")
         and then Exists (Dir, "other@main"),
         "nothing removed");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Clean_Keeps_What_Is_Alive_And_Reports_What_It_Cannot_Tell;

   procedure Clean_Says_When_There_Is_Nothing_To_Do
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Namespace (Dir, "widget@main", "main");
      Assert (Run (Env (F), Args) = 0, "success");
      Assert
        (F.Console.Out_Text = "nothing to clean" & LF,
         "said so: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Clean_Says_When_There_Is_Nothing_To_Do;

   procedure Clean_Removes_A_Namespace_Whose_Upstream_Is_Gone
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      With_Remote (Dir);
      Namespace (Dir, "widget@main", "main");
      Namespace (Dir, "widget@feature", "feature");
      Git (Repo (Dir), "config", "branch.feature.remote", "origin");
      Git (Repo (Dir), "config", "branch.feature.merge", "refs/heads/feature");
      Assert (Run (Env (F), Args ("--dry-run")) = 0, "dry run");
      Assert
        (F.Console.Out_Text = "nothing to clean" & LF,
         "a dry run does not fetch, so the stale tracking ref stands: " &
         F.Console.Out_Text);
      F.Console.Clear;
      Git (Repo (Dir), "fetch", "-q", "--prune");
      Assert
        (Run (Env (F), Args ("--dry-run")) = 0, "dry run after the fetch");
      Assert
        (F.Console.Out_Text =
         "would-remove" & HT & "widget@feature" & HT &
         "upstream origin/feature is gone" & LF,
         "would: " & F.Console.Out_Text);
      Assert (Exists (Dir, "widget@feature"), "kept by a dry run");
      F.Console.Clear;
      Assert (Run (Env (F), Args) = 0, "clean");
      Assert
        (F.Console.Out_Text =
         "removed" & HT & "widget@feature" & HT &
         "upstream origin/feature is gone" & LF,
         "removed: " & F.Console.Out_Text);
      Assert (not Exists (Dir, "widget@feature"), "gone");
      Assert (Exists (Dir, "widget@main"), "the other kept");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Clean_Removes_A_Namespace_Whose_Upstream_Is_Gone;

   procedure Clean_Fetches_Before_It_Decides (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      With_Remote (Dir);
      Namespace (Dir, "widget@feature", "feature");
      Git (Repo (Dir), "config", "branch.feature.remote", "origin");
      Git (Repo (Dir), "config", "branch.feature.merge", "refs/heads/feature");
      Assert (Run (Env (F), Args) = 0, "clean");
      Assert
        (F.Console.Out_Text =
         "removed" & HT & "widget@feature" & HT &
         "upstream origin/feature is gone" & LF,
         "the prune made the upstream look gone: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Clean_Fetches_Before_It_Decides;

   procedure Clean_Arguments (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Assert (Run (Env (F), Args ("--wat")) = 2, "unknown");
      F.Console.Clear;
      Assert (Run (Env (F), Args ("-h")) = 0, "help");
      Assert
        (F.Console.Err_Text = "usage: synapse graph-clean [--dry-run]" & LF,
         "usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Clean_Arguments;

   procedure Clean_Needs_A_Vault (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      F.Vars.Set ("HOME", Path (Dir, "home"));
      F.Vars.Set ("SYNAPSE_NAMESPACE", "widget@main");
      F.Vars.Set ("SYNAPSE_REPO_ROOT", Path (Dir));
      F.Vars.Set ("SYNAPSE_BRANCH", "main");
      Assert (Run (Env (F), Args) = 1, "no vault");
      Assert
        (F.Console.Err_Text = "synapse-graph-clean: no vault" & LF,
         "says so: " & F.Console.Err_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Clean_Needs_A_Vault;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Graph_Clean");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Clean_Keeps_What_Is_Alive_And_Reports_What_It_Cannot_Tell'Access,
         "Clean keeps what is alive and reports what it cannot tell");
      Register_Routine
        (T, Clean_Says_When_There_Is_Nothing_To_Do'Access,
         "Clean says when there is nothing to do");
      Register_Routine
        (T, Clean_Removes_A_Namespace_Whose_Upstream_Is_Gone'Access,
         "Clean removes a namespace whose upstream is gone");
      Register_Routine
        (T, Clean_Fetches_Before_It_Decides'Access,
         "Clean fetches before it decides");
      Register_Routine (T, Clean_Arguments'Access, "Clean arguments");
      Register_Routine (T, Clean_Needs_A_Vault'Access, "Clean needs a vault");
   end Register_Tests;

end Synapse.Commands.Graph_Clean.Tests;
