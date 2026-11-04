with Ada.Streams;

--  Random bytes from the operating system's own source, the one a clock cannot
--  stand in for: two programs started in the same instant do not get the same
--  bytes.

package Synapse.Pipeline.Entropy is

   --  Fills Item. Ok is False when the system gave nothing, and Item is then
   --  not to be used.
   procedure Fill
     (Item : out Ada.Streams.Stream_Element_Array; Ok : out Boolean);

end Synapse.Pipeline.Entropy;
