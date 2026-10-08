with Ada.Strings.Unbounded;

with Synapse.Ports.Deleter;
with Synapse.Ports.Renamer;

--  Renaming and deleting notes of a vault directory. Both write through the
--  disk store directly, never through validation: they only move text that
--  was already accepted.

package Synapse.Adapters.Disk_Renamer is

   type Disk_Renamer is limited new Ports.Renamer.Renamer with private;

   function Create (Vault : String) return Disk_Renamer;

   --  Writes the note at its new path with links to itself rewritten and its
   --  title and first heading brought in step with the new file name, then
   --  rewrites the links in every note that linked to it, then removes the
   --  old file. The referrers are taken before anything is written, while the
   --  old name still resolves.
   --
   --  It is not atomic across files and does not try to be: the old file is
   --  removed only after every rewrite has succeeded, so an interrupted call
   --  leaves some notes pointing at the new title and some at the old, and
   --  nothing deleted. Calling it again finishes the job.
   overriding
   procedure Rename
     (R : in out Disk_Renamer; Old_Path, New_Path : String);

private

   type Disk_Renamer is limited new Ports.Renamer.Renamer with record
      Vault : Ada.Strings.Unbounded.Unbounded_String;
   end record;

end Synapse.Adapters.Disk_Renamer;
