package body Synapse.Pipeline.Commands.Usage is

   function Synopsis (Help : String) return String is
   begin
      for I in Help'Range loop
         if Help (I) = LF then
            return Help (Help'First .. I);
         end if;
      end loop;
      return Help & LF;
   end Synopsis;

end Synapse.Pipeline.Commands.Usage;
