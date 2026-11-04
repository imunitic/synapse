package body Synapse.Pipeline.Durations is

   function Seconds (Text : String) return Timeout_Seconds is
      --  A count above Largest_Seconds is a duration above it in every unit,
      --  so the count stays small enough for the products below to fit.
      Count : Long_Long_Integer := 0;
      Total : Long_Long_Integer;
   begin
      if Text'Length < 2 then
         return 0;
      end if;
      for I in Text'First .. Text'Last - 1 loop
         if Text (I) not in '0' .. '9' then
            return 0;
         end if;
         Count :=
           Count * 10
           + Long_Long_Integer
               (Character'Pos (Text (I)) - Character'Pos ('0'));
         if Count > Largest_Seconds then
            return 0;
         end if;
      end loop;
      case Text (Text'Last) is
         when 's'    => Total := Count;
         when 'm'    => Total := Count * 60;
         when 'h'    => Total := Count * 3600;
         when others => return 0;
      end case;
      if Total > Largest_Seconds then
         return 0;
      end if;
      return Timeout_Seconds (Total);
   end Seconds;

end Synapse.Pipeline.Durations;
