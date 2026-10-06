with Ada.Strings.Unbounded;

--  Naming a namespace: `synapse/{repo}@{branch}/`. A namespace is keyed by
--  repository and branch, so the graph describes one tree and not every
--  branch at once. A linked worktree needs no disambiguation of its own: git
--  refuses to check out one branch twice, so a branch already names at most
--  one checkout.
--
--  What is here is the text work. Finding a checkout and reading its git
--  files is Synapse.Adapters.Git_Identity.

package Synapse.Core.Identity is

   use Ada.Strings.Unbounded;

   type Maybe_Text (Found : Boolean := False) is record
      case Found is
         when True =>
            Text : Unbounded_String;

         when False =>
            null;
      end case;
   end record;

   --  The repository name of a remote in every form it takes
   --  (`ssh://git@host:7999/x/repo.git`, `git@host:org/repo.git`,
   --  `https://host/org/repo/`, a local path, `host:repo.git`): the last path
   --  or colon segment, without a trailing slash and without one trailing
   --  `.git`. It is taken from the remote and not the directory: a linked
   --  worktree's directory differs from its parent's, and one repository's
   --  branches would land under two names. With no remote, the caller passes
   --  the repository root, whose last segment is a stable name for a project
   --  that is only local.
   function Repo_Name (Remote : String) return String;

   --  Characters a branch may contain that a directory name may not: this is
   --  the vault's own set, not git's rules for references.
   Illegal_In_Branch : constant String := "/:*?""<>|";

   --  The branch as one directory name.
   function Sanitize_Branch (Branch : String) return String;

   --  `repo@branch`. `@` and not `:`, which is illegal in a vault file name
   --  and shows as `/` in the macOS Finder.
   function Namespace (Repo, Sanitized_Branch : String) return String
   is (Repo & "@" & Sanitized_Branch);

   --  The path a `.git` file points at: its `gitdir:` line. Nothing for a
   --  file without one or with an empty path.
   function Parse_Git_Dir_File (Content : String) return Maybe_Text;

   --  The branch HEAD names, from `ref: refs/heads/{branch}`. Nothing for a
   --  detached HEAD (a bare hash), for a reference outside `refs/heads/` and
   --  for an empty branch.
   function Parse_Head (Content : String) return Maybe_Text;

   --  The url of the remote named Preferred in a git config, else of the first
   --  remote in file order. Comments, quotes, a trailing `;` or `#` comment,
   --  `[remote "name"]` and the old `[remote.name]` are understood; the key is
   --  not case-sensitive.
   function Remote_Url_From_Config
     (Config, Preferred : String) return Maybe_Text;

   --  Where a checkout's git data lives.
   type Layout is record
      --  The directory that holds `.git`.
      Repo_Root  : Unbounded_String;
      --  Data of this worktree: `HEAD` is here.
      Git_Dir    : Unbounded_String;
      --  Data shared by the worktrees: `config` is here. The same as Git_Dir
      --  outside a linked worktree.
      Common_Dir : Unbounded_String;
   end record;

   --  A namespace and everything it was derived from.
   type Resolved is record
      Where      : Layout;
      --  The remote url used as identity, or the repository root.
      Remote     : Unbounded_String;
      Branch     : Unbounded_String;  --  as HEAD names it
      Branch_Key : Unbounded_String;  --  as a directory name
      Key        : Unbounded_String;  --  `repo@branch`
   end record;

   Not_A_Git_Repo : exception;

   --  A detached HEAD has no branch and so no namespace. `rev-parse` would
   --  say `HEAD` for every detached checkout, a key they would all share.
   Detached_Head : exception;

   Detached_Message : constant String :=
     "synapse: detached HEAD -- a namespace is keyed by branch, so there is "
     & "none here";

end Synapse.Core.Identity;
