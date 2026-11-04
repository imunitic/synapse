with Interfaces.C;
with System;

package body Synapse.Pipeline.Entropy is

   use type Interfaces.C.unsigned_char;

   --  RtlGenRandom, which advapi32 exports under this name.
   function Random_Bytes
     (Buffer : System.Address; Length : Interfaces.C.unsigned_long)
      return Interfaces.C.unsigned_char
   with Import, Convention => Stdcall, External_Name => "SystemFunction036";

   procedure Fill
     (Item : out Ada.Streams.Stream_Element_Array; Ok : out Boolean) is
   begin
      Item := [others => 0];
      Ok :=
        Item'Length = 0
        or else Random_Bytes
          (Item (Item'First)'Address, Interfaces.C.unsigned_long (Item'Length))
          /= 0;
   end Fill;

end Synapse.Pipeline.Entropy;
