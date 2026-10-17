with Ada.Directories;

with Synapse.Adapters.Disk_Link_Graph;
with Synapse.Adapters.Disk_Store;
with Synapse.Core.Node_Path;
with Synapse.Core.Wikilinks;
with Synapse.Ports.Link_Graph;
with Synapse.Ports.Store;

package body Synapse.Adapters.Disk_Deleter is

   use Ada.Strings.Unbounded;

   function Create (Vault : String) return Disk_Deleter
   is (Ports.Deleter.Deleter with Vault => To_Unbounded_String (Vault));

   overriding
   procedure Delete (D : in out Disk_Deleter; Path : String) is
      Vault : constant String := To_String (D.Vault);
      Disk  : Disk_Store.Disk_Store := Disk_Store.Create (Vault, "");
      Graph : Disk_Link_Graph.Disk_Link_Graph :=
        Disk_Link_Graph.Create (Vault);
   begin
      if not Disk.Read (Path).Found then
         raise Ports.Store.Node_Not_Found with Path;
      end if;

      declare
         Referrers : constant Ports.Link_Graph.Backlink_Vectors.Vector :=
           Graph.Backlinks (Path);
         Title     : constant String := Core.Wikilinks.Title_Of (Path);
      begin
         for Referrer of Referrers loop
            if To_String (Referrer.Node) /= Path then
               declare
                  Text : constant Ports.Store.Maybe_Text :=
                    Disk.Read (To_String (Referrer.Node));
               begin
                  if Text.Found then
                     declare
                        Written : constant Ports.Store.Write_Result :=
                          Disk.Write
                            (To_String (Referrer.Node),
                             Core.Wikilinks.Unlink_Target
                               (To_String (Text.Value), Title));
                     begin
                        null;
                     end;
                  end if;
               end;
            end if;
         end loop;
      end;

      if not Core.Node_Path.Is_Safe (Path) then
         raise Ports.Store.Unsafe_Node with Path;
      end if;
      if Ada.Directories.Exists (Vault & "/" & Path) then
         Ada.Directories.Delete_File (Vault & "/" & Path);
      end if;
   end Delete;

end Synapse.Adapters.Disk_Deleter;
