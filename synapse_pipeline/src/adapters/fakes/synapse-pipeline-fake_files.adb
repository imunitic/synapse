package body Synapse.Pipeline.Fake_Files is

   --  The directory part of Path: everything before its last slash.
   function Parent (Path : String) return String is
   begin
      for I in reverse Path'Range loop
         if Path (I) = '/' then
            return Path (Path'First .. I - 1);
         end if;
      end loop;
      return "";
   end Parent;

   procedure Add_Directory (F : in out Fake_Files; Path : String) is
      Dir : constant String := Parent (Path);
   begin
      if Path /= "" then
         F.Directories.Include (Path);
         if Dir /= "" and then Dir /= Path then
            Add_Directory (F, Dir);
         end if;
      end if;
   end Add_Directory;

   procedure Add_File (F : in out Fake_Files; Path, Content : String) is
   begin
      F.Files.Include (Path, Content);
      Add_Directory (F, Parent (Path));
   end Add_File;

   --  A directory is the same with or without a slash at its end.
   function Without_Slash (Path : String) return String is
     (if Path'Length > 1 and then Path (Path'Last) = '/'
      then Path (Path'First .. Path'Last - 1)
      else Path);

   overriding
   function Is_Directory (F : Fake_Files; Path : String) return Boolean is
     (F.Directories.Contains (Without_Slash (Path)));

   overriding
   function Is_File (F : Fake_Files; Path : String) return Boolean is
     (F.Files.Contains (Path));

   overriding
   function List
     (F : Fake_Files; Directory, Extension : String)
      return Synapse.Core.Text_Lists.Vector
   is
      Result : Synapse.Core.Text_Lists.Vector;
      Parent_Directory : constant String := Without_Slash (Directory);
   begin
      for C in F.Files.Iterate loop
         declare
            Path : constant String := Contents.Key (C);
         begin
            if Parent (Path) = Parent_Directory then
               declare
                  Name : constant String :=
                    Path (Path'First + Parent_Directory'Length + 1
                          .. Path'Last);
               begin
                  if Name'Length >= Extension'Length
                    and then Name (Name'Last - Extension'Length + 1
                                   .. Name'Last) = Extension
                  then
                     Result.Append
                       (Ada.Strings.Unbounded.To_Unbounded_String (Name));
                  end if;
               end;
            end if;
         end;
      end loop;
      return Result;
   end List;

   overriding
   function Current_Directory (F : Fake_Files) return String is
     (Ada.Strings.Unbounded.To_String (F.Here));

   overriding
   function Read
     (F : Fake_Files; Path : String) return File_System.Maybe_Content is
   begin
      if F.Unreadable.Contains (Path) or else not F.Files.Contains (Path) then
         return (Found => False);
      end if;
      return
        (Found => True,
         Value => Ada.Strings.Unbounded.To_Unbounded_String
                    (F.Files.Element (Path)));
   end Read;

end Synapse.Pipeline.Fake_Files;
