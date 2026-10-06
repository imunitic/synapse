with Ada.Containers;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Adapters.File_Bytes;
with Synapse.Adapters.System_Process;
with Synapse.Core.Text_Lists;
with Synapse.Test_Scratch;

package body Synapse.Adapters.Git_Sync.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use Synapse.Test_Scratch;
   use type Ada.Containers.Count_Type;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   --  Records every command and answers from a script.
   type Scripted_Runner is limited new Runner.Runner with record
      Log      : Unbounded_String;
      Staged   : Unbounded_String;
      Identity : Boolean := True;
   end record;

   overriding
   function Run
     (R       : in out Scripted_Runner;
      Program : String;
      Args    : Core.Text_Lists.Vector;
      Opts    : Runner.Options) return Runner.Result
   is
      Line   : Unbounded_String := To_Unbounded_String (Program);
      Result : Runner.Result;
   begin
      for A of Args loop
         Ada.Strings.Unbounded.Append (Line, " " & A);
      end loop;
      Ada.Strings.Unbounded.Append
        (R.Log, To_String (Line) & "|" & To_String (Opts.Cwd) & LF);
      if not Args.Is_Empty then
         declare
            First : constant String := To_String (Args (1));
         begin
            if First = "-c" and then Args.Length > 2
              and then To_String (Args (3)) = "diff"
            then
               Result.Output := R.Staged;
            elsif First = "config" and then Args.Length = 2 then
               Result.Exit_Code := (if R.Identity then 0 else 1);
               if R.Identity then
                  Result.Output := To_Unbounded_String ("a@b" & LF);
               end if;
            end if;
         end;
      end if;
      return Result;
   end Run;

   Real : Adapters.System_Process.System_Runner;

   procedure Commit_Messages_Name_The_Paths (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Commit_Message ("a.md") = "vault: a.md", "one");
      Assert (Commit_Message ("a.md" & LF & "b.md") = "vault: a.md, b.md",
              "two");
      Assert (Commit_Message ("1" & LF & "2" & LF & "3" & LF & "4")
              = "vault: 1, 2, 3, 4", "four are named");
      Assert (Commit_Message ("1" & LF & "2" & LF & "3" & LF & "4" & LF & "5")
              = "vault: 5 files", "five are counted");
      Assert (Commit_Message ("a b/c d.md") = "vault: a b/c d.md",
              "spaces kept");
   end Commit_Messages_Name_The_Paths;

   procedure The_Exact_Git_Commands_Are_Pinned (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      R : Scripted_Runner;
   begin
      R.Staged := To_Unbounded_String ("a.md" & LF & "b.md" & LF);
      Commit_If_Dirty (R, "/v");
      Assert (To_String (R.Log)
              = "git add -A|/v" & LF
                & "git -c core.quotePath=false diff --cached --name-only|/v"
                & LF
                & "git config user.email|/v" & LF
                & "git commit --quiet -m vault: a.md, b.md|/v" & LF,
              "add, list, identity, commit: " & To_String (R.Log));

      R.Log := Null_Unbounded_String;
      R.Identity := False;
      Commit_If_Dirty (R, "/v");
      Assert (Ada.Strings.Fixed.Index (To_String (R.Log),
                                       "git config user.email "
                                       & "vault@synapse.local|/v") > 0
              and then Ada.Strings.Fixed.Index (To_String (R.Log),
                                                "git config user.name "
                                                & "Synapse Vault|/v") > 0,
              "a missing identity is set");

      R.Log := Null_Unbounded_String;
      R.Staged := Null_Unbounded_String;
      Commit_If_Dirty (R, "/v");
      Assert (Ada.Strings.Fixed.Index (To_String (R.Log), "commit") = 0,
              "nothing staged, nothing committed");
   end The_Exact_Git_Commands_Are_Pinned;

   procedure Ensure_Repo_Initialises_Only_Once (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Assert (not Ada.Directories.Exists (Path (Dir, ".git")), "no repo yet");
      Ensure_Repo (Real, Path (Dir));
      Assert (Ada.Directories.Exists (Path (Dir, ".git")), "made one");
      File_Bytes.Write (Path (Dir, ".git/marker"), "kept");
      Ensure_Repo (Real, Path (Dir));
      Assert (Ada.Directories.Exists (Path (Dir, ".git/marker")),
              "an existing repo is left alone");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Ensure_Repo_Initialises_Only_Once;

   procedure Commits_Are_Made_Only_For_Changes (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Init_Repo (Path (Dir));
      Commit_If_Dirty (Real, Path (Dir));
      Assert (Commit_Count (Path (Dir)) = 0, "nothing to commit");
      File_Bytes.Write (Path (Dir, "a.md"), "one");
      Commit_If_Dirty (Real, Path (Dir));
      Assert (Commit_Count (Path (Dir)) = 1, "one change, one commit");
      Assert (Head_Subject (Path (Dir)) = "vault: a.md", "its message");
      Commit_If_Dirty (Real, Path (Dir));
      Assert (Commit_Count (Path (Dir)) = 1, "no change, no commit");
      for I in 1 .. 5 loop
         File_Bytes.Write
           (Path (Dir, "n" & Ada.Strings.Fixed.Trim (Integer'Image (I),
                                                      Ada.Strings.Left)
                       & ".md"), "x");
      end loop;
      Commit_If_Dirty (Real, Path (Dir));
      Assert (Head_Subject (Path (Dir)) = "vault: 5 files", "a count");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Commits_Are_Made_Only_For_Changes;

   procedure A_Non_Ascii_Path_Is_Named_Verbatim
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir  : constant Scratch := Make;
      Dash : constant String :=
        Character'Val (16#E2#) & Character'Val (16#80#)
        & Character'Val (16#94#);
   begin
      Init_Repo (Path (Dir));
      File_Bytes.Write (Path (Dir, "sb " & Dash & " Foo.md"), "x");
      Commit_If_Dirty (Real, Path (Dir));
      Assert (Head_Subject (Path (Dir)) = "vault: sb " & Dash & " Foo.md",
              "not git's octal escape: " & Head_Subject (Path (Dir)));
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Non_Ascii_Path_Is_Named_Verbatim;

   procedure A_Repository_Without_Identity_Still_Commits
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Ada.Directories.Create_Path (Path (Dir));
      Git (Path (Dir), "init", "-q", "-b", "main");
      Git (Path (Dir), "config", "user.useConfigOnly", "true");
      File_Bytes.Write (Path (Dir, "a.md"), "x");
      --  With no identity anywhere git would refuse; the store sets one.
      Commit_If_Dirty (Real, Path (Dir));
      if Git (Path (Dir), "config", "user.email") = "vault@synapse.local" then
         Assert (Commit_Count (Path (Dir)) = 1, "committed with the fallback");
      else
         Assert (Commit_Count (Path (Dir)) = 1,
                 "committed with the identity the machine has");
      end if;
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Repository_Without_Identity_Still_Commits;

   procedure The_Lock_Is_Exclusive_Until_Released (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir           : constant Scratch := Make;
      First, Second : Dir_Lock.Lock;
   begin
      Init_Repo (Path (Dir));
      Try_Acquire (Path (Dir), First);
      Assert (Dir_Lock.Held (First), "taken");
      Assert (Ada.Directories.Exists (Path (Dir, ".git/synapse-sync.lock")),
              "inside the repository");
      Try_Acquire (Path (Dir), Second);
      Assert (not Dir_Lock.Held (Second), "not twice");
      Acquire_With_Retry (Path (Dir), 1, Second);
      Assert (not Dir_Lock.Held (Second), "a single try gives up");
      Dir_Lock.Release (First);
      Try_Acquire (Path (Dir), Second);
      Assert (Dir_Lock.Held (Second), "free after release");
      Dir_Lock.Release (Second);
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Lock_Is_Exclusive_Until_Released;

   procedure Nothing_Is_Synced_Without_An_Upstream
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Init_Repo (Path (Dir));
      File_Bytes.Write (Path (Dir, "a.md"), "x");
      Commit_If_Dirty (Real, Path (Dir));
      Assert (not Upstream_Of (Real, Path (Dir)).Found, "no upstream");
      Assert (Commits_Ahead (Real, Path (Dir)) = 0, "so nothing is ahead");
      Assert (Pull (Real, Path (Dir)), "pull is trivially safe");
      Push_If_Ahead (Real, Path (Dir));
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Nothing_Is_Synced_Without_An_Upstream;

   --  A bare remote and a clone of it with one commit pushed.
   procedure Clone_With_Remote (Dir : Scratch; Name : String) is
   begin
      Git (Path (Dir), "clone", "-q", Path (Dir, "remote.git"), Name);
      Git (Path (Dir, Name), "config", "user.email", "test@example.com");
      Git (Path (Dir, Name), "config", "user.name", "Test");
   end Clone_With_Remote;

   procedure Pushing_Needs_Commits_Ahead (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Git (Path (Dir), "init", "-q", "--bare", "-b", "main", "remote.git");
      Clone_With_Remote (Dir, "a");
      Git (Path (Dir, "a"), "checkout", "-q", "-b", "main");
      File_Bytes.Write (Path (Dir, "a/one.md"), "1");
      Commit_If_Dirty (Real, Path (Dir, "a"));
      Git (Path (Dir, "a"), "push", "-q", "-u", "origin", "main");
      Assert (Upstream_Of (Real, Path (Dir, "a")).Found, "has an upstream");
      Assert (To_String (Upstream_Of (Real, Path (Dir, "a")).Text)
              = "origin/main", "named");
      Assert (Commits_Ahead (Real, Path (Dir, "a")) = 0, "in step");

      File_Bytes.Write (Path (Dir, "a/two.md"), "2");
      Commit_If_Dirty (Real, Path (Dir, "a"));
      Assert (Commits_Ahead (Real, Path (Dir, "a")) = 1, "one ahead");
      Push_If_Ahead (Real, Path (Dir, "a"));
      Assert (Commits_Ahead (Real, Path (Dir, "a")) = 0, "pushed");
      Assert (Git (Path (Dir, "remote.git"), "rev-list", "--count", "main")
              = "2", "the remote has both");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Pushing_Needs_Commits_Ahead;

   procedure A_Conflicting_Pull_Is_Aborted_And_Leaves_The_Note_Clean
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Git (Path (Dir), "init", "-q", "--bare", "-b", "main", "remote.git");
      Clone_With_Remote (Dir, "a");
      Git (Path (Dir, "a"), "checkout", "-q", "-b", "main");
      File_Bytes.Write (Path (Dir, "a/n.md"), "base" & LF);
      Commit_If_Dirty (Real, Path (Dir, "a"));
      Git (Path (Dir, "a"), "push", "-q", "-u", "origin", "main");
      Clone_With_Remote (Dir, "b");
      Git (Path (Dir, "b"), "checkout", "-q", "main");

      File_Bytes.Write (Path (Dir, "b/n.md"), "from b" & LF);
      Commit_If_Dirty (Real, Path (Dir, "b"));
      Push_If_Ahead (Real, Path (Dir, "b"));

      File_Bytes.Write (Path (Dir, "a/n.md"), "from a" & LF);
      Commit_If_Dirty (Real, Path (Dir, "a"));
      Assert (not Pull (Real, Path (Dir, "a")), "the conflict is reported");
      Assert (File_Bytes.Read (Path (Dir, "a/n.md"), 1000) = "from a" & LF,
              "no conflict markers in the note");
      Assert (not Ada.Directories.Exists (Path (Dir, "a/.git/rebase-merge"))
              and then not Ada.Directories.Exists
                             (Path (Dir, "a/.git/rebase-apply")),
              "no rebase left half-applied");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Conflicting_Pull_Is_Aborted_And_Leaves_The_Note_Clean;

   procedure The_Pusher_Pulls_Commits_And_Pushes (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir : constant Scratch := Make;
   begin
      Git (Path (Dir), "init", "-q", "--bare", "-b", "main", "remote.git");
      Clone_With_Remote (Dir, "a");
      Git (Path (Dir, "a"), "checkout", "-q", "-b", "main");
      File_Bytes.Write (Path (Dir, "a/one.md"), "1");
      Commit_If_Dirty (Real, Path (Dir, "a"));
      Git (Path (Dir, "a"), "push", "-q", "-u", "origin", "main");

      --  One commit ahead, and one change a write had to leave uncommitted.
      File_Bytes.Write (Path (Dir, "a/two.md"), "2");
      Commit_If_Dirty (Real, Path (Dir, "a"));
      File_Bytes.Write (Path (Dir, "a/three.md"), "3");

      Run_Pusher (Real, Path (Dir, "a"));
      Assert (Git (Path (Dir, "remote.git"), "rev-list", "--count", "main")
              = "3", "the catch-up commit went out in the same cycle");
      Assert (not Ada.Directories.Exists
                    (Path (Dir, "a/.git/synapse-sync.lock")),
              "and the lock was released");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end The_Pusher_Pulls_Commits_And_Pushes;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Git_Sync");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Commit_Messages_Name_The_Paths'Access,
         "Commit messages name the paths");
      Register_Routine
        (T, The_Exact_Git_Commands_Are_Pinned'Access,
         "The exact git commands are pinned");
      Register_Routine
        (T, Ensure_Repo_Initialises_Only_Once'Access,
         "Ensure_Repo initialises only once");
      Register_Routine
        (T, Commits_Are_Made_Only_For_Changes'Access,
         "Commits are made only for changes");
      Register_Routine
        (T, A_Non_Ascii_Path_Is_Named_Verbatim'Access,
         "A non-ASCII path is named verbatim");
      Register_Routine
        (T, A_Repository_Without_Identity_Still_Commits'Access,
         "A repository without identity still commits");
      Register_Routine
        (T, The_Lock_Is_Exclusive_Until_Released'Access,
         "The lock is exclusive until released");
      Register_Routine
        (T, Nothing_Is_Synced_Without_An_Upstream'Access,
         "Nothing is synced without an upstream");
      Register_Routine
        (T, Pushing_Needs_Commits_Ahead'Access,
         "Pushing needs commits ahead");
      Register_Routine
        (T, A_Conflicting_Pull_Is_Aborted_And_Leaves_The_Note_Clean'Access,
         "A conflicting pull is aborted and leaves the note clean");
      Register_Routine
        (T, The_Pusher_Pulls_Commits_And_Pushes'Access,
         "The pusher pulls, commits and pushes");
   end Register_Tests;

end Synapse.Adapters.Git_Sync.Tests;
