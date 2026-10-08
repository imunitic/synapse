with Synapse.Core.Identity;

--  Which namespace a checkout belongs to, found by reading the four files
--  that answer the whole question (`.git`, `HEAD`, `commondir`, `config`)
--  and never by running git: reading them is exact where a spawn is merely
--  convenient, and costs nothing against the budget of a hook.
--
--  Not reproduced: `url.<base>.insteadOf` rewriting, which `git remote
--  get-url` applies and a read of the config does not. If one is ever
--  configured the recorded remote stops matching, and every component reports
--  the mismatch instead of writing: a namespace is never silently migrated.

package Synapse.Adapters.Git_Identity is

   --  The checkout that holds Cwd, found by looking for `.git` in it and then
   --  in each parent. A linked worktree has a `.git` file naming its own git
   --  directory, where `HEAD` lives, while `config` lives in the common
   --  directory that names; reading them the other way round would resolve a
   --  worktree to its parent's branch. Paths are made free of links, as the
   --  staleness hook strips the repository root from a path as text.
   --  Raises Not_A_Git_Repo.
   function Find_Layout (Cwd : String) return Core.Identity.Layout;

   --  The remote of a layout: `origin`, else the first remote of the config,
   --  else the repository root, so a repository with no remote still has a
   --  stable value.
   function Remote_Of (Where : Core.Identity.Layout) return String;

   --  Raises Not_A_Git_Repo, and Detached_Head for a HEAD that names no
   --  branch.
   function Resolve (Cwd : String) return Core.Identity.Resolved;

end Synapse.Adapters.Git_Identity;
