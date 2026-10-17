with Ada.Unchecked_Deallocation;

with GNAT.CRC32;

package body Synapse.Core.Byte_Window is

   use Ports.Byte_Source;

   procedure Free is new Ada.Unchecked_Deallocation (String, Text_Access);

   overriding procedure Finalize (W : in out Window) is
   begin
      Free (W.Data);
   end Finalize;

   function Checksum
     (Source : in out Ports.Byte_Source.Source'Class;
      From, Stop : Ports.Byte_Source.Offset; Block : Positive)
      return Interfaces.Unsigned_32
   is
      Crc  : GNAT.CRC32.CRC32;
      Here : Offset := From;
   begin
      GNAT.CRC32.Initialize (Crc);
      while Here < Stop loop
         declare
            Chunk : constant String :=
              Source.Read (Here, Positive'Min (Block, Positive (Stop - Here)));
         begin
            exit when Chunk'Length = 0;
            GNAT.CRC32.Update (Crc, Chunk);
            Here := Here + Offset (Chunk'Length);
         end;
      end loop;
      return GNAT.CRC32.Get_Value (Crc);
   end Checksum;

   function Read
     (W    : in out Window; Source : in out Ports.Byte_Source.Source'Class;
      From :        Ports.Byte_Source.Offset; Count : Positive) return String
   is
   begin
      if W.Data /= null and then From >= W.Start
        and then From + Offset (Count) <= W.Start + Offset (W.Data'Length)
      then
         declare
            First : constant Positive := Positive (From - W.Start) + 1;
         begin
            return W.Data (First .. First + Count - 1);
         end;
      end if;

      declare
         Block : constant String :=
           Source.Read (From, Positive'Max (Count, Default_Block));
      begin
         --  A short block at the end of the source is cached as it is.
         Free (W.Data);
         W.Start := From;
         W.Data  := new String'(Block);
         return
           Block
             (Block'First ..
                  Block'First - 1 + Natural'Min (Count, Block'Length));
      end;
   end Read;

end Synapse.Core.Byte_Window;
