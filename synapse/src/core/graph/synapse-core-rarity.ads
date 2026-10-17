--  The one number behind two independent rarity floors: the vocabulary
--  judgement of a cluster and the reference weighting of the link graph both
--  compute `max (2, N / 20)`, over different entities (words per cluster,
--  symbols per node) and with no other dependency between them. The function
--  is one line of arithmetic, but the 20 recalibrating in one place and not
--  the other, silently, is a real risk, so it has one name.

package Synapse.Core.Rarity is

   --  Below this many clusters or nodes sharing a word or a symbol, it counts
   --  as rare.
   Divisor : constant := 20;

   --  The most clusters or nodes that may share something for it to count as
   --  rare, among Count of them. A floor of 2 applies whatever the count.
   function Rare_Max (Count : Natural) return Positive is
     (Natural'Max (2, Count / Divisor));

end Synapse.Core.Rarity;
