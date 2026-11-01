package body Synapse.Pipeline.Harnesses is

   use Ada.Strings.Unbounded;

   function Find (Name : String) return Kind_Options.Option is
   begin
      for Kind in Harness_Kind loop
         if Name = Name_Of (Kind) then
            return Kind_Options.Of_Value (Kind);
         end if;
      end loop;
      return Kind_Options.None;
   end Find;

   function Default
     (V : Synapse.Ports.Variables.Variables'Class)
      return Default_Results.Result
   is
      Set : constant Synapse.Ports.Variables.Maybe_Value :=
        V.Get (Default_Variable);
   begin
      if not Set.Found or else Length (Set.Value) = 0 then
         return Default_Results.Success (Kind_Options.None);
      end if;
      declare
         Found : constant Kind_Options.Option := Find (To_String (Set.Value));
      begin
         if Found.Found then
            return Default_Results.Success (Found);
         end if;
         return Default_Results.Failure
           (To_Unbounded_String
              (Default_Variable & " is '" & To_String (Set.Value)
               & "', which is not a harness; the harnesses are " & Names));
      end;
   end Default;

   function Names return String is
     (Name_Of (Claude) & ", " & Name_Of (Codex) & ", " & Name_Of (Opencode));

end Synapse.Pipeline.Harnesses;
