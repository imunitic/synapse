with GNAT.OS_Lib;
with Ada.Directories;
with Ada.Strings.Fixed;
with Synapse.Adapters.File_Bytes;
with Synapse.Test_Environment;
with Synapse.Test_Scratch;
with Synapse.Test_Repo;
with Synapse.Test_Vault;
with AUnit.Assertions;

package body Synapse.Commands.Doctor.Tests is

   use AUnit.Assertions;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   use Synapse.Test_Environment;
   use Synapse.Test_Scratch;
   use Synapse.Test_Repo;
   use Synapse.Test_Vault;

   LF : constant Character := Character'Val (10);

   Remote : constant String := "https://example.com/o/widget.git";

   function Report (F : Fixture) return String is (F.Console.Out_Text);

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   --  A configured machine: a conf naming the vault, a checkout on `main`
   --  with a remote, and a namespace that agrees with it.
   procedure Setup (F : aliased in out Fixture; Dir : Scratch) is
   begin
      Use_Vault (F, Dir);
      F.Vars.Set ("SYNAPSE_WORK_DIR", Path (Dir, "work"));
      Put_Config
        (Dir, "synapse.conf",
         "SYNAPSE_VAULT_DIR=""" & Path (Dir, "vault") & """" & LF);
      Put_File (Dir, "a.txt", "a");
      Commit_All (Dir);
      Git (Repo (Dir), "remote", "add", "origin", Remote);
      Put
        (Dir, "synapse/widget@main/Index.md",
         "---" & LF & "title: Index" & LF & "remote: """ & Remote & """" & LF &
         "branch: ""main""" & LF & "---" & LF);
      Put (Dir, "synapse/widget@main/Node A.md", "x");
      Put (Dir, "synapse/widget@main/Node B.md", "x");
   end Setup;

   procedure Doctor_Passes_A_Configured_Machine (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Put_Config
        (Dir, "settings.json",
         "synapse-hook session-start synapse-hook prompt-context " &
         "synapse-hook staleness synapse-hook stop-nudge");
      Assert
        (Run (Env (F), Args ("--repo", Repo (Dir))) = 0,
         "success: " & Report (F));
      Assert
        (Has
           (Report (F),
            "ok    config         " & Path (Dir, "home/.claude/synapse.conf") &
            LF),
         "config: " & Report (F));
      Assert
        (Has (Report (F), "ok    vault          " & Path (Dir, "vault") & LF),
         "vault");
      Assert
        (Has (Report (F), "ok    remote         " & Remote & LF), "remote");
      Assert
        (Has (Report (F), "ok    namespace      widget@main" & LF),
         "namespace");
      Assert
        (Has
           (Report (F),
            "ok    graph          synapse/widget@main/ (2 nodes)" & LF),
         "graph");
      Assert
        (Has
           (Report (F), "ok    hooks          all four registered once" & LF),
         "hooks");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Doctor_Passes_A_Configured_Machine;

   procedure Doctor_Names_The_Missing_Artefacts_Of_A_Fresh_Checkout
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Assert
        (Run (Env (F), Args ("--repo", Repo (Dir))) = 1,
         "no hooks is a failure");
      Assert
        (Has (Report (F), "warn  work dir       " & Path (Dir, "work") & LF),
         "work dir: " & Report (F));
      Assert
        (Has
           (Report (F),
            "warn  reverse index  absent -- the staleness hook does nothing without it" &
            LF),
         "index");
      Assert
        (Has
           (Report (F),
            "warn  tags cache     absent -- `query symbol` will tag on demand, slowly" &
            LF),
         "tags");
      Assert
        (Has
           (Report (F),
            "warn  code cache     absent -- `callers` exits 1 until `build-refs` runs" &
            LF),
         "refs");
      Assert
        (Has
           (Report (F),
            "FAIL  hooks          no settings.json -- run `synapse-setup configure claude`" &
            LF),
         "hooks");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Doctor_Names_The_Missing_Artefacts_Of_A_Fresh_Checkout;

   procedure Doctor_Finds_The_Derived_Files (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Ada.Directories.Create_Path (Path (Dir, "work"));
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "work/_tags_cache.bin"), "x");
      Synapse.Adapters.File_Bytes.Write (Path (Dir, "work/_refs.tsv"), "x");
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "work/_index.bin"), "junk");
      Assert
        (Run (Env (F), Args ("--repo", Repo (Dir))) = 1,
         "a damaged index fails");
      Assert
        (Has (Report (F), "ok    work dir       " & Path (Dir, "work") & LF),
         "work dir");
      Assert
        (Has
           (Report (F),
            "ok    tags cache     " & Path (Dir, "work/_tags_cache.bin") & LF),
         "tags");
      Assert
        (Has
           (Report (F),
            "ok    code cache     " & Path (Dir, "work/_refs.tsv") & LF),
         "refs");
      Assert
        (Has (Report (F), "FAIL  reverse index  discarded ("),
         "index: " & Report (F));
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Doctor_Finds_The_Derived_Files;

   procedure Doctor_Tells_A_Namespace_That_Disagrees
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Put
        (Dir, "synapse/widget@main/Index.md",
         "---" & LF & "remote: ""https://example.com/o/other.git""" & LF &
         "branch: ""main""" & LF & "---" & LF);
      Assert
        (Run (Env (F), Args ("--repo", Repo (Dir))) = 1, "remote mismatch");
      Assert
        (Has
           (Report (F),
            "FAIL  graph          remote mismatch: Index.md says https://example.com/o/other.git -- rebuild with /synapse-rebuild-full if the remote changed" &
            LF),
         "remote: " & Report (F));
      F.Console.Clear;
      Put
        (Dir, "synapse/widget@main/Index.md",
         "---" & LF & "remote: """ & Remote & """" & LF & "branch: ""dev""" &
         LF & "---" & LF);
      Assert
        (Run (Env (F), Args ("--repo", Repo (Dir))) = 1, "branch mismatch");
      Assert
        (Has
           (Report (F),
            "FAIL  graph          branch mismatch: Index.md says dev, this is main -- the directory was renamed by hand" &
            LF),
         "branch: " & Report (F));
      F.Console.Clear;
      Put
        (Dir, "synapse/widget@main/Index.md",
         "---" & LF & "branch: ""main""" & LF & "---" & LF);
      Assert
        (Run (Env (F), Args ("--repo", Repo (Dir))) = 1, "no remote field");
      Assert
        (Has
           (Report (F),
            "FAIL  graph          Index.md has no remote field -- every component reads that as a mismatch" &
            LF),
         "no remote: " & Report (F));
      F.Console.Clear;
      Ada.Directories.Delete_Tree (Path (Dir, "vault/synapse/widget@main"));
      Assert (Run (Env (F), Args ("--repo", Repo (Dir))) = 1, "no namespace");
      Assert
        (Has
           (Report (F),
            "warn  graph          no namespace at synapse/widget@main/ -- /synapse-init builds one" &
            LF),
         "absent: " & Report (F));
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Doctor_Tells_A_Namespace_That_Disagrees;

   procedure Doctor_Says_What_Is_Wrong_With_The_Configuration
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      --  A repository of its own: a plain directory would be read as part of
      --  whatever checkout the tests run in.
      Put_File (Dir, "a.txt", "a");
      Commit_All (Dir);
      Assert (Run (Env (F), Args ("--repo", Repo (Dir))) = 1, "failures");
      Assert
        (Has
           (Report (F),
            "warn  config         no synapse.conf; using $SYNAPSE_VAULT_DIR" &
            LF)
         or else Has (Report (F), "FAIL  config"),
         "config: " & Report (F));
      F.Console.Clear;
      F.Vars.Set ("SYNAPSE_VAULT_DIR", "");
      F.Vars.Set ("HOME", Path (Dir, "empty-home"));
      Assert (Run (Env (F), Args ("--repo", Repo (Dir))) = 1, "no vault");
      Assert
        (Has
           (Report (F),
            "FAIL  vault          SYNAPSE_VAULT_DIR is not set anywhere" & LF),
         "vault: " & Report (F));
      F.Console.Clear;
      F.Vars.Set ("SYNAPSE_VAULT_DIR", Path (Dir, "nowhere"));
      Assert (Run (Env (F), Args ("--repo", Repo (Dir))) = 1, "vault gone");
      Assert
        (Has
           (Report (F),
            "FAIL  vault          " & Path (Dir, "nowhere") &
            " does not exist" & LF),
         "missing: " & Report (F));
      F.Console.Clear;
      Synapse.Adapters.File_Bytes.Write (Path (Dir, "afile"), "x");
      F.Vars.Set ("SYNAPSE_VAULT_DIR", Path (Dir, "afile"));
      Assert (Run (Env (F), Args ("--repo", Repo (Dir))) = 1, "vault a file");
      Assert
        (Has
           (Report (F),
            "FAIL  vault          " & Path (Dir, "afile") &
            " is not a directory" & LF),
         "file: " & Report (F));
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Doctor_Says_What_Is_Wrong_With_The_Configuration;

   procedure Doctor_Outside_A_Repository_Warns (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make_Outside_Git;
      F   : aliased Fixture;
   begin
      Use_Vault (F, Dir);
      Assert
        (Run (Env (F), Args ("--repo", Path (Dir))) = 1, "the rest fails");
      Assert
        (Has
           (Report (F), "not inside a git repo -- nothing to graph here" & LF),
         "outside: " & Report (F));
      Assert (not Has (Report (F), "namespace"), "no namespace line");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Doctor_Outside_A_Repository_Warns;

   procedure Doctor_On_A_Detached_Head_Warns (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Git (Repo (Dir), "checkout", "-q", "--detach");
      Assert
        (Run (Env (F), Args ("--repo", Repo (Dir))) = 1, "the rest fails");
      Assert
        (Has
           (Report (F),
            "detached HEAD -- a namespace is keyed by branch, so there is none" &
            LF),
         "detached: " & Report (F));
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Doctor_On_A_Detached_Head_Warns;

   procedure Doctor_Counts_The_Hooks_Registered (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Put_Config (Dir, "settings.json", "synapse-hook staleness");
      Assert (Run (Env (F), Args ("--repo", Repo (Dir))) = 1, "three missing");
      Assert
        (Has
           (Report (F),
            "FAIL  hooks          3 of 4 not registered -- run `synapse-setup configure claude`" &
            LF),
         "missing: " & Report (F));
      F.Console.Clear;
      Put_Config
        (Dir, "settings.json",
         "synapse-hook session-start synapse-hook session-start synapse-hook prompt-context " &
         "synapse-hook staleness synapse-hook stop-nudge");
      Assert (Run (Env (F), Args ("--repo", Repo (Dir))) = 1, "one twice");
      Assert
        (Has
           (Report (F),
            "FAIL  hooks          1 registered more than once -- each fires that many times; fix ~/.claude/settings.json or re-run `synapse-setup configure claude`" &
            LF),
         "twice: " & Report (F));
      F.Console.Clear;
      Put_Config
        (Dir, "settings.json",
         "hooks/synapse-x.sh synapse-hook session-start synapse-hook prompt-context " &
         "synapse-hook staleness synapse-hook stop-nudge");
      Assert (Run (Env (F), Args ("--repo", Repo (Dir))) = 1, "a wrapper");
      Assert
        (Has
           (Report (F), "ok    hooks          all four registered once" & LF),
         "still counted");
      Assert
        (Has
           (Report (F),
            "FAIL  hook wiring    settings.json still names a hooks/*.sh wrapper -- fix ~/.claude/settings.json or re-run `synapse-setup configure claude`" &
            LF),
         "wrapper: " & Report (F));
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Doctor_Counts_The_Hooks_Registered;

   procedure Doctor_Reports_Grammar_Locks (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      F.Vars.Set ("SYNAPSE_GRAMMARS_DIR", Path (Dir, "grammars"));
      Ada.Directories.Create_Path (Path (Dir, "grammars/repos"));
      Assert (Run (Env (F), Args ("--repo", Repo (Dir))) = 1, "no locks");
      Assert
        (not Has (Report (F), "grammar locks"), "silent when there are none");
      F.Console.Clear;
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, "grammars/repos/a.lock"), "");
      Assert (Run (Env (F), Args ("--repo", Repo (Dir))) = 1, "a fresh lock");
      Assert
        (Has
           (Report (F),
            "1 held (" & Path (Dir, "grammars/repos/a.lock") &
            ") -- another synapse is cloning, or one was killed just now; delete it if nothing is running" &
            LF),
         "held: " & Report (F));
      F.Console.Clear;
      GNAT.OS_Lib.Set_File_Last_Modify_Time_Stamp
        (Path (Dir, "grammars/repos/a.lock"),
         GNAT.OS_Lib.GM_Time_Of (2_020, 1, 1, 0, 0, 0));
      Assert (Run (Env (F), Args ("--repo", Repo (Dir))) = 1, "an old lock");
      Assert
        (Has (Report (F), "ok    grammar locks 1 abandoned (")
         or else Has (Report (F), "grammar locks  1 abandoned ("),
         "abandoned: " & Report (F));
      Assert
        (Has
           (Report (F),
            ") -- older than the staleness window, so the next run takes it over" &
            LF),
         "and why");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Doctor_Reports_Grammar_Locks;

   procedure Doctor_Names_The_Git_Directory_Of_A_Worktree
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Setup (F, Dir);
      Git
        (Repo (Dir), "worktree", "add", "-q", Path (Dir, "wt"), "-b", "feat");
      Assert (Run (Env (F), Args ("--repo", Path (Dir, "wt"))) = 1, "run");
      Assert (Has (Report (F), "ok    worktree"), "worktree: " & Report (F));
      Assert
        (Has (Report (F), " (shared: " & Path (Dir, "repo/.git") & ")" & LF),
         "shared: " & Report (F));
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Doctor_Names_The_Git_Directory_Of_A_Worktree;

   procedure Doctor_Arguments (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
      F   : aliased Fixture;
   begin
      Assert (Run (Env (F), Args ("--wat")) = 2, "unknown");
      Assert (Run (Env (F), Args ("--repo")) = 2, "dangling");
      F.Console.Clear;
      Assert (Run (Env (F), Args ("-h")) = 0, "help");
      Assert
        (Has (F.Console.Err_Text, "usage: synapse doctor [--repo <dir>]"),
         "usage");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Doctor_Arguments;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Commands.Doctor");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Doctor_Passes_A_Configured_Machine'Access,
         "Doctor passes a configured machine");
      Register_Routine
        (T, Doctor_Names_The_Missing_Artefacts_Of_A_Fresh_Checkout'Access,
         "Doctor names the missing artefacts of a fresh checkout");
      Register_Routine
        (T, Doctor_Finds_The_Derived_Files'Access,
         "Doctor finds the derived files");
      Register_Routine
        (T, Doctor_Tells_A_Namespace_That_Disagrees'Access,
         "Doctor tells a namespace that disagrees");
      Register_Routine
        (T, Doctor_Says_What_Is_Wrong_With_The_Configuration'Access,
         "Doctor says what is wrong with the configuration");
      Register_Routine
        (T, Doctor_Outside_A_Repository_Warns'Access,
         "Doctor outside a repository warns");
      Register_Routine
        (T, Doctor_On_A_Detached_Head_Warns'Access,
         "Doctor on a detached head warns");
      Register_Routine
        (T, Doctor_Counts_The_Hooks_Registered'Access,
         "Doctor counts the hooks registered");
      Register_Routine
        (T, Doctor_Reports_Grammar_Locks'Access,
         "Doctor reports grammar locks");
      Register_Routine
        (T, Doctor_Names_The_Git_Directory_Of_A_Worktree'Access,
         "Doctor names the git directory of a worktree");
      Register_Routine (T, Doctor_Arguments'Access, "Doctor arguments");
   end Register_Tests;

end Synapse.Commands.Doctor.Tests;
