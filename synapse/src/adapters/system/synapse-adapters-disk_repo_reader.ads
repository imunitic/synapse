with Ada.Strings.Unbounded;

with Synapse.Ports.Repo_Reader;

--  A repository on disk. A file over 4 MiB is not read: the graph's rules look
--  for a declaration near the top of a source or a build file, and a file that
--  size is generated or data.

package Synapse.Adapters.Disk_Repo_Reader is

   Largest_File : constant := 4 * 1_024 * 1_024;

   type Reader is limited new Ports.Repo_Reader.Reader with private;

   function Create (Root : String) return Reader;

   overriding function Read
     (R : in out Reader; Path : String) return Ports.Repo_Reader.Maybe_Content;

private

   type Reader is limited new Ports.Repo_Reader.Reader with record
      Root : Ada.Strings.Unbounded.Unbounded_String;
   end record;

end Synapse.Adapters.Disk_Repo_Reader;
