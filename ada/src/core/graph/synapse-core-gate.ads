with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.Text_Lists;

--  The quality gate for clustering: does a cluster own any vocabulary of its
--  own?
--
--  Input is a table of `cluster <TAB> word <TAB> count` rows. A cluster whose
--  most frequent words are all words half the other clusters also have is
--  either not a cluster or has been named after a layer, and this finds it.
--  A short row is skipped; a count that is not a number reads as zero, since
--  the row still proves the word occurs in the cluster; a word listed twice
--  in one cluster counts once and keeps the larger count.

package Synapse.Core.Gate is

   use Ada.Strings.Unbounded;

   type Status is (Ok,
      --  At most one rare word among the top ones: no vocabulary of its own,
      --  or it looks that way.
      Flagged,
      --  Would have been flagged, but none of the cluster's files could be
      --  parsed, so the count of rare words says nothing about it.
      Unparseable);

   type Verdict is record
      Cluster : Unbounded_String;
      --  How many of the top words are rare across clusters.
      Rare    : Natural := 0;
      State   : Status  := Ok;
      --  The top words, most frequent first, ties by name.
      Top     : Text_Lists.Vector;
   end record;

   package Verdict_Vectors is new Ada.Containers.Vectors (Positive, Verdict);

   type Options is record
      --  Words per cluster the rule looks at.
      Top         : Natural := 8;
      --  Clusters none of whose files had a usable grammar. A cluster not
      --  listed is judged by its words: no data is not the claim that
      --  nothing parses.
      Unparseable : Text_Lists.Set;
   end record;

   --  Judges every cluster, in the order the table first names them. A word
   --  is rare when at most `Rare_Max (clusters)` clusters contain it.
   function Judge
     (Table : String; Settings : Options := (others => <>))
      return Verdict_Vectors.Vector;

   --  `cluster <TAB> rare <TAB> flagged|ok|unparseable <TAB> top words
   --  separated by spaces`, and a line feed.
   function Verdict_Line (V : Verdict) return String;

   type Distinctiveness_Options is record
      Top : Natural := 8;
      --  The scaling constant: what share of the groups a word may be in and
      --  still count as half distinctive. 20 is the calibration `Judge` uses
      --  for its own threshold; a larger K asks a word to be rarer.
      K   : Natural := 20;
   end record;

   --  How many of a group's top words score above one half, of how many were
   --  considered. A count and not a sum of scores: summed scores let many
   --  middling words stand in for a distinctive one.
   type Distinctiveness_Row is record
      Group       : Unbounded_String;
      Distinctive : Natural := 0;
      Considered  : Natural := 0;
   end record;

   package Row_Vectors is new Ada.Containers.Vectors
     (Positive, Distinctiveness_Row);

   --  Scores the top words of every group of a `group <TAB> word <TAB> count`
   --  table, the table written before any clustering exists. Every group
   --  appears, one scoring zero included, since leaving it out would read as
   --  not computed.
   function Judge_Distinctiveness
     (Table : String; Settings : Distinctiveness_Options := (others => <>))
      return Row_Vectors.Vector;

   --  `group <TAB> distinctive <TAB> considered`, and a line feed.
   function Distinctiveness_Line (Row : Distinctiveness_Row) return String;

end Synapse.Core.Gate;
