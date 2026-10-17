with Ada.Directories;

with Synapse.Adapters.File_Bytes;
with Synapse.Adapters.Replace_File;

package body Synapse.Adapters.Atomic_File is

   --  The directory part of Path, or "" when it has none.
   function Directory_Of (Path : String) return String is
   begin
      return Ada.Directories.Containing_Directory (Path);
   exception
      when others =>
         return "";
   end Directory_Of;

   procedure Write (Path, Bytes : String) is
      Tmp : constant String := Path & ".tmp";
      Dir : constant String := Directory_Of (Path);
   begin
      if Dir /= "" then
         Ada.Directories.Create_Path (Dir);
      end if;
      begin
         File_Bytes.Write (Tmp, Bytes);
         Replace_File.Replace (Tmp, Path);
      exception
         when others =>
            if Ada.Directories.Exists (Tmp) then
               Ada.Directories.Delete_File (Tmp);
            end if;
            raise;
      end;
   end Write;

end Synapse.Adapters.Atomic_File;
