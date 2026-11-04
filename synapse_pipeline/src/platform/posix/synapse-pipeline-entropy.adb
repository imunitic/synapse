with Ada.Streams.Stream_IO;

package body Synapse.Pipeline.Entropy is

   use type Ada.Streams.Stream_Element_Offset;

   procedure Fill
     (Item : out Ada.Streams.Stream_Element_Array; Ok : out Boolean)
   is
      File : Ada.Streams.Stream_IO.File_Type;
      Last : Ada.Streams.Stream_Element_Offset;
   begin
      Item := [others => 0];
      Ada.Streams.Stream_IO.Open
        (File, Ada.Streams.Stream_IO.In_File, "/dev/urandom");
      Ada.Streams.Stream_IO.Read (File, Item, Last);
      Ada.Streams.Stream_IO.Close (File);
      Ok := Last = Item'Last;
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;
         Ok := False;
   end Fill;

end Synapse.Pipeline.Entropy;
