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

   overriding
   function Subdirectories
     (F : System_Files; Directory : String)
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
        (Search, Directory, "", [Dirs.Directory => True, others => False]);
      while Dirs.More_Entries (Search) loop
         Dirs.Get_Next_Entry (Search, Item);
         declare
            Name : constant String := Dirs.Simple_Name (Item);
         begin
            if Name not in "." | ".." then
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
   end Subdirectories;

   overriding
   procedure Write
     (F : in out System_Files; Path, Text : String; Done : out Boolean)
   is
      pragma Unreferenced (F);
      File : Ada.Streams.Stream_IO.File_Type;
   begin
      Done := False;
      Dirs.Create_Path (Dirs.Containing_Directory (Path));
      Ada.Streams.Stream_IO.Create
        (File, Ada.Streams.Stream_IO.Out_File, Path);
      String'Write (Ada.Streams.Stream_IO.Stream (File), Text);
      Ada.Streams.Stream_IO.Close (File);
      Done := True;
   exception
      when others =>
         if Ada.Streams.Stream_IO.Is_Open (File) then
            Ada.Streams.Stream_IO.Close (File);
         end if;
         Done := False;
   end Write;

   overriding
   procedure Remove_Tree (F : in out System_Files; Path : String) is
   begin
      if Path = "" or else not Dirs.Exists (Path) then
         return;
      end if;
      if Is_Directory (F, Path) then
         Dirs.Delete_Tree (Path);
      else
         Dirs.Delete_File (Path);
      end if;
   exception
      when Ada.Directories.Name_Error | Ada.Directories.Use_Error =>
         null;
   end Remove_Tree;

   --  Copies what is in the directory From into the directory To, which
   --  exists, one entry at a time, and the directories among them whole.
   procedure Copy_Into (F : in out System_Files; From, To : String) is
      Search : Dirs.Search_Type;
      Item   : Dirs.Directory_Entry_Type;
      Names  : Synapse.Core.Text_Lists.Sets.Set;
   begin
      Dirs.Start_Search
        (Search, From, "",
         [Dirs.Ordinary_File | Dirs.Directory => True, others => False]);
      while Dirs.More_Entries (Search) loop
         Dirs.Get_Next_Entry (Search, Item);
         if Dirs.Simple_Name (Item) not in "." | ".." then
            Names.Include (Dirs.Simple_Name (Item));
         end if;
      end loop;
      Dirs.End_Search (Search);
      for Name of Names loop
         declare
            Source : constant String := Dirs.Compose (From, Name);
            Target : constant String := Dirs.Compose (To, Name);
         begin
            if Is_Directory (F, Source) then
               Dirs.Create_Directory (Target);
               Copy_Into (F, Source, Target);
            else
               Dirs.Copy_File (Source, Target);
            end if;
         end;
      end loop;
   end Copy_Into;

   overriding
   procedure Replace_Tree
     (F : in out System_Files; Source, Destination : String;
      Done : out Boolean) is
   begin
      Done := False;
      if not Is_Directory (F, Source) or else Destination = "" then
         return;
      end if;
      Remove_Tree (F, Destination);
      Dirs.Create_Path (Destination);
      Copy_Into (F, Source, Destination);
      Done := True;
   exception
      when Ada.Directories.Name_Error | Ada.Directories.Use_Error
         | Ada.Directories.Status_Error =>
         Done := False;
   end Replace_Tree;

end Synapse.Pipeline.System_Files;
