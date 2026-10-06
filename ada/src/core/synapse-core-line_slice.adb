package body Synapse.Core.Line_Slice is

   function Next_Line_Feed (Text : String; From : Integer) return Natural is
   begin
      for I in Integer'Max (From, Text'First) .. Text'Last loop
         if Text (I) = LF then
            return I;
         end if;
      end loop;
      return 0;
   end Next_Line_Feed;

   function Count_Lines (Text : String) return Natural is
      Count : Natural := 0;
   begin
      for C of Text loop
         if C = LF then
            Count := Count + 1;
         end if;
      end loop;
      return Count;
   end Count_Lines;

   function Bounds (Text : String; First, Last : Natural) return Maybe_Bounds
   is
      Line : Natural := 1;
      Here : Integer := Text'First;
      From : Integer := 0;
   begin
      if First = 0 or else Last < First then
         return (Found => False);
      end if;
      while Here <= Text'Last + 1 loop
         if Line = First and then From = 0 then
            From := Here;
         end if;
         declare
            Stop : constant Natural := Next_Line_Feed (Text, Here);
         begin
            if Line = Last then
               return
                 (Found => True, From => From,
                  To    => (if Stop = 0 then Text'Last else Stop));
            end if;
            exit when Stop = 0;
            Here := Stop + 1;
            Line := Line + 1;
         end;
      end loop;
      return (Found => False);
   end Bounds;

end Synapse.Core.Line_Slice;
