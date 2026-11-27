with Synapse.Core.Text_Lists;

package body Synapse.Pipeline.Definition_Copies is

   use Ada.Strings.Unbounded;

   Directory : constant String := "synapse-pipeline/";

   function Collect
     (Files         : File_System.File_System'Class;
      Item          : Resolved.Pipeline;
      Pipeline_File : String)
      return Copy_Vectors.Vector
   is
      Result : Copy_Vectors.Vector;
      Seen   : Synapse.Core.Text_Lists.Sets.Set;

      --  Keeps the file Source under Path, once.
      procedure Add (Path, Source : String) is
         Found : constant File_System.Maybe_Content := Files.Read (Source);
      begin
         if Found.Found and then not Seen.Contains (Path) then
            Seen.Insert (Path);
            Result.Append
              (Copy'(Path    => To_Unbounded_String (Path),
                     Content => Found.Value));
         end if;
      end Add;
   begin
      Add (Directory & To_String (Item.Name) & ".synapse", Pipeline_File);
      for S of Item.Steps loop
         for O of S.Origins loop
            Add
              (Directory & To_String (O.Name) & ".synapse",
               To_String (O.File));
         end loop;
      end loop;
      return Result;
   end Collect;

end Synapse.Pipeline.Definition_Copies;
