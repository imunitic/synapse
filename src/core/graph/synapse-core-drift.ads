with Synapse.Core.Text_Lists;

--  What changed in the tree since a node was built, and what that means.
--
--  `stale` re-hashes what a node claims; `drift` compares its recorded
--  `commit` with HEAD. Only drift sees added, deleted and renamed paths, since
--  a comparison of hashes over a list of paths cannot notice a file that is no
--  longer in the list. Neither pulls.
--
--  This is the part that is a function of what git prints and not of git:
--  parsing `--name-status -M`, intersecting a node's paths with what moved,
--  and deciding which finding that is.
--
--  Modified, deleted and renamed are three findings and not one, because a
--  rename is the only class that can be fixed without writing the node again:
--  the concept did not change, the paths did. Calling a rename changed content
--  would send someone to rewrite prose that is still right.

package Synapse.Core.Drift is

   --  The classes of change a node can care about, each sorted bytewise so
   --  that every intersection below is one merge pass.
   type Diff is record
      Modified     : Text_Lists.Vector;
      Deleted      : Text_Lists.Vector;
      --  The old path of each rename (`R100 <TAB> old <TAB> new`): what a node
      --  still lists, so it is the side to intersect.
      Renamed_From : Text_Lists.Vector;
      Added        : Text_Lists.Vector;
   end record;

   --  Parses `git diff --name-status -M <base>..HEAD`. A status letter can
   --  carry a similarity score (`R100`, `M`), so each class is a prefix test.
   --  A rename or copy has three fields and the old path is the second; for
   --  any other status the rest of the line is the whole path, a tab included,
   --  since a path may legally have one. Other classes (type changes,
   --  conflicts) are not reported on and are left out. Each class is sorted
   --  here and not by the caller: every use is an intersection, and an
   --  unsorted side finds nothing.
   function Parse_Name_Status (Raw : String) return Diff;

   --  How many paths two bytewise sorted lists share: `comm -12 | grep -c .`
   --  in process, so that no locale can disagree with the sort that fed it.
   function Count_Intersect (A, B : Text_Lists.Vector) return Natural;

   --  How one node's own paths intersect a diff.
   type Node_Drift is record
      Modified : Natural := 0;
      Renamed  : Natural := 0;
      Deleted  : Natural := 0;
   end record;

   function Any (D : Node_Drift) return Boolean is
     (D.Modified > 0 or else D.Renamed > 0 or else D.Deleted > 0);

   --  Paths must be sorted bytewise. An added path is never a node's drift: it
   --  is the repository's.
   function Of_Node
     (Paths : Text_Lists.Vector; Changes : Diff) return Node_Drift;

   --  A `node <TAB> reason` row names a node; this names a finding about the
   --  repository instead.
   Repo_Scope : constant String := "(repo)";

   --  The lines of one node, modified, then renamed, then deleted: a rename
   --  carries the one remedy that needs no re-reading, so it comes before a
   --  deletion that might otherwise be the only line anyone reads. Nothing for
   --  a node that did not drift.
   function Findings (Node_Without_Md : String; D : Node_Drift) return String;

   --  Why a node could not be compared at all, as opposed to having drifted.
   --  Each points at `stale` instead, since re-hashing needs no baseline.
   type Undiffable_Kind is
     (Node_File_Missing, No_Commit_Recorded, Baseline_Absent);

   --  The line for a node that could not be compared. Commit names the
   --  recorded commit for Baseline_Absent, which is not in this clone's
   --  history: a shallow clone, or a baseline from a branch never fetched.
   function Undiffable_Line
     (Node_Without_Md : String; Kind : Undiffable_Kind; Commit : String := "")
      return String;

   --  The first twelve characters; shorter input whole, not padded.
   function Short_Commit (Commit : String) return String;

end Synapse.Core.Drift;
