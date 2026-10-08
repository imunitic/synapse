with Ada.Strings.Unbounded;

with Acceptance.Fixtures;

package body Acceptance.Git_Store_Tests is

   use Acceptance.Fixtures;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   function Git_At
     (F                          : Fixture; Cwd : String; A1 : String;
      A2, A3, A4, A5, A6, A7, A8 : String := "") return Result is
     (Run (F, "git", Args (A1, A2, A3, A4, A5, A6, A7, A8), Cwd));

   function Git_Output_At
     (F : Fixture; Cwd : String; A1 : String; A2, A3, A4 : String := "")
      return String is
     (Trim (To_String (Git_At (F, Cwd, A1, A2, A3, A4).Output)));

   --  A bare "remote" and a vault repository that tracks it, both local
   --  paths, so that a push is real git plumbing with no network.
   function Seed_Vault_With_Remote (F : Fixture) return String is
      Remote : constant String := Root (F) & "/vault-remote.git";
      Ignore : Result;
   begin
      Ignore :=
        Git_At (F, Root (F), "init", "-q", "--bare", "-b", "main", Remote);
      Ignore := Git_At (F, Vault (F), "init", "-q", "-b", "main", Vault (F));
      Ignore := Git_At (F, Vault (F), "remote", "add", "origin", Remote);
      Write_File (Vault (F) & "/seed.md", "seed" & LF);
      Ignore := Git_At (F, Vault (F), "add", "seed.md");
      Ignore :=
        Git_At
          (F, Vault (F), "-c", "user.email=t@e", "-c", "user.name=t", "commit",
           "-q", "-m", "seed");
      Ignore := Git_At (F, Vault (F), "push", "-q", "-u", "origin", "main");
      return Remote;
   end Seed_Vault_With_Remote;

   procedure Write_Spawns_A_Pusher_That_Pushes (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F      : Fixture;
      Remote : constant String := Seed_Vault_With_Remote (F);
   begin
      Set_Env (F, "SYNAPSE_VAULT_INTEGRATIONS", "git");
      Set_Env (F, "SYNAPSE_VAULT_PUSH_EVERY", "1");
      Assert_Exit
        (Run_Fake_Stdin (F, "more" & LF, "vault-write", "more.md"), 0,
         "vault-write");

      --  The pusher is detached and the write does not wait for it, so it
      --  has a bounded time to finish the push.
      for Attempt in 1 .. 50 loop
         exit when Git_Output_At
             (F, Remote, "log", "-1", "--format=%s", "main") =
           "vault: more.md";
         delay 0.1;
      end loop;
      Assert_Equal
        (Git_Output_At (F, Remote, "log", "-1", "--format=%s", "main"),
         "vault: more.md", "the remote's latest commit");
   end Write_Spawns_A_Pusher_That_Pushes;

   procedure Below_The_Threshold_Commits_And_Does_Not_Push
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F      : Fixture;
      Remote : constant String := Seed_Vault_With_Remote (F);
   begin
      Set_Env (F, "SYNAPSE_VAULT_INTEGRATIONS", "git");
      Set_Env (F, "SYNAPSE_VAULT_PUSH_EVERY", "5");
      Assert_Exit
        (Run_Fake_Stdin (F, "more" & LF, "vault-write", "more.md"), 0,
         "vault-write");

      --  The commit lands locally either way; only the push is gated.
      Assert_Equal
        (Git_Output_At (F, Vault (F), "log", "-1", "--format=%s"),
         "vault: more.md", "the local commit");
      delay 0.3;
      Assert_Equal
        (Git_Output_At (F, Remote, "log", "-1", "--format=%s", "main"), "seed",
         "the remote is untouched");
   end Below_The_Threshold_Commits_And_Does_Not_Push;

   overriding function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Acceptance: the git integration's pusher");
   end Name;

   overriding procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Write_Spawns_A_Pusher_That_Pushes'Access,
         "vault-write spawns a pusher that pushes to a local remote");
      Register_Routine
        (T, Below_The_Threshold_Commits_And_Does_Not_Push'Access,
         "below the push-every threshold it commits and spawns no pusher");
   end Register_Tests;

end Acceptance.Git_Store_Tests;
