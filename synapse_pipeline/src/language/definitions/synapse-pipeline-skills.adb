with Ada.Strings.Unbounded;

package body Synapse.Pipeline.Skills is

   use Ada.Strings.Unbounded;

   function Is_Valid_Name (Name : String) return Boolean is
   begin
      if Name'Length not in 1 .. 64 then
         return False;
      end if;
      for I in Name'Range loop
         if Name (I) not in 'a' .. 'z' | '0' .. '9' | '-' then
            return False;
         end if;
      end loop;
      return Name (Name'First) /= '-' and then Name (Name'Last) /= '-'
        and then
          (for all I in Name'First .. Name'Last - 1 =>
             Name (I .. I + 1) /= "--");
   end Is_Valid_Name;

   function Join (Directory, Name : String) return String is
     (if Directory'Length > 0 and then Directory (Directory'Last) = '/'
      then Directory & Name
      else Directory & "/" & Name);

   function Find
     (Files : File_System.File_System'Class;
      Roots : Search_Paths.Root_Vectors.Vector; Name : String)
      return Synapse.Core.Optional_Text.Option
   is
   begin
      for R of Roots loop
         declare
            Directory : constant String := Join (To_String (R.Path), Name);
         begin
            if Files.Is_File (Join (Directory, "SKILL.md")) then
               return Synapse.Core.Optional_Text.Of_Value
                 (To_Unbounded_String (Directory));
            end if;
         end;
      end loop;
      return Synapse.Core.Optional_Text.None;
   end Find;

   function Searched (Roots : Search_Paths.Root_Vectors.Vector) return String
   is
      Result : Unbounded_String;
   begin
      for R of Roots loop
         if Length (Result) > 0 then
            Append (Result, ", ");
         end if;
         Append (Result, R.Path);
      end loop;
      return To_String (Result);
   end Searched;

end Synapse.Pipeline.Skills;
