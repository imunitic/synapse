with Ada.Directories;
with Ada.Streams.Stream_IO;

with GNAT.OS_Lib;

with Synapse.Pipeline.Private_Access;

package body Synapse.Pipeline.Disk_Registry is

   package Dirs renames Ada.Directories;
   package Streams renames Ada.Streams.Stream_IO;

   use Ada.Strings.Unbounded;
   use type Dirs.File_Kind;

   LF : constant Character := Character'Val (10);

   Summary_Name : constant String := "execution.json";
   Events_Name  : constant String := "events.jsonl";
   Transcripts  : constant String := "transcripts";

   --  The most a summary or an event history is read back as.
   Largest_Read : constant := 16 * 1024 * 1024;

   overriding
   procedure Open (R : in out Disk_Registry; Work_Directory : String) is
   begin
      R.Root := To_Unbounded_String (Work_Directory & "/pipelines");
   end Open;

   --  A name that stays inside the directory it is given in.
   function Is_Plain (Name : String) return Boolean is
     (Name'Length > 0 and then Name (Name'First) /= '.'
      and then (for all C of Name => C not in '/' | '\' | ':'));

   function Directory_Of (R : Disk_Registry; Id : String) return String is
     (To_String (R.Root) & "/" & Id);

   function Is_Directory (Path : String) return Boolean is
   begin
      return Dirs.Exists (Path) and then Dirs.Kind (Path) = Dirs.Directory;
   exception
      when others =>
         return False;
   end Is_Directory;

   function Is_File (Path : String) return Boolean is
   begin
      return Dirs.Exists (Path) and then Dirs.Kind (Path) = Dirs.Ordinary_File;
   exception
      when others =>
         return False;
   end Is_File;

   --  Writes Content beside Path and renames it over Path, so a reader sees
   --  the old file or the new one.
   function Write_Whole (Path, Content : String) return Boolean is
      Temporary : constant String := Path & ".tmp";
      File      : Streams.File_Type;
      Renamed   : Boolean;
   begin
      Streams.Create (File, Streams.Out_File, Temporary);
      String'Write (Streams.Stream (File), Content);
      Streams.Close (File);
      GNAT.OS_Lib.Rename_File (Temporary, Path, Renamed);
      if not Renamed then
         Dirs.Delete_File (Temporary);
      end if;
      return Renamed;
   exception
      when others =>
         if Streams.Is_Open (File) then
            Streams.Close (File);
         end if;
         begin
            if Is_File (Temporary) then
               Dirs.Delete_File (Temporary);
            end if;
         exception
            when others =>
               null;
         end;
         return False;
   end Write_Whole;

   function Read_Text (Path : String) return Registry_Store.Maybe_Content is
      File : Streams.File_Type;
   begin
      if not Is_File (Path) then
         return (Found => False);
      end if;
      Streams.Open (File, Streams.In_File, Path);
      declare
         Size : constant Natural := Natural (Streams.Size (File));
      begin
         if Size > Largest_Read then
            Streams.Close (File);
            return (Found => False);
         end if;
         declare
            Text : String (1 .. Size);
         begin
            String'Read (Streams.Stream (File), Text);
            Streams.Close (File);
            return (Found => True, Value => To_Unbounded_String (Text));
         end;
      end;
   exception
      when others =>
         if Streams.Is_Open (File) then
            Streams.Close (File);
         end if;
         return (Found => False);
   end Read_Text;

   --  The names of what is directly in Directory, of the Kind given.
   function Names_In
     (Directory : String; Kind : Dirs.File_Kind)
      return Synapse.Core.Text_Lists.Vector
   is
      Names  : Synapse.Core.Text_Lists.Sets.Set;
      Result : Synapse.Core.Text_Lists.Vector;
      Search : Dirs.Search_Type;
      Item   : Dirs.Directory_Entry_Type;
      Filter : Dirs.Filter_Type := [others => False];
   begin
      if not Is_Directory (Directory) then
         return Result;
      end if;
      Filter (Kind) := True;
      Dirs.Start_Search (Search, Directory, "", Filter);
      while Dirs.More_Entries (Search) loop
         Dirs.Get_Next_Entry (Search, Item);
         declare
            Name : constant String := Dirs.Simple_Name (Item);
         begin
            if Name /= "." and then Name /= ".." then
               Names.Include (Name);
            end if;
         end;
      end loop;
      Dirs.End_Search (Search);
      for Name of Names loop
         Result.Append (To_Unbounded_String (Name));
      end loop;
      return Result;
   exception
      when others =>
         return Result;
   end Names_In;

   overriding
   function Create
     (R : in out Disk_Registry; Id : String)
      return Registry_Store.Create_Result
   is
      Dir : constant String := Directory_Of (R, Id);
   begin
      if not Is_Plain (Id) then
         return Registry_Store.Failed;
      end if;
      Dirs.Create_Path (To_String (R.Root));
      Private_Access.Directory (To_String (R.Root));
      Dirs.Create_Directory (Dir);
      Private_Access.Directory (Dir);
      return Registry_Store.Created;
   exception
      when others =>
         return (if Dirs.Exists (Dir) then Registry_Store.Already_Exists
              else Registry_Store.Failed);
   end Create;

   overriding
   function Replace_Summary
     (R : in out Disk_Registry; Id, Content : String) return Boolean
   is
      Dir : constant String := Directory_Of (R, Id);
   begin
      return Is_Plain (Id) and then Is_Directory (Dir)
        and then Write_Whole (Dir & "/" & Summary_Name, Content);
   end Replace_Summary;

   overriding
   function Append_Event
     (R : in out Disk_Registry; Id, Line : String) return Boolean
   is
      Dir  : constant String := Directory_Of (R, Id);
      Path : constant String := Dir & "/" & Events_Name;
      File : Streams.File_Type;
   begin
      if not Is_Plain (Id) or else not Is_Directory (Dir) then
         return False;
      end if;
      if Is_File (Path) then
         Streams.Open (File, Streams.Append_File, Path);
      else
         Streams.Create (File, Streams.Out_File, Path);
      end if;
      String'Write (Streams.Stream (File), Line & LF);
      Streams.Close (File);
      return True;
   exception
      when others =>
         if Streams.Is_Open (File) then
            Streams.Close (File);
         end if;
         return False;
   end Append_Event;

   overriding
   function Write_Transcript
     (R : in out Disk_Registry; Id, Name, Content : String) return Boolean
   is
      Dir : constant String := Directory_Of (R, Id);
   begin
      if not Is_Plain (Id) or else not Is_Plain (Name)
        or else not Is_Directory (Dir)
      then
         return False;
      end if;
      if not Is_Directory (Dir & "/" & Transcripts) then
         Dirs.Create_Directory (Dir & "/" & Transcripts);
      end if;
      return Write_Whole (Dir & "/" & Transcripts & "/" & Name, Content);
   exception
      when others =>
         return False;
   end Write_Transcript;

   overriding
   function Remove (R : in out Disk_Registry; Id : String) return Boolean is
      Dir : constant String := Directory_Of (R, Id);
   begin
      if not Is_Plain (Id) then
         return False;
      end if;
      if Dirs.Exists (Dir) then
         Dirs.Delete_Tree (Dir);
      end if;
      return not Dirs.Exists (Dir);
   exception
      when others =>
         return False;
   end Remove;

   overriding
   function Ids (R : Disk_Registry) return Synapse.Core.Text_Lists.Vector is
   begin
      return Names_In (To_String (R.Root), Dirs.Directory);
   end Ids;

   overriding
   function Read_Summary
     (R : Disk_Registry; Id : String) return Registry_Store.Maybe_Content is
   begin
      if not Is_Plain (Id) then
         return (Found => False);
      end if;
      return Read_Text (Directory_Of (R, Id) & "/" & Summary_Name);
   end Read_Summary;

   overriding
   function Read_Events
     (R : Disk_Registry; Id : String) return Registry_Store.Maybe_Content is
   begin
      if not Is_Plain (Id) then
         return (Found => False);
      end if;
      return Read_Text (Directory_Of (R, Id) & "/" & Events_Name);
   end Read_Events;

   overriding
   function Transcript_Path
     (R : Disk_Registry; Id, Name : String) return String is
   begin
      return Directory_Of (R, Id) & "/" & Transcripts & "/" & Name;
   end Transcript_Path;

   overriding
   function Transcript_Names
     (R : Disk_Registry; Id : String) return Synapse.Core.Text_Lists.Vector
   is
      Result : Synapse.Core.Text_Lists.Vector;
   begin
      if not Is_Plain (Id) then
         return Result;
      end if;
      for Name of Names_In
        (Directory_Of (R, Id) & "/" & Transcripts, Dirs.Ordinary_File)
      loop
         declare
            Text : constant String := To_String (Name);
         begin
            if Text'Length < 4
              or else Text (Text'Last - 3 .. Text'Last) /= ".tmp"
            then
               Result.Append (Name);
            end if;
         end;
      end loop;
      return Result;
   end Transcript_Names;

   overriding
   function Last_Write
     (R : Disk_Registry; Id : String)
      return Registry_Store.Time_Options.Option
   is
      Path : constant String := Directory_Of (R, Id) & "/" & Summary_Name;
   begin
      if Is_Plain (Id) and then Is_File (Path) then
         return Registry_Store.Time_Options.Of_Value
           (Dirs.Modification_Time (Path));
      end if;
      return Registry_Store.Time_Options.None;
   exception
      when others =>
         return Registry_Store.Time_Options.None;
   end Last_Write;

end Synapse.Pipeline.Disk_Registry;
