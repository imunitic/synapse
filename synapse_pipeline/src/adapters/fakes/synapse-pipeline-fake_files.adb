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

   overriding
   function Subdirectories
     (F : Fake_Files; Directory : String)
      return Synapse.Core.Text_Lists.Vector
   is
      Result : Synapse.Core.Text_Lists.Vector;
      Here   : constant String := Without_Slash (Directory);
   begin
      for Path of F.Directories loop
         if Parent (Path) = Here and then Path /= Here then
            Result.Append
              (Ada.Strings.Unbounded.To_Unbounded_String
                 (Path (Path'First + Here'Length + 1 .. Path'Last)));
         end if;
      end loop;
      return Result;
   end Subdirectories;

   overriding
   procedure Write
     (F : in out Fake_Files; Path, Text : String; Done : out Boolean) is
   begin
      Add_File (F, Path, Text);
      Done := True;
   end Write;

   --  Whether Path is Root or something below it.
   function Is_Under (Path, Root : String) return Boolean is
     (Path = Root
      or else (Path'Length > Root'Length
               and then Path (Path'First .. Path'First + Root'Length) =
                        Root & "/"));

   overriding
   procedure Remove_Tree (F : in out Fake_Files; Path : String) is
      Root : constant String := Without_Slash (Path);
      Doomed_Files : Names.Set;
      Doomed_Dirs  : Names.Set;
   begin
      for C in F.Files.Iterate loop
         if Is_Under (Contents.Key (C), Root) then
            Doomed_Files.Include (Contents.Key (C));
         end if;
      end loop;
      for Item of F.Directories loop
         if Is_Under (Item, Root) then
            Doomed_Dirs.Include (Item);
         end if;
      end loop;
      for Item of Doomed_Files loop
         F.Files.Delete (Item);
      end loop;
      for Item of Doomed_Dirs loop
         F.Directories.Delete (Item);
      end loop;
   end Remove_Tree;

   overriding
   procedure Replace_Tree
     (F : in out Fake_Files; Source, Destination : String;
      Done : out Boolean)
   is
      From : constant String := Without_Slash (Source);
      To   : constant String := Without_Slash (Destination);
      Copied_Files : Contents.Map;
      Copied_Dirs  : Names.Set;
   begin
      Done := False;
      if not Is_Directory (F, From) then
         return;
      end if;
      for C in F.Files.Iterate loop
         if Is_Under (Contents.Key (C), From) then
            Copied_Files.Include
              (To & Contents.Key (C) (Contents.Key (C)'First + From'Length
                                      .. Contents.Key (C)'Last),
               Contents.Element (C));
         end if;
      end loop;
      for Item of F.Directories loop
         if Is_Under (Item, From) then
            Copied_Dirs.Include
              (To & Item (Item'First + From'Length .. Item'Last));
         end if;
      end loop;
      Remove_Tree (F, To);
      for Item of Copied_Dirs loop
         Add_Directory (F, Item);
      end loop;
      for C in Copied_Files.Iterate loop
         Add_File (F, Contents.Key (C), Contents.Element (C));
      end loop;
      Done := True;
   end Replace_Tree;

end Synapse.Pipeline.Fake_Files;
