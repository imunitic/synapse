with Synapse.Core.Optional_Text;

--  Looking at the changes made in a working tree, so that a run can keep what
--  each session changed. Implementations are Git_Working_Trees, which asks
--  git, and Fake_Working_Trees, for tests.

package Synapse.Pipeline.Working_Trees is

   subtype Maybe_Text is Synapse.Core.Optional_Text.Option;

   type Working_Tree is limited interface;

   --  A snapshot of the working tree of Directory, which is empty for where
   --  the program is: the id of the tree object it is made into, or nothing
   --  when Directory is not in a git repository or git cannot be run. Name,
   --  a plain name, tells this snapshot from the others of the run. Nothing
   --  is committed, staged or stashed: the repository is left as it was, but
   --  for the objects the snapshot is made of.
   function Snapshot
     (T : in out Working_Tree; Directory, Name : String) return Maybe_Text
   is abstract;

   --  What changed between two snapshots of Directory, as `git diff` prints
   --  it, or nothing when it cannot be had. An empty text is no change.
   function Changes
     (T : in out Working_Tree; Directory, Before, After : String)
      return Maybe_Text
   is abstract;

   --  The ref that pins the snapshot Which ("start" or "end") of the run Id.
   function Run_Ref (Id, Which : String) return String is
     ("refs/synapse/runs/" & Id & "/" & Which);

   --  Points Ref, a ref outside refs/heads and refs/tags, at the tree object
   --  Tree in the repository of Directory, so that git gc keeps it. Nothing
   --  else in the repository changes. True when it is written.
   function Pin
     (T : in out Working_Tree; Directory, Ref, Tree : String) return Boolean
   is abstract;

   --  Deletes Ref in the repository of Directory; a ref that is not there,
   --  or a folder that is not in a repository, is left as it is.
   procedure Unpin (T : in out Working_Tree; Directory, Ref : String)
   is abstract;

end Synapse.Pipeline.Working_Trees;
