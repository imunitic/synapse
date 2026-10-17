package body Synapse.Adapters.Memory_Byte_Source is

   use Ada.Strings.Unbounded;

   function Create (Content : String) return Source is
     (Ports.Byte_Source.Source with Content => To_Unbounded_String (Content));

   overriding function Size
     (S : in out Source) return Ports.Byte_Source.Offset is
     (Ports.Byte_Source.Offset (Length (S.Content)));

   overriding function Read
     (S : in out Source; From : Ports.Byte_Source.Offset; Count : Positive)
      return String
   is
      Total : constant Natural := Length (S.Content);
   begin
      if From >= Ports.Byte_Source.Offset (Total) then
         return "";
      end if;
      declare
         First : constant Positive := Natural (From) + 1;
         Last  : constant Natural  := Natural'Min (Total, First - 1 + Count);
      begin
         declare
            Part : constant String := Slice (S.Content, First, Last);
         begin
            --  Indexed from 1 whatever the slice's own bounds are.
            return Result : constant String (1 .. Part'Length) := Part;
         end;
      end;
   end Read;

end Synapse.Adapters.Memory_Byte_Source;
