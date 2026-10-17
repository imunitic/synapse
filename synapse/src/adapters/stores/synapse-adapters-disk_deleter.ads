with Ada.Strings.Unbounded;

with Synapse.Ports.Deleter;

--  Deleting a note of a vault directory and unlinking every link to it.

package Synapse.Adapters.Disk_Deleter is

   type Disk_Deleter is limited new Ports.Deleter.Deleter with private;

   function Create (Vault : String) return Disk_Deleter;

   --  Turns every link to the note into plain text (its alias, else its bare
   --  title) in each note that linked to it, then removes the file. The
   --  referrers are taken first, while the note still resolves.
   overriding
   procedure Delete (D : in out Disk_Deleter; Path : String);

private

   type Disk_Deleter is limited new Ports.Deleter.Deleter with record
      Vault : Ada.Strings.Unbounded.Unbounded_String;
   end record;

end Synapse.Adapters.Disk_Deleter;
