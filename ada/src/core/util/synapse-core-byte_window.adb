with Ada.Unchecked_Deallocation;

package body Synapse.Core.Byte_Window is

   use Ports.Byte_Source;

   procedure Free is new Ada.Unchecked_Deallocation (String, Text_Access);

   overriding procedure Finalize (W : in out Window) is
   begin
      Free (W.Data);
   end Finalize;

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
