with Synapse.Pipeline.Session_Process;
with Synapse.Pipeline.Working_Trees;

--  Working trees as git sees them. A snapshot is the tree object made from a
--  temporary index, in the folder for temporary files and removed at once,
--  which starts empty and is brought to the working tree by `add -A`: new
--  files in, deleted files out, ignored files left out. The real index is
--  never touched, so nothing is staged. Every file is read for it, so it
--  takes as long as reading the working tree does.

package Synapse.Pipeline.Git_Working_Trees is

   type Git_Working_Trees
     (Process : not null access Session_Process.Process'Class)
   is limited new Working_Trees.Working_Tree with null record;

   overriding
   function Snapshot
     (T : in out Git_Working_Trees; Directory, Name : String)
      return Working_Trees.Maybe_Text;

   overriding
   function Changes
     (T : in out Git_Working_Trees; Directory, Before, After : String)
      return Working_Trees.Maybe_Text;

end Synapse.Pipeline.Git_Working_Trees;
