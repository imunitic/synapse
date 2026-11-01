package body Synapse.Pipeline.Permission_Levels is

   function Find (Name : String) return Level_Options.Option is
   begin
      for Item in Level loop
         if Name = Name_Of (Item) then
            return Level_Options.Of_Value (Item);
         end if;
      end loop;
      return Level_Options.None;
   end Find;

   function Names return String is
     (Name_Of (Read_Only) & ", " & Name_Of (Workspace_Write) & ", "
      & Name_Of (Full_Access));

end Synapse.Pipeline.Permission_Levels;
