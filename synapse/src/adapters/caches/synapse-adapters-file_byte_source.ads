with Ada.Finalization;
with Ada.Streams.Stream_IO;

with Synapse.Ports.Byte_Source;

--  A file as a byte source, read in blocks at the position asked for. Closed
--  when the source goes out of scope. Files past two gigabytes work.

package Synapse.Adapters.File_Byte_Source is

   type Source is
     limited new Ada.Finalization.Limited_Controlled and
       Ports.Byte_Source.Source with private;

   --  Raises Source_Failure when the file cannot be opened.
   procedure Open (S : in out Source; Path : String);

   --  Releases the file; the source can be opened again.
   procedure Close (S : in out Source);

   overriding function Size
     (S : in out Source) return Ports.Byte_Source.Offset;

   --  Raises Source_Failure when the file cannot be read.
   overriding function Read
     (S : in out Source; From : Ports.Byte_Source.Offset; Count : Positive)
      return String;

   overriding procedure Finalize (S : in out Source);

private

   type Source is
   limited new Ada.Finalization.Limited_Controlled and
     Ports.Byte_Source.Source with record
      File : Ada.Streams.Stream_IO.File_Type;
   end record;

end Synapse.Adapters.File_Byte_Source;
