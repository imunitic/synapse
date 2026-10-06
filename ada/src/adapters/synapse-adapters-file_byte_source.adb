with Ada.IO_Exceptions;
with Ada.Streams;

package body Synapse.Adapters.File_Byte_Source is

   package SIO renames Ada.Streams.Stream_IO;

   use type Ada.Streams.Stream_Element_Offset;

   procedure Open (S : in out Source; Path : String) is
   begin
      if SIO.Is_Open (S.File) then
         SIO.Close (S.File);
      end if;
      SIO.Open (S.File, SIO.In_File, Path, Form => "shared=yes");
   exception
      when Ada.IO_Exceptions.Name_Error | Ada.IO_Exceptions.Use_Error =>
         raise Ports.Byte_Source.Source_Failure with "cannot open " & Path;
   end Open;

   procedure Close (S : in out Source) is
   begin
      if SIO.Is_Open (S.File) then
         SIO.Close (S.File);
      end if;
   end Close;

   overriding function Size (S : in out Source) return Ports.Byte_Source.Offset
   is
   begin
      return Ports.Byte_Source.Offset (SIO.Size (S.File));
   exception
      when others =>
         raise Ports.Byte_Source.Source_Failure;
   end Size;

   overriding function Read
     (S : in out Source; From : Ports.Byte_Source.Offset; Count : Positive)
      return String
   is
   begin
      if From >= Ports.Byte_Source.Offset (SIO.Size (S.File)) then
         return "";
      end if;
      declare
         Buffer :
           Ada.Streams.Stream_Element_Array
             (1 .. Ada.Streams.Stream_Element_Offset (Count));
         Last   : Ada.Streams.Stream_Element_Offset;
      begin
         SIO.Set_Index (S.File, SIO.Positive_Count (From + 1));
         SIO.Read (S.File, Buffer, Last);
         return Result : String (1 .. Natural (Last)) do
            for I in Result'Range loop
               Result (I) :=
                 Character'Val
                   (Buffer (Ada.Streams.Stream_Element_Offset (I)));
            end loop;
         end return;
      end;
   exception
      when Ada.IO_Exceptions.Device_Error | Ada.IO_Exceptions.Use_Error
        | Ada.IO_Exceptions.Mode_Error | Ada.IO_Exceptions.Status_Error =>
         raise Ports.Byte_Source.Source_Failure;
   end Read;

   overriding procedure Finalize (S : in out Source) is
   begin
      if SIO.Is_Open (S.File) then
         SIO.Close (S.File);
      end if;
   end Finalize;

end Synapse.Adapters.File_Byte_Source;
