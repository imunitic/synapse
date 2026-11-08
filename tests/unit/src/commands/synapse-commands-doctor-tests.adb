with GNAT.OS_Lib;
with Ada.Directories;
with Ada.Strings.Fixed;
with Synapse.Adapters.File_Bytes;
with Synapse.Core.JSON;
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

   package JSON renames Synapse.Core.JSON;

   On_Windows : constant Boolean := GNAT.OS_Lib.Directory_Separator = '\';

   --  A program called Name that is found, whose script is Unix_Body, or on
   --  Windows prints Version. PATH is the folder it is in and nothing else.
   procedure Install_Script
     (F : in out Fixture; Dir : Scratch; Name, Unix_Body, Windows_Body : String)
   is
      Script : constant String :=
        Path (Dir, "bin/" & Name & (if On_Windows then ".cmd" else ""));
   begin
      Ada.Directories.Create_Path (Path (Dir, "bin"));
      Synapse.Adapters.File_Bytes.Write
        (Script,
         (if On_Windows then "@echo off" & LF & Windows_Body & LF
          else "#!/bin/sh" & LF & Unix_Body & LF));
      GNAT.OS_Lib.Set_Executable (Script);
      F.Vars.Set ("PATH", Path (Dir, "bin"));
   end Install_Script;

   --  A program that says Version when it is asked for it.
   procedure Install (F : in out Fixture; Dir : Scratch; Name, Version : String)
   is
   begin
      Install_Script
        (F, Dir, Name, "echo '" & Version & "'", "echo " & Version);
   end Install;

   --  A file under the home folder, with its directories.
   procedure Put_Home (Dir : Scratch; Name, Text : String) is
      File : constant String := Path (Dir, "home/" & Name);
   begin
      Ada.Directories.Create_Path (Ada.Directories.Containing_Directory (File));
      Synapse.Adapters.File_Bytes.Write (File, Text);
   end Put_Home;

   --  What the JSON report the last run printed says of the check Key in its
   --  member Name, or says there is none.
   function Field (F : Fixture; Key, Name : String) return String is
      Parsed : constant JSON.Parse_Result := JSON.Parse (F.Console.Out_Text);
   begin
      Assert (Parsed.Ok, "one JSON document: " & F.Console.Out_Text);
      declare
         Checks : constant JSON.Value :=
           JSON.Member_Value (Parsed.Item, "checks");
      begin
         for I in 1 .. JSON.Length (Checks) loop
            declare
               C : constant JSON.Value := JSON.Element (Checks, I);
            begin
               if JSON.As_String (JSON.Member_Value (C, "key")) = Key then
                  return JSON.As_String (JSON.Member_Value (C, Name));
               end if;
            end;
         end loop;
      end;
      return "<no check " & Key & ">";
   end Field;

   No_Check : constant String := "<no check ";

   --  A configured machine: a conf naming the vault, a checkout on `main`
   --  with a remote, and a namespace that agrees with it.
   procedure Setup (F : aliased in out Fixture; Dir : Scratch) is
   begin
      Use_Vault (F, Dir);
      Install (F, Dir, "claude", "2.1.0 (Claude Code)");
      F.Vars.Set ("SYNAPSE_WORK_DIR", Path (Dir, Synapse.Test_Repo.Root_Rel));
      F.Vars.Set ("SYNAPSE_NAMESPACE", Synapse.Test_Repo.Namespace);
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
      Assert
        (Has (Report (F), "claude") and then Has (Report (F), "Synapse installed"),
         "the harness: " & Report (F));
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
        (Has (Report (F), "warn  work dir       " & Path (Dir, Synapse.Test_Repo.Work_Rel) & LF),
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
            "FAIL  hooks          Synapse is installed in none of the harnesses found -- run `synapse configure claude`" &
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
      Ada.Directories.Create_Path (Path (Dir, Synapse.Test_Repo.Work_Rel));
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, Synapse.Test_Repo.Work_Rel & "/_tags_cache.bin"), "x");
      Synapse.Adapters.File_Bytes.Write (Path (Dir, Synapse.Test_Repo.Work_Rel & "/_refs.tsv"), "x");
      Synapse.Adapters.File_Bytes.Write
        (Path (Dir, Synapse.Test_Repo.Work_Rel & "/_index.bin"), "junk");
      Assert
        (Run (Env (F), Args ("--repo", Repo (Dir))) = 1,
         "a damaged index fails");
      Assert
        (Has (Report (F), "ok    work dir       " & Path (Dir, Synapse.Test_Repo.Work_Rel) & LF),
         "work dir");
      Assert
        (Has
           (Report (F),
            "ok    tags cache     " & Path (Dir, Synapse.Test_Repo.Work_Rel & "/_tags_cache.bin") & LF),
         "tags");
      Assert
        (Has
           (Report (F),
            "ok    code cache     " & Path (Dir, Synapse.Test_Repo.Work_Rel & "/_refs.tsv") & LF),
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
            "FAIL  vault          SYNAPSE_VAULT_DIR is not set anywhere"),
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


   procedure Doctor_Finds_The_Harnesses_And_Their_Versions
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make_Outside_Git;
      F   : aliased Fixture;
      Code : Natural;
   begin
      Use_Vault (F, Dir);
      Install (F, Dir, "claude", "2.1.0 (Claude Code)");
      Install (F, Dir, "codex", "codex-cli 0.9.9");
      Code := Run (Env (F), Args ("--repo", Path (Dir), "--format", "json"));
      Assert (Code in 0 | 1, "it ran");
      if not On_Windows then
         Assert (Field (F, "claude", "value") = "2.1.0", "claude's version");
         Assert (Field (F, "codex", "value") = "0.9.9", "codex's version");
      end if;
      Assert
        (Field (F, "claude", "status") = "warn"
         and then Has
                    (Field (F, "claude", "detail"),
                     "Synapse is not installed in it -- run `synapse " &
                     "configure claude`"),
         "installed, and Synapse is not in it: " & Field (F, "claude", "detail"));
      Assert
        (Field (F, "opencode", "status") = "ok"
         and then Field (F, "opencode", "detail") = "not installed"
         and then Field (F, "opencode", "value") = "",
         "a harness that is missing is only said so, while another is there");
      Assert
        (Field (F, "harness", "status") = No_Check & "harness>",
         "and nothing fails for it");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Doctor_Finds_The_Harnesses_And_Their_Versions;

   procedure Doctor_Fails_When_No_Harness_Is_Installed
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make_Outside_Git;
      F   : aliased Fixture;

      procedure Said_Missing (Name : String) is
      begin
         Assert
           (Field (F, Name, "status") = "warn"
            and then Field (F, Name, "detail") = "not installed",
            Name & " is said to be missing");
      end Said_Missing;
   begin
      Use_Vault (F, Dir);
      F.Vars.Set ("PATH", Path (Dir, "bin"));
      Assert
        (Run (Env (F), Args ("--repo", Path (Dir), "--format", "json")) = 1,
         "none is a failure");
      Assert (Field (F, "harness", "status") = "fail", "the line that says so");
      Assert
        (Has (Field (F, "harness", "detail"), "nothing will work without it"),
         "and what it means: " & Field (F, "harness", "detail"));
      Said_Missing ("claude");
      Said_Missing ("codex");
      Said_Missing ("opencode");
      F.Console.Clear;
      Assert
        (Run (Env (F), Args ("--repo", Path (Dir))) = 1, "the same in text");
      Assert
        (Has (Report (F), "FAIL  harness")
         and then Has (Report (F), "none of claude, codex or opencode"),
         "text: " & Report (F));
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Doctor_Fails_When_No_Harness_Is_Installed;

   procedure Doctor_Sees_Where_Synapse_Is_Installed
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir  : constant Scratch := Make_Outside_Git;
      F    : aliased Fixture;
      Code : Natural;
   begin
      Use_Vault (F, Dir);
      Install (F, Dir, "claude", "2.1.0");
      Install (F, Dir, "codex", "0.9.9");
      Install (F, Dir, "opencode", "2.2.6");
      Put_Home (Dir, ".claude/settings.json", "{}");
      Put_Home (Dir, ".codex/hooks.json", "synapse-hook session-start");
      Put_Home (Dir, ".config/opencode/plugin/synapse.js", "// plugin");
      Code := Run (Env (F), Args ("--repo", Path (Dir), "--format", "json"));
      Assert (Code in 0 | 1, "it ran");
      Assert
        (Field (F, "claude", "status") = "warn",
         "claude has a settings file with none of Synapse's hooks in it");
      Assert
        (Field (F, "codex", "status") = "ok"
         and then Has (Field (F, "codex", "detail"), ", Synapse installed"),
         "codex has its hook: " & Field (F, "codex", "detail"));
      Assert
        (Field (F, "opencode", "status") = "ok"
         and then Has (Field (F, "opencode", "detail"), ", Synapse installed"),
         "opencode has its plugin: " & Field (F, "opencode", "detail"));
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Doctor_Sees_Where_Synapse_Is_Installed;

   procedure Doctor_Fails_When_Synapse_Is_In_None_Of_The_Harnesses
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir  : constant Scratch := Make_Outside_Git;
      F    : aliased Fixture;
      Code : Natural;
   begin
      Use_Vault (F, Dir);
      Install (F, Dir, "codex", "0.9.9");
      Code := Run (Env (F), Args ("--repo", Path (Dir), "--format", "json"));
      Assert (Code = 1, "a harness with no Synapse in it does nothing");
      Assert
        (Field (F, "hooks", "status") = "fail"
         and then Has
                    (Field (F, "hooks", "detail"),
                     "installed in none of the harnesses found -- run " &
                     "`synapse configure codex`"),
         "and it says which to configure: " & Field (F, "hooks", "detail"));
      Assert
        (Field (F, "codex", "status") = "warn",
         "its own line is a warning");

      --  Once it is in one of them the rest is only said on their lines.
      F.Console.Clear;
      Put_Home (Dir, ".codex/hooks.json", "synapse-hook session-start");
      Code := Run (Env (F), Args ("--repo", Path (Dir), "--format", "json"));
      Assert (Code in 0 | 1, "it ran");
      Assert
        (Field (F, "hooks", "status") = No_Check & "hooks>",
         "no failure for it once one has it");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Doctor_Fails_When_Synapse_Is_In_None_Of_The_Harnesses;

   procedure Doctor_Is_Quiet_About_Claude_Hooks_For_Another_Harness
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir  : constant Scratch := Make_Outside_Git;
      F    : aliased Fixture;
      Code : Natural;
   begin
      --  A machine that has Codex, with Synapse in it, and never had Claude
      --  Code: no settings.json is not a fault of its hooks.
      Use_Vault (F, Dir);
      Install (F, Dir, "codex", "0.9.9");
      Put_Home (Dir, ".codex/hooks.json", "synapse-hook session-start");
      Code := Run (Env (F), Args ("--repo", Path (Dir), "--format", "json"));
      Assert (Code in 0 | 1, "it ran");
      Assert
        (Field (F, "hooks", "status") = No_Check & "hooks>",
         "no hooks line: " & F.Console.Out_Text);

      --  Nor is a settings.json that Synapse is not in: the harness's own
      --  line says that.
      F.Console.Clear;
      Put_Home (Dir, ".claude/settings.json", "{""theme"": ""dark""}");
      Code := Run (Env (F), Args ("--repo", Path (Dir), "--format", "json"));
      Assert (Code in 0 | 1, "it ran again");
      Assert
        (Field (F, "hooks", "status") = No_Check & "hooks>",
         "still none: " & F.Console.Out_Text);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Doctor_Is_Quiet_About_Claude_Hooks_For_Another_Harness;

   procedure Doctor_Reads_The_Version_However_A_Program_Prints_It
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir  : constant Scratch := Make_Outside_Git;
      F    : aliased Fixture;
      Code : Natural;
   begin
      if On_Windows then
         Remove (Dir);
         return;
      end if;
      Use_Vault (F, Dir);
      --  A program that colours its version and puts a `v` before it.
      Install_Script
        (F, Dir, "opencode",
         "printf '\033[1mopencode\033[0m \033[2mv\033[0m\033[1m2.2.6\033[0m\n'",
         "");
      --  A program that does not know --version.
      Install_Script
        (F, Dir, "synapse-pipeline",
         "echo ""unknown subcommand '--version'"" >&2; exit 1", "");
      Install_Script (F, Dir, "codex", "echo 'codex-cli 0.9.9'", "");
      Code := Run (Env (F), Args ("--repo", Path (Dir), "--format", "json"));
      Assert (Code in 0 | 1, "it ran");
      Assert
        (Field (F, "opencode", "value") = "2.2.6",
         "without the colour and the v: " & Field (F, "opencode", "detail"));
      Assert
        (Field (F, "codex", "value") = "0.9.9", "the first word that is a number");
      Assert
        (Field (F, "pipeline", "status") = "ok"
         and then Field (F, "pipeline", "value") = ""
         and then Field (F, "pipeline", "detail") = "installed",
         "its complaint is not its version: " & Field (F, "pipeline", "detail"));
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Doctor_Reads_The_Version_However_A_Program_Prints_It;

   procedure Doctor_Says_Whether_Pipelines_Can_Run
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir  : constant Scratch := Make_Outside_Git;
      F    : aliased Fixture;
      Code : Natural;
   begin
      Use_Vault (F, Dir);
      F.Vars.Set ("PATH", Path (Dir, "bin"));
      Code := Run (Env (F), Args ("--repo", Path (Dir), "--format", "json"));
      Assert (Code in 0 | 1, "it ran");
      Assert
        (Field (F, "pipeline", "status") = "warn"
         and then Has
                    (Field (F, "pipeline", "detail"),
                     "npm install -g @imunitic/synapse-pipeline"),
         "missing: " & Field (F, "pipeline", "detail"));

      F.Console.Clear;
      Install (F, Dir, "synapse-pipeline", "synapse-pipeline 0.17.1");
      Code := Run (Env (F), Args ("--repo", Path (Dir), "--format", "json"));
      Assert (Code in 0 | 1, "it ran again");
      Assert (Field (F, "pipeline", "status") = "ok", "found");
      if not On_Windows then
         Assert (Field (F, "pipeline", "value") = "0.17.1", "with its version");
      end if;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Doctor_Says_Whether_Pipelines_Can_Run;

   procedure Doctor_Says_Whether_The_Vault_Is_Seeded
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir  : constant Scratch := Make_Outside_Git;
      F    : aliased Fixture;
      Code : Natural;
   begin
      Use_Vault (F, Dir);
      Code := Run (Env (F), Args ("--repo", Path (Dir), "--format", "json"));
      Assert (Code in 0 | 1, "it ran");
      Assert
        (Field (F, "vault", "status") = "ok"
         and then Field (F, "vault-index", "status") = "warn"
         and then Has (Field (F, "vault-index", "detail"), "no Index.md"),
         "an empty vault is not seeded: " & Field (F, "vault-index", "detail"));
      F.Console.Clear;
      Put (Dir, "Index.md", "# Index");
      Code := Run (Env (F), Args ("--repo", Path (Dir), "--format", "json"));
      Assert (Code in 0 | 1, "it ran again");
      Assert
        (Field (F, "vault-index", "status") = "ok"
         and then Field (F, "vault-index", "value") = Path (Dir, "vault/Index.md"),
         "a seeded one is, and says where its Index.md is");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Doctor_Says_Whether_The_Vault_Is_Seeded;

   procedure Doctor_Prints_Json_On_Request (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir  : constant Scratch := Make_Outside_Git;
      F    : aliased Fixture;
      Code : Natural;
   begin
      Use_Vault (F, Dir);
      F.Vars.Set ("PATH", Path (Dir, "bin"));
      Code := Run (Env (F), Args ("--repo", Path (Dir), "--format", "json"));
      declare
         Parsed : constant JSON.Parse_Result :=
           JSON.Parse (F.Console.Out_Text);
      begin
         Assert (Parsed.Ok, "one document: " & F.Console.Out_Text);
         Assert
           (JSON.As_String (JSON.Member_Value (Parsed.Item, "format")) =
            "synapse-doctor/v1",
            "its format");
         declare
            Counts : constant JSON.Value :=
              JSON.Member_Value (Parsed.Item, "counts");
            Total  : constant Long_Long_Integer :=
              JSON.As_Integer (JSON.Member_Value (Counts, "ok"))
              + JSON.As_Integer (JSON.Member_Value (Counts, "warn"))
              + JSON.As_Integer (JSON.Member_Value (Counts, "fail"));
         begin
            Assert
              (Total =
               Long_Long_Integer
                 (JSON.Length (JSON.Member_Value (Parsed.Item, "checks"))),
               "the counts add up to the checks");
            Assert
              ((JSON.As_Integer (JSON.Member_Value (Counts, "fail")) > 0)
               = (Code = 1),
               "and the exit code is 1 exactly when something failed");
         end;
      end;

      F.Console.Clear;
      Assert
        (Run (Env (F), Args ("--repo", Path (Dir), "--format", "text")) = Code,
         "text is the same run");
      Assert
        (Has (Report (F), "ok    git") or else Has (Report (F), "FAIL  git"),
         "as lines");
      F.Console.Clear;
      Assert
        (Run (Env (F), Args ("--format", "xml")) = 2, "a format it has not");
      Assert (Run (Env (F), Args ("--format")) = 2, "a format missing");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Doctor_Prints_Json_On_Request;

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
      Register_Routine
        (T, Doctor_Finds_The_Harnesses_And_Their_Versions'Access,
         "Doctor finds the harnesses and their versions");
      Register_Routine
        (T, Doctor_Fails_When_No_Harness_Is_Installed'Access,
         "Doctor fails when no harness is installed");
      Register_Routine
        (T, Doctor_Sees_Where_Synapse_Is_Installed'Access,
         "Doctor sees where Synapse is installed");
      Register_Routine
        (T, Doctor_Fails_When_Synapse_Is_In_None_Of_The_Harnesses'Access,
         "Doctor fails when Synapse is in none of the harnesses");
      Register_Routine
        (T, Doctor_Is_Quiet_About_Claude_Hooks_For_Another_Harness'Access,
         "Doctor is quiet about Claude hooks for another harness");
      Register_Routine
        (T, Doctor_Reads_The_Version_However_A_Program_Prints_It'Access,
         "Doctor reads the version however a program prints it");
      Register_Routine
        (T, Doctor_Says_Whether_Pipelines_Can_Run'Access,
         "Doctor says whether pipelines can run");
      Register_Routine
        (T, Doctor_Says_Whether_The_Vault_Is_Seeded'Access,
         "Doctor says whether the vault is seeded");
      Register_Routine
        (T, Doctor_Prints_Json_On_Request'Access,
         "Doctor prints JSON on request");
   end Register_Tests;

end Synapse.Commands.Doctor.Tests;
