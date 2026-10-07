with Ada.Finalization;

with Synapse.Ports.Byte_Source;

--  A block of a byte source kept at hand, so that reading a table record by
--  record, or a run of short strings in order, asks the source for one block
--  and not for each of them.

package Synapse.Core.Byte_Window is

   Default_Block : constant := 65_536;

   type Window is limited private;

   --  The Count bytes at From: fewer when the source ends first, none at or
   --  past its end. A read the cached block holds does not touch the source;
   --  any other loads a block that starts at From, or the read itself when it
   --  is larger than a block.
   function Read
     (W    : in out Window; Source : in out Ports.Byte_Source.Source'Class;
      From :        Ports.Byte_Source.Offset; Count : Positive) return String;

private

   type Text_Access is access String;

   type Window is new Ada.Finalization.Limited_Controlled with record
      Start : Ports.Byte_Source.Offset := 0;
      Data  : Text_Access              := null;
   end record;

   overriding procedure Finalize (W : in out Window);

end Synapse.Core.Byte_Window;
