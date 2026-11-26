with Ada.Strings.Unbounded;

with Synapse.Core.Text_Lists;
with Synapse.Pipeline.Working_Trees;

--  Working trees that are told what to answer: the snapshots in order, and
--  the one patch every comparison gives. It records what it was asked.

package Synapse.Pipeline.Fake_Working_Trees is

   type Fake_Working_Trees is limited new Working_Trees.Working_Tree
   with record
      --  Handed out one to each snapshot asked for; a snapshot past the last
      --  finds no repository.
      Snapshots  : Synapse.Core.Text_Lists.Vector;
      Taken      : Natural := 0;

      --  What a comparison answers when Patch_Known; nothing otherwise.
      Patch       : Ada.Strings.Unbounded.Unbounded_String;
      Patch_Known : Boolean := False;

      --  What snapshots were asked for: the directory and the name of each.
      Directories : Synapse.Core.Text_Lists.Vector;
      Names       : Synapse.Core.Text_Lists.Vector;

      --  What comparisons were asked for, each as `before..after`.
      Compared    : Synapse.Core.Text_Lists.Vector;

      --  What was pinned, each as `ref=tree`, and what was unpinned, each
      --  ref. A pin fails, and is not recorded, when Pin_Fails.
      Pinned      : Synapse.Core.Text_Lists.Vector;
      Unpinned    : Synapse.Core.Text_Lists.Vector;
      Pin_Fails   : Boolean := False;
   end record;

   overriding
   function Snapshot
     (T : in out Fake_Working_Trees; Directory, Name : String)
      return Working_Trees.Maybe_Text;

   overriding
   function Changes
     (T : in out Fake_Working_Trees; Directory, Before, After : String)
      return Working_Trees.Maybe_Text;

   overriding
   function Pin
     (T : in out Fake_Working_Trees; Directory, Ref, Tree : String)
      return Boolean;

   overriding
   procedure Unpin (T : in out Fake_Working_Trees; Directory, Ref : String);

end Synapse.Pipeline.Fake_Working_Trees;
