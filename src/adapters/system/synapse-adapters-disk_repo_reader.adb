with Synapse.Adapters.File_Bytes;

package body Synapse.Adapters.Disk_Repo_Reader is

   use Ada.Strings.Unbounded;

   function Create (Root : String) return Reader is
     (Ports.Repo_Reader.Reader with Root => To_Unbounded_String (Root));

   overriding function Read
     (R : in out Reader; Path : String) return Ports.Repo_Reader.Maybe_Content
   is
   begin
      return
        (Found => True,
         Value =>
           To_Unbounded_String
             (File_Bytes.Read
                (To_String (R.Root) & "/" & Path, Largest_File)));
   exception
      when others =>
         return (Found => False);
   end Read;

end Synapse.Adapters.Disk_Repo_Reader;
