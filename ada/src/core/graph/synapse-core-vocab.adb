package body Synapse.Core.Vocab is

   function Group_Of (Path : String; Depth : Natural) return String is
      Segments : Natural := 1;
   begin
      for C of Path loop
         if C = '/' then
            Segments := Segments + 1;
         end if;
      end loop;
      declare
         Limit : constant Natural := Natural'Min (Segments - 1, Depth);
         Seen  : Natural          := 0;
      begin
         if Limit < 1 then
            return Repo_Root_Group;
         end if;
         for At_Index in Path'Range loop
            if Path (At_Index) = '/' then
               Seen := Seen + 1;
               if Seen = Limit then
                  return Path (Path'First .. At_Index - 1);
               end if;
            end if;
         end loop;
         return Path;
      end;
   end Group_Of;

   function Artifact_Of (Path : String) return String is
      Base_First : Positive := Path'First;
      Dot        : Natural  := 0;
   begin
      for I in reverse Path'Range loop
         if Path (I) = '/' then
            Base_First := I + 1;
            exit;
         end if;
      end loop;
      for I in reverse Base_First .. Path'Last loop
         if Path (I) = '.' then
            Dot := I;
            exit;
         end if;
      end loop;
      declare
         From   : constant Positive :=
           (if Dot = 0 or else Dot = Path'Last then Base_First else Dot + 1);
         Result : String            := Path (From .. Path'Last);
      begin
         for C of Result loop
            if C in 'A' .. 'Z' then
               C := Character'Val (Character'Pos (C) + 32);
            end if;
         end loop;
         return Result;
      end;
   end Artifact_Of;

end Synapse.Core.Vocab;
