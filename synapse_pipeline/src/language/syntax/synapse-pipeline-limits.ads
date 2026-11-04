--  The largest values the language accepts for the settings that repeat a
--  paid agent session. A value above one is a mistake, so validation
--  refuses it, and the types below carry the bound to every later use.

package Synapse.Pipeline.Limits is

   --  The most retries a step may have, and the most times an edge may fire.
   Largest_Repeat : constant := 100;

   subtype Repeat_Count is Natural range 0 .. Largest_Repeat;

end Synapse.Pipeline.Limits;
