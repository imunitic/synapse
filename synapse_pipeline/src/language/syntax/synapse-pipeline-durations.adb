package body Synapse.Pipeline.Durations is

   --  Large enough to be a limit and small enough that no unit overflows.
   Largest : constant := 10_000_000;

   function Seconds (Text : String) return Natural is
      Count : Natural := 0;
   begin
      if Text'Length < 2 then
         return 0;
      end if;
      for I in Text'First .. Text'Last - 1 loop
         if Text (I) not in '0' .. '9' then
            return 0;
         end if;
         Count :=
           Count * 10 + (Character'Pos (Text (I)) - Character'Pos ('0'));
         if Count > Largest then
            return 0;
         end if;
      end loop;
      case Text (Text'Last) is
         when 's'    => return Count;
         when 'm'    => return Count * 60;
         when 'h'    => return Count * 3600;
         when others => return 0;
      end case;
   end Seconds;

end Synapse.Pipeline.Durations;
