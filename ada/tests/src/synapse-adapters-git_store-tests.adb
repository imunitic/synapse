with Ada.Containers;
with Ada.Directories;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Adapters.Disk_Store;
with Synapse.Adapters.Fake_Store;
with Synapse.Adapters.File_Bytes;
with Synapse.Adapters.System_Process;
with Synapse.Test_Scratch;

package body Synapse.Adapters.Git_Store.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use Synapse.Test_Scratch;
   use type Ada.Containers.Count_Type;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   --  Counts how often a push was asked for.
   type Counting_Spawner is limited new Pusher_Spawner with record
      Calls : Natural := 0;
      Last  : Unbounded_String;
   end record;

   overriding
   procedure Spawn_Pusher (S : in out Counting_Spawner; Vault : String) is
   begin
      S.Calls := S.Calls + 1;
      S.Last := To_Unbounded_String (Vault);
   end Spawn_Pusher;

   --  A runner for a machine where git cannot be started.
   type Broken_Runner is limited new Ports.Process_Runner.Runner with
     null record;

   overriding
   function Run
     (R       : in out Broken_Runner;
      Program : String;
      Args    : Core.Text_Lists.Vector;
      Opts    : Ports.Process_Runner.Options)
      return Ports.Process_Runner.Result
   is
      pragma Unreferenced (R, Args, Opts);
   begin
      raise Ports.Process_Runner.Process_Failure with "cannot run " & Program;
      return (others => <>);
   end Run;

   procedure A_First_Write_Initialises_And_Commits
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir   : constant Scratch := Make;
      Disk  : aliased Disk_Store.Disk_Store :=
        Disk_Store.Create (Path (Dir), "");
      Run   : aliased System_Process.System_Runner;
      Store : Git_Store := Create (Disk'Access, Run'Access, Path (Dir));
   begin
      Assert (Store.Write ("a.md", "---" & Character'Val (10) & "title: A"
                           & Character'Val (10) & "---").Accepted, "accepted");
      Assert (Ada.Directories.Exists (Path (Dir, ".git")), "a repo was made");
      Assert (Commit_Count (Path (Dir)) = 1, "one commit");
      Assert (Head_Subject (Path (Dir)) = "vault: a.md", "naming the file");
      Assert (Store.Read ("a.md").Found, "reads through");
      Assert (To_String (Store.List.Element (1)) = "a.md", "lists through");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_First_Write_Initialises_And_Commits;

   procedure Every_Write_Commits_Without_A_Second_Init
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir   : constant Scratch := Make;
      Disk  : aliased Disk_Store.Disk_Store :=
        Disk_Store.Create (Path (Dir), "ns");
      Run   : aliased System_Process.System_Runner;
      Store : Git_Store := Create (Disk'Access, Run'Access, Path (Dir));
   begin
      Assert (Store.Write ("a.md", "one").Accepted, "first");
      File_Bytes.Write (Path (Dir, ".git/marker"), "kept");
      Assert (Store.Write ("b.md", "two").Accepted, "second");
      Assert (Commit_Count (Path (Dir)) = 2, "two commits");
      Assert (Ada.Directories.Exists (Path (Dir, ".git/marker")),
              "the repository was not initialised again");
      Assert (Head_Subject (Path (Dir)) = "vault: ns/b.md",
              "the path as the vault sees it");
      Assert (not Ada.Directories.Exists
                    (Path (Dir, ".git/synapse-sync.lock")),
              "the lock was released");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Every_Write_Commits_Without_A_Second_Init;

   procedure A_Write_That_Loses_The_Lock_Still_Lands
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir   : constant Scratch := Make;
      Disk  : aliased Disk_Store.Disk_Store :=
        Disk_Store.Create (Path (Dir), "");
      Run   : aliased System_Process.System_Runner;
      Store : Git_Store := Create (Disk'Access, Run'Access, Path (Dir));
   begin
      Init_Repo (Path (Dir));
      Ada.Directories.Create_Directory (Path (Dir, ".git/synapse-sync.lock"));
      Assert (Store.Write ("a.md", "kept").Accepted, "accepted");
      Assert (Store.Read ("a.md").Found, "on disk");
      Assert (Commit_Count (Path (Dir)) = 0, "but not committed");
      Ada.Directories.Delete_Directory (Path (Dir, ".git/synapse-sync.lock"));
      Assert (Store.Write ("b.md", "next").Accepted, "the next write");
      Assert (Commit_Count (Path (Dir)) = 1, "sweeps the skipped one up");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Write_That_Loses_The_Lock_Still_Lands;

   procedure A_Broken_Git_Never_Fails_A_Write (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir   : constant Scratch := Make;
      Disk  : aliased Disk_Store.Disk_Store :=
        Disk_Store.Create (Path (Dir), "");
      Run   : aliased Broken_Runner;
      Store : Git_Store := Create (Disk'Access, Run'Access, Path (Dir));
   begin
      Assert (Store.Write ("a.md", "kept").Accepted, "accepted anyway");
      Assert (To_String (Store.Read ("a.md").Text) = "kept", "and on disk");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Broken_Git_Never_Fails_A_Write;

   procedure A_Push_Is_Asked_For_At_Each_Multiple (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir     : constant Scratch := Make;
      Vault   : constant String := Path (Dir, "a");
      Disk    : aliased Disk_Store.Disk_Store :=
        Disk_Store.Create (Vault, "");
      Run     : aliased System_Process.System_Runner;
      Spawner : aliased Counting_Spawner;
      Store   : Git_Store :=
        Create (Disk'Access, Run'Access, Vault, 2, Spawner'Access);
   begin
      Git (Path (Dir), "init", "-q", "--bare", "-b", "main", "remote.git");
      Git (Path (Dir), "clone", "-q", Path (Dir, "remote.git"), "a");
      Git (Vault, "config", "user.email", "t@example.com");
      Git (Vault, "config", "user.name", "T");
      Git (Vault, "checkout", "-q", "-b", "main");
      File_Bytes.Write (Vault & "/seed.md", "s");
      Git (Vault, "add", "-A");
      Git (Vault, "commit", "-q", "-m", "seed");
      Git (Vault, "push", "-q", "-u", "origin", "main");

      Assert (Store.Write ("1.md", "x").Accepted, "first");
      Assert (Spawner.Calls = 0, "one ahead: not due");
      Assert (Store.Write ("2.md", "x").Accepted, "second");
      Assert (Spawner.Calls = 1 and then To_String (Spawner.Last) = Vault,
              "two ahead: due, for this vault");
      Assert (Store.Write ("3.md", "x").Accepted, "third");
      Assert (Spawner.Calls = 1, "three ahead: not a multiple");
      Assert (Store.Write ("4.md", "x").Accepted, "fourth");
      Assert (Spawner.Calls = 2, "four ahead: due again");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end A_Push_Is_Asked_For_At_Each_Multiple;

   procedure Pushes_Are_Never_Asked_For_Without_A_Reason
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Dir     : constant Scratch := Make;
      Disk    : aliased Disk_Store.Disk_Store :=
        Disk_Store.Create (Path (Dir), "");
      Run     : aliased System_Process.System_Runner;
      Spawner : aliased Counting_Spawner;
      Never   : Git_Store :=
        Create (Disk'Access, Run'Access, Path (Dir), 0, Spawner'Access);
      Nobody  : Git_Store := Create (Disk'Access, Run'Access, Path (Dir), 1);
   begin
      Assert (Never.Write ("a.md", "x").Accepted, "with a zero threshold");
      Assert (Nobody.Write ("b.md", "x").Accepted, "with nobody to ask");
      Assert (Spawner.Calls = 0, "no upstream and no threshold: nothing");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end Pushes_Are_Never_Asked_For_Without_A_Reason;

   procedure It_Can_Wrap_Any_Store (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Dir   : constant Scratch := Make;
      Fake  : aliased Fake_Store.Fake_Store;
      Run   : aliased System_Process.System_Runner;
      Store : Git_Store := Create (Fake'Access, Run'Access, Path (Dir));
   begin
      Assert (Store.Write ("a.md", "needle").Accepted, "written to the fake");
      Assert (Fake.Writes = 1, "the inner store did the write");
      Assert (Store.Search ("needle").Length = 1, "search delegates");
      Assert (Commit_Count (Path (Dir)) = 0,
              "nothing on disk in the vault to commit");
      Remove (Dir);
   exception
      when others =>
         Remove (Dir);
         raise;
   end It_Can_Wrap_Any_Store;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Adapters.Git_Store");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_First_Write_Initialises_And_Commits'Access,
         "A first write initialises and commits");
      Register_Routine
        (T, Every_Write_Commits_Without_A_Second_Init'Access,
         "Every write commits without a second init");
      Register_Routine
        (T, A_Write_That_Loses_The_Lock_Still_Lands'Access,
         "A write that loses the lock still lands");
      Register_Routine
        (T, A_Broken_Git_Never_Fails_A_Write'Access,
         "A broken git never fails a write");
      Register_Routine
        (T, A_Push_Is_Asked_For_At_Each_Multiple'Access,
         "A push is asked for at each multiple");
      Register_Routine
        (T, Pushes_Are_Never_Asked_For_Without_A_Reason'Access,
         "Pushes are never asked for without a reason");
      Register_Routine
        (T, It_Can_Wrap_Any_Store'Access, "It can wrap any store");
   end Register_Tests;

end Synapse.Adapters.Git_Store.Tests;
