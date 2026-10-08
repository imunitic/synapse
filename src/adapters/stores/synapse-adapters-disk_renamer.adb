with Ada.Directories;

with Synapse.Adapters.Disk_Link_Graph;
with Synapse.Adapters.Disk_Store;
with Synapse.Core.Node_Path;
with Synapse.Core.Unicode.Transforms;
with Synapse.Core.Wikilinks;
with Synapse.Ports.Link_Graph;
with Synapse.Ports.Store;

package body Synapse.Adapters.Disk_Renamer is

   use Ada.Strings.Unbounded;

   function Create (Vault : String) return Disk_Renamer
   is (Ports.Renamer.Renamer with Vault => To_Unbounded_String (Vault));

   --  Whether writing New_Path writes the file at Old_Path: they differ only
   --  by case, New_Path already exists, and yet the directory lists only the
   --  spelling of Old_Path, which a file system that does not tell cases
   --  apart does. Asked before anything is written.
   function Same_File
     (Vault, Old_Path, New_Path : String) return Boolean
   is
      use Ada.Directories;

      function Simple (Path : String) return String
      is (Core.Wikilinks.Title_Of (Path));

      Directory : constant String :=
        Ada.Directories.Containing_Directory (Vault & "/" & New_Path);
      Search    : Search_Type;
      Item      : Directory_Entry_Type;
      Exact     : Boolean := False;
   begin
      if Old_Path = New_Path
        or else Core.Unicode.Transforms.Fold (Old_Path)
                /= Core.Unicode.Transforms.Fold (New_Path)
        or else not Exists (Vault & "/" & New_Path)
      then
         return False;
      end if;
      Start_Search (Search, Directory, "");
      while More_Entries (Search) loop
         Get_Next_Entry (Search, Item);
         if Simple_Name (Item) = Simple (New_Path) & ".md"
           or else Simple_Name (Item) = Simple (New_Path)
         then
            Exact := True;
         end if;
      end loop;
      End_Search (Search);
      return not Exact;
   exception
      when others =>
         return False;
   end Same_File;

   overriding
   procedure Rename
     (R : in out Disk_Renamer; Old_Path, New_Path : String)
   is
      Vault : constant String := To_String (R.Vault);
      Disk  : Disk_Store.Disk_Store := Disk_Store.Create (Vault, "");
      Graph : Disk_Link_Graph.Disk_Link_Graph :=
        Disk_Link_Graph.Create (Vault);
      Found : constant Ports.Store.Maybe_Text := Disk.Read (Old_Path);
   begin
      if not Found.Found then
         raise Ports.Store.Node_Not_Found with Old_Path;
      end if;

      declare
         Referrers : constant Ports.Link_Graph.Backlink_Vectors.Vector :=
           Graph.Backlinks (Old_Path);
         Old_Title : constant String := Core.Wikilinks.Title_Of (Old_Path);
         New_Title : constant String := Core.Wikilinks.Title_Of (New_Path);
         Same      : constant Boolean :=
           Same_File (Vault, Old_Path, New_Path);

         --  The moved note's own links get the rewrite any other referrer
         --  gets: a self-link is a referrer that is written to its new place.
         Moved : constant String :=
           Core.Wikilinks.Sync_Title_And_Heading
             (Core.Wikilinks.Rename_Target
                (To_String (Found.Value), Old_Title, New_Title),
              Old_Title, New_Title);
         Ignore : constant Ports.Store.Write_Result :=
           Disk.Write (New_Path, Moved);
      begin
         for Referrer of Referrers loop
            if To_String (Referrer.Node) /= Old_Path then
               declare
                  Text : constant Ports.Store.Maybe_Text :=
                    Disk.Read (To_String (Referrer.Node));
               begin
                  if Text.Found then
                     declare
                        Written : constant Ports.Store.Write_Result :=
                          Disk.Write
                            (To_String (Referrer.Node),
                             Core.Wikilinks.Rename_Target
                               (To_String (Text.Value), Old_Title, New_Title));
                     begin
                        null;
                     end;
                  end if;
               end;
            end if;
         end loop;

         if not Same and then Core.Node_Path.Is_Safe (Old_Path) then
            Ada.Directories.Delete_File (Vault & "/" & Old_Path);
         end if;
      end;
   end Rename;

end Synapse.Adapters.Disk_Renamer;
