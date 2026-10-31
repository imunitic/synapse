package body Synapse.Pipeline.Failures is

   function Find (Name : String) return Kind_Options.Option is
   begin
      for Kind in Failure_Kind loop
         if Name = Name_Of (Kind) then
            return Kind_Options.Of_Value (Kind);
         end if;
      end loop;
      return Kind_Options.None;
   end Find;

end Synapse.Pipeline.Failures;
