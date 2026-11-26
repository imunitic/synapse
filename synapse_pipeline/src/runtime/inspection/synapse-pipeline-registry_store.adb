package body Synapse.Pipeline.Registry_Store is

   function Is_Plain_Name (Name : String) return Boolean is
     (Name'Length > 0 and then Name (Name'First) /= '.'
      and then (for all C of Name => C not in '/' | '\' | ':'));

   function Is_Plain_Path (Path : String) return Boolean is
      Start : Positive := Path'First;
   begin
      if Path'Length = 0 then
         return False;
      end if;
      for I in Path'Range loop
         if Path (I) = '/' then
            if not Is_Plain_Name (Path (Start .. I - 1)) then
               return False;
            end if;
            Start := I + 1;
         end if;
      end loop;
      return Is_Plain_Name (Path (Start .. Path'Last));
   end Is_Plain_Path;

   function Is_Run_Name (Name : String) return Boolean is
      Characters : Natural := 0;
      Not_Space  : Boolean := False;
   begin
      for C of Name loop
         if Character'Pos (C) < 16#20# or else Character'Pos (C) = 16#7F#
         then
            return False;
         end if;
         --  A continuation byte of UTF-8 is part of the character before it.
         if Character'Pos (C) not in 16#80# .. 16#BF# then
            Characters := Characters + 1;
         end if;
         if C /= ' ' then
            Not_Space := True;
         end if;
      end loop;
      return Characters in 1 .. Longest_Run_Name and then Not_Space;
   end Is_Run_Name;

end Synapse.Pipeline.Registry_Store;
