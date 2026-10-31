with Ada.Directories;
with Ada.Streams.Stream_IO;
with Ada.Strings.Unbounded;

package body Synapse.Pipeline.System_Files is

   package Dirs renames Ada.Directories;

   use type Dirs.File_Kind;

   overriding
   function Is_Directory (F : System_Files; Path : String) return Boolean is
      pragma Unreferenced (F);
   begin
      return Path /= "" and then Dirs.Exists (Path)
        and then Dirs.Kind (Path) = Dirs.Directory;
   exception
      when Ada.Directories.Name_Error | Ada.Directories.Use_Error =>
         return False;
   end Is_Directory;

   overriding
   function Is_File (F : System_Files; Path : String) return Boolean is
      pragma Unreferenced (F);
   begin
      return Path /= "" and then Dirs.Exists (Path)
        and then Dirs.Kind (Path) = Dirs.Ordinary_File;
   exception
      when Ada.Directories.Name_Error | Ada.Directories.Use_Error =>
         return False;
   end Is_File;

   overriding
   function List
     (F : System_Files; Directory, Extension : String)
      return Synapse.Core.Text_Lists.Vector
   is
      Names  : Synapse.Core.Text_Lists.Sets.Set;
      Result : Synapse.Core.Text_Lists.Vector;
      Search : Dirs.Search_Type;
      Item   : Dirs.Directory_Entry_Type;
   begin
      if not Is_Directory (F, Directory) then
         return Result;
      end if;
      Dirs.Start_Search
        (Search, Directory, "", [Dirs.Ordinary_File => True, others => False]);
      while Dirs.More_Entries (Search) loop
         Dirs.Get_Next_Entry (Search, Item);
         declare
            Name : constant String := Dirs.Simple_Name (Item);
         begin
            if Name'Length >= Extension'Length
              and then Name (Name'Last - Extension'Length + 1 .. Name'Last) =
                       Extension
            then
               Names.Include (Name);
            end if;
         end;
      end loop;
      Dirs.End_Search (Search);
      for Name of Names loop
         Result.Append (Ada.Strings.Unbounded.To_Unbounded_String (Name));
      end loop;
      return Result;
   exception
      when Ada.Directories.Name_Error | Ada.Directories.Use_Error =>
         return Result;
   end List;

   overriding
   function Current_Directory (F : System_Files) return String is
      pragma Unreferenced (F);
   begin
      return Dirs.Current_Directory;
   end Current_Directory;

   overriding
   function Read
     (F : System_Files; Path : String) return File_System.Maybe_Content
   is
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      if not Is_File (F, Path) then
         return (Found => False);
      end if;
      Ada.Streams.Stream_IO.Open
        (File, Ada.Streams.Stream_IO.In_File, Path);
      declare
         Size : constant Natural :=
           Natural (Ada.Streams.Stream_IO.Size (File));
      begin
         if Size > File_System.Max_File_Size then
            Ada.Streams.Stream_IO.Close (File);
            return (Found => False);
         end if;
         declare
            Text : String (1 .. Size);
         begin
            String'Read (Ada.Streams.Stream_IO.Stream (File), Text);
            Ada.Streams.Stream_IO.Close (File);
            return (Found => True, Value =>
                      Ada.Strings.Unbounded.To_Unbounded_String (Text));
         end;
      end;
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;
         return (Found => False);
   end Read;

end Synapse.Pipeline.System_Files;
