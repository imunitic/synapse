with Synapse.Adapters.Dir_Lock;
with Synapse.Ports.Process_Runner;
with Synapse.Ports.Store;

--  The vault's own version control: the git operations over one directory
--  that the git store and the background pusher share. Git runs through a
--  process runner. Every operation takes the vault path; a git that cannot
--  be started raises Process_Failure.

package Synapse.Adapters.Git_Sync is

   package Runner renames Synapse.Ports.Process_Runner;

   --  The sync lock lives inside the repository and is taken to be abandoned
   --  after this long: every legitimate holder does a local commit or a small
   --  pull or push.
   Lock_Stale_After : constant Duration := 180.0;

   function Lock_Path (Vault : String) return String;

   --  One attempt, never waiting.
   procedure Try_Acquire (Vault : String; L : in out Dir_Lock.Lock);

   --  Up to Max_Tries attempts, for a caller that is already detached.
   procedure Acquire_With_Retry
     (Vault : String; Max_Tries : Positive; L : in out Dir_Lock.Lock);

   --  The tracked upstream's short name (`origin/main`), or nothing: no
   --  remote, or one never pushed to, is ordinary.
   function Upstream_Of
     (R : in out Runner.Runner'Class; Vault : String)
      return Ports.Store.Maybe_Text;

   --  Rebases local commits that are not pushed onto the upstream. A
   --  conflict is aborted at once instead of leaving markers in a note.
   --  True when it is safe to go on: up to date, pulled cleanly, or there is
   --  no upstream.
   function Pull (R : in out Runner.Runner'Class; Vault : String)
      return Boolean;

   --  The commit message for these staged paths, one per line: `vault: ` and
   --  the paths comma-separated, or `vault: N files` for more than four.
   function Commit_Message (Staged : String) return String;

   --  `git add -A`, then a commit when that staged anything, with a local
   --  identity set first only if none resolves. Quiet when git says no.
   procedure Commit_If_Dirty (R : in out Runner.Runner'Class; Vault : String);

   --  The number of local commits not on the upstream; zero without one.
   function Commits_Ahead (R : in out Runner.Runner'Class; Vault : String)
      return Natural;

   --  Pushes when commits are ahead (counted after any pull). A failed push
   --  is silent.
   procedure Push_If_Ahead (R : in out Runner.Runner'Class; Vault : String);

   --  `git init` when Vault has no `.git` directory.
   procedure Ensure_Repo (R : in out Runner.Runner'Class; Vault : String);

   --  The commit a write, rename or delete makes after it: ensure a
   --  repository, try the lock without waiting, and commit if dirty while
   --  holding it. When another holder has the lock nothing is committed: the
   --  change is already on disk and the next commit or the pusher sweeps it
   --  up. Returns whether the lock was held, so a caller can go on to check
   --  for a push; failures of git are not raised.
   procedure Commit_Under_Lock
     (R : in out Runner.Runner'Class; Vault : String; Committed : out Boolean);

   --  The body of the background pusher: take the lock (up to ten tries),
   --  pull, stopping if that fails, commit whatever a write that skipped its
   --  own commit left, then push, in that order so the catch-up commit goes
   --  out in the same cycle.
   procedure Run_Pusher (R : in out Runner.Runner'Class; Vault : String);

end Synapse.Adapters.Git_Sync;
