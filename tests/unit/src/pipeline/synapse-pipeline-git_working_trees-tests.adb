with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with AUnit.Assertions;

with Synapse.Core.Text_Lists;
with Synapse.Pipeline.Fake_Process;
with Synapse.Pipeline.Session_Process;
with Synapse.Pipeline.System_Process;
with Synapse.Test_Scratch;

package body Synapse.Pipeline.Git_Working_Trees.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Has (Items : Synapse.Core.Text_Lists.Vector; Text : String)
      return Boolean is
   begin
      for Item of Items loop
         if To_String (Item) = Text then
            return True;
         end if;
      end loop;
      return False;
   end Has;

   --  Whether some item ends with Tail.
   function Has_Ending (Items : Synapse.Core.Text_Lists.Vector; Tail : String)
      return Boolean is
   begin
      for Item of Items loop
         declare
            Text : constant String := To_String (Item);
         begin
            if Text'Length >= Tail'Length
              and then Text (Text'Last - Tail'Length + 1 .. Text'Last) = Tail
            then
               return True;
            end if;
         end;
      end loop;
      return False;
   end Has_Ending;

   procedure A_Snapshot_Is_Made_From_A_Temporary_Index
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Process : aliased Fake_Process.Fake_Process;
      Trees   : Git_Working_Trees (Process'Access);
      Answer  : Working_Trees.Maybe_Text;
   begin
      Process.Outcomes.Append (Fake_Process.Exited ("true" & ASCII.LF));
      Process.Outcomes.Append (Fake_Process.Exited (""));
      Process.Outcomes.Append (Fake_Process.Exited ("abc123" & ASCII.LF));
      Answer := Trees.Snapshot ("/work", "exec-1-1-1-before");
      Assert
        (Answer.Found and then To_String (Answer.Value) = "abc123",
         "the snapshot is the id of the tree git wrote, without the line "
         & "break it ends its answer with");
      Assert (Natural (Process.Requests.Length) = 3, "three programs ran");
      declare
         Inside : constant Session_Process.Process_Request :=
           Process.Requests.Element (1);
         Added  : constant Session_Process.Process_Request :=
           Process.Requests.Element (2);
         Wrote  : constant Session_Process.Process_Request :=
           Process.Requests.Element (3);
      begin
         Assert
           (To_String (Inside.Program) = "git"
            and then To_String (Inside.Directory) = "/work"
            and then Has (Inside.Arguments, "rev-parse")
            and then Has (Inside.Arguments, "--is-inside-work-tree"),
            "git is asked first whether the folder is in a work tree");
         Assert
           (Has (Added.Arguments, "add") and then Has (Added.Arguments, "-A")
            and then Has (Wrote.Arguments, "write-tree"),
            "then adds all and writes the tree");
         Assert
           (Has_Ending
              (Added.Environment,
               "synapse-changes-exec-1-1-1-before.index")
            and then Has_Ending
                       (Wrote.Environment,
                        "synapse-changes-exec-1-1-1-before.index"),
            "both through an index of its own, named for the snapshot");
         Assert
           (not Has_Ending
                  (Inside.Environment, "synapse-changes-exec-1-1-1-before.index"),
            "which the first question does not use");
         for Request of Process.Requests loop
            Assert
              (Has (Request.Arguments, "--literal-pathspecs")
               and then Has (Request.Environment, "GIT_OPTIONAL_LOCKS=0")
               and then Has (Request.Environment, "GIT_TERMINAL_PROMPT=0"),
               "no path is a pattern, and git does not wait or ask");
         end loop;
      end;
   end A_Snapshot_Is_Made_From_A_Temporary_Index;

   procedure A_Folder_That_Is_Not_In_A_Repository_Has_No_Snapshot
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Process : aliased Fake_Process.Fake_Process;
      Trees   : Git_Working_Trees (Process'Access);
   begin
      Process.Outcomes.Append
        (Fake_Process.Exited ("", 128, "fatal: not a git repository"));
      Assert
        (not Trees.Snapshot ("/plain", "x").Found,
         "there is no snapshot of a folder that is not in a repository");
      Assert
        (Natural (Process.Requests.Length) = 1,
         "and nothing is added");
   end A_Folder_That_Is_Not_In_A_Repository_Has_No_Snapshot;

   procedure A_Git_That_Cannot_Be_Run_Has_No_Snapshot
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Process : aliased Fake_Process.Fake_Process;
      Trees   : Git_Working_Trees (Process'Access);
   begin
      Assert
        (not Trees.Snapshot ("/work", "x").Found,
         "there is no snapshot when git cannot be started");
   end A_Git_That_Cannot_Be_Run_Has_No_Snapshot;

   procedure An_Add_That_Fails_Has_No_Snapshot (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Process : aliased Fake_Process.Fake_Process;
      Trees   : Git_Working_Trees (Process'Access);
   begin
      Process.Outcomes.Append (Fake_Process.Exited ("true"));
      Process.Outcomes.Append (Fake_Process.Exited ("", 1, "no space left"));
      Assert
        (not Trees.Snapshot ("/work", "x").Found,
         "there is no snapshot when the files cannot be added");
      Assert
        (Natural (Process.Requests.Length) = 2,
         "and no tree is written");
   end An_Add_That_Fails_Has_No_Snapshot;

   procedure Changes_Are_What_Git_Diff_Prints (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Process : aliased Fake_Process.Fake_Process;
      Trees   : Git_Working_Trees (Process'Access);
      Answer  : Working_Trees.Maybe_Text;
   begin
      Process.Outcomes.Append (Fake_Process.Exited ("diff --git a/x b/x" & ASCII.LF));
      Answer := Trees.Changes ("/work", "aaa", "bbb");
      Assert
        (Answer.Found
         and then To_String (Answer.Value) = "diff --git a/x b/x" & ASCII.LF,
         "the changes are what git printed");
      declare
         Asked : constant Session_Process.Process_Request :=
           Process.Requests.Element (1);
      begin
         Assert
           (To_String (Asked.Directory) = "/work"
            and then Has (Asked.Arguments, "diff")
            and then Has (Asked.Arguments, "--find-renames")
            and then Has (Asked.Arguments, "--no-ext-diff")
            and then Has (Asked.Arguments, "--no-textconv")
            and then Has (Asked.Arguments, "aaa")
            and then Has (Asked.Arguments, "bbb"),
            "between the two snapshots, with no program of the user's");
      end;
   end Changes_Are_What_Git_Diff_Prints;

   procedure Changes_That_Git_Cannot_Give_Are_None (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Process : aliased Fake_Process.Fake_Process;
      Trees   : Git_Working_Trees (Process'Access);
   begin
      Process.Outcomes.Append (Fake_Process.Exited ("", 1, "bad object"));
      Assert
        (not Trees.Changes ("/work", "aaa", "bbb").Found,
         "a diff that failed is not an empty one");
   end Changes_That_Git_Cannot_Give_Are_None;

   --  A repository in Scratch with one commit and a file changed since, and
   --  the snapshot of its working tree, made by git.
   function Snapshot_Of_A_Changed_Repository
     (Scratch : Synapse.Test_Scratch.Scratch;
      Trees   : in out Git_Working_Trees) return String
   is
      Dir  : constant String := Synapse.Test_Scratch.Path (Scratch);

      procedure Write (Name, Text : String) is
         File : Ada.Text_IO.File_Type;
      begin
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Dir & "/" & Name);
         Ada.Text_IO.Put_Line (File, Text);
         Ada.Text_IO.Close (File);
      end Write;
   begin
      Synapse.Test_Scratch.Init_Repo (Dir);
      Write ("a.txt", "one");
      Synapse.Test_Scratch.Git (Dir, "add", "-A");
      Synapse.Test_Scratch.Git (Dir, "commit", "-q", "-m", "first");
      Write ("a.txt", "two");
      declare
         Snapshot : constant Working_Trees.Maybe_Text :=
           Trees.Snapshot (Dir, "pin-test");
      begin
         Assert (Snapshot.Found, "the working tree has a snapshot");
         return To_String (Snapshot.Value);
      end;
   end Snapshot_Of_A_Changed_Repository;

   function Contains (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   procedure A_Pinned_Snapshot_Is_What_The_Ref_Names_And_Outlives_Gc
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Scratch : constant Synapse.Test_Scratch.Scratch :=
        Synapse.Test_Scratch.Make;
      Process : aliased System_Process.System_Process;
      Trees   : Git_Working_Trees (Process'Access);
      Dir     : constant String := Synapse.Test_Scratch.Path (Scratch);
      Ref     : constant String := Working_Trees.Run_Ref ("exec-1", "start");
   begin
      declare
         Tree : constant String :=
           Snapshot_Of_A_Changed_Repository (Scratch, Trees);
      begin
         Assert (Trees.Pin (Dir, Ref, Tree), "the snapshot is pinned");
         Assert
           (Synapse.Test_Scratch.Git (Dir, "rev-parse", Ref) = Tree,
            "the ref names the tree of the snapshot");
         Synapse.Test_Scratch.Git (Dir, "gc", "-q", "--prune=now");
         Assert
           (Synapse.Test_Scratch.Git (Dir, "cat-file", "-t", Tree) = "tree",
            "the tree is still there after git gc");
         Assert
           (not Contains
                  (Synapse.Test_Scratch.Git (Dir, "branch", "--list", "--all"),
                   "synapse")
            and then not Contains
                           (Synapse.Test_Scratch.Git (Dir, "tag"), "synapse"),
            "the ref is not a branch and not a tag");
         Trees.Unpin (Dir, Ref);
         Assert
           (Synapse.Test_Scratch.Git
              (Dir, "for-each-ref", "refs/synapse/") = "",
            "unpinning removes the ref");
      end;
      Synapse.Test_Scratch.Remove (Scratch);
   exception
      when others =>
         Synapse.Test_Scratch.Remove (Scratch);
         raise;
   end A_Pinned_Snapshot_Is_What_The_Ref_Names_And_Outlives_Gc;

   procedure A_Folder_That_Is_Not_In_A_Repository_Pins_Nothing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Scratch : constant Synapse.Test_Scratch.Scratch :=
        Synapse.Test_Scratch.Make_Outside_Git;
      Process : aliased System_Process.System_Process;
      Trees   : Git_Working_Trees (Process'Access);
      Dir     : constant String := Synapse.Test_Scratch.Path (Scratch);
   begin
      Assert
        (not Trees.Pin
               (Dir, Working_Trees.Run_Ref ("exec-1", "start"),
                "4b825dc642cb6eb9a060e54bf8d69288fbee4904"),
         "there is nothing to pin in a folder that is not in a repository");
      Trees.Unpin (Dir, Working_Trees.Run_Ref ("exec-1", "start"));
      Synapse.Test_Scratch.Remove (Scratch);
   exception
      when others =>
         Synapse.Test_Scratch.Remove (Scratch);
         raise;
   end A_Folder_That_Is_Not_In_A_Repository_Pins_Nothing;

   procedure Unpinning_A_Ref_That_Is_Not_There_Is_Not_An_Error
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Scratch : constant Synapse.Test_Scratch.Scratch :=
        Synapse.Test_Scratch.Make;
      Process : aliased System_Process.System_Process;
      Trees   : Git_Working_Trees (Process'Access);
      Dir     : constant String := Synapse.Test_Scratch.Path (Scratch);
   begin
      Synapse.Test_Scratch.Init_Repo (Dir);
      Trees.Unpin (Dir, Working_Trees.Run_Ref ("exec-1", "end"));
      Trees.Unpin (Dir, Working_Trees.Run_Ref ("exec-1", "end"));
      Synapse.Test_Scratch.Remove (Scratch);
   exception
      when others =>
         Synapse.Test_Scratch.Remove (Scratch);
         raise;
   end Unpinning_A_Ref_That_Is_Not_There_Is_Not_An_Error;

   procedure A_Run_Ref_Is_Under_Refs_Synapse_Runs (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Working_Trees.Run_Ref ("exec-1", "start")
         = "refs/synapse/runs/exec-1/start",
         "a run's start is pinned under refs/synapse/runs/<id>/start");
   end A_Run_Ref_Is_Under_Refs_Synapse_Runs;

   --  A repository whose own .gitignore ignores every dotfile, as fw-core's
   --  does, while it tracks some of them: a snapshot made from an empty index
   --  would leave them out, and every one would show as added.
   procedure A_Tracked_File_An_Ignore_Rule_Matches_Stays_In_The_Snapshot
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Scratch : constant Synapse.Test_Scratch.Scratch :=
        Synapse.Test_Scratch.Make;
      Process : aliased System_Process.System_Process;
      Trees   : Git_Working_Trees (Process'Access);
      Dir     : constant String := Synapse.Test_Scratch.Path (Scratch);

      procedure Write (Name, Text : String) is
         File : Ada.Text_IO.File_Type;
      begin
         Ada.Text_IO.Create (File, Ada.Text_IO.Out_File, Dir & "/" & Name);
         Ada.Text_IO.Put_Line (File, Text);
         Ada.Text_IO.Close (File);
      end Write;
   begin
      Synapse.Test_Scratch.Init_Repo (Dir);
      Write (".gitignore", ".*");
      Write (".tracked", "kept");
      Write ("a.txt", "one");
      Synapse.Test_Scratch.Git (Dir, "add", "-A");
      Synapse.Test_Scratch.Git (Dir, "add", "-f", ".gitignore", ".tracked");
      Synapse.Test_Scratch.Git (Dir, "commit", "-q", "-m", "first");
      Write (".untracked", "not kept");
      declare
         Snapshot : constant Working_Trees.Maybe_Text :=
           Trees.Snapshot (Dir, "ignored-test");
      begin
         Assert (Snapshot.Found, "the working tree has a snapshot");
         Assert
           (Synapse.Test_Scratch.Git
              (Dir, "diff", "--name-only", "HEAD", To_String (Snapshot.Value))
            = "",
            "the snapshot of an unchanged working tree is the last commit's "
            & "tree, tracked dotfiles included");
         Assert
           (not Contains
              (Synapse.Test_Scratch.Git
                 (Dir, "ls-tree", "--name-only", To_String (Snapshot.Value)),
               ".untracked"),
            "an ignored file that is not tracked stays out");
      end;
      Synapse.Test_Scratch.Remove (Scratch);
   exception
      when others =>
         Synapse.Test_Scratch.Remove (Scratch);
         raise;
   end A_Tracked_File_An_Ignore_Rule_Matches_Stays_In_The_Snapshot;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Git_Working_Trees");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Snapshot_Is_Made_From_A_Temporary_Index'Access,
         "A snapshot is made from a temporary index");
      Register_Routine
        (T, A_Folder_That_Is_Not_In_A_Repository_Has_No_Snapshot'Access,
         "A folder that is not in a repository has no snapshot");
      Register_Routine
        (T, A_Git_That_Cannot_Be_Run_Has_No_Snapshot'Access,
         "A git that cannot be run has no snapshot");
      Register_Routine
        (T, An_Add_That_Fails_Has_No_Snapshot'Access,
         "An add that fails has no snapshot");
      Register_Routine
        (T, Changes_Are_What_Git_Diff_Prints'Access,
         "Changes are what git diff prints");
      Register_Routine
        (T, Changes_That_Git_Cannot_Give_Are_None'Access,
         "Changes that git cannot give are none");
      Register_Routine
        (T,
         A_Tracked_File_An_Ignore_Rule_Matches_Stays_In_The_Snapshot'Access,
         "A tracked file an ignore rule matches stays in the snapshot");
      Register_Routine
        (T, A_Pinned_Snapshot_Is_What_The_Ref_Names_And_Outlives_Gc'Access,
         "A pinned snapshot is what the ref names and outlives git gc");
      Register_Routine
        (T, A_Folder_That_Is_Not_In_A_Repository_Pins_Nothing'Access,
         "A folder that is not in a repository pins nothing");
      Register_Routine
        (T, Unpinning_A_Ref_That_Is_Not_There_Is_Not_An_Error'Access,
         "Unpinning a ref that is not there is not an error");
      Register_Routine
        (T, A_Run_Ref_Is_Under_Refs_Synapse_Runs'Access,
         "A run ref is under refs/synapse/runs");
   end Register_Tests;

end Synapse.Pipeline.Git_Working_Trees.Tests;
