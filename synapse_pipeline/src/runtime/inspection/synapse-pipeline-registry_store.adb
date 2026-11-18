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

end Synapse.Pipeline.Registry_Store;
