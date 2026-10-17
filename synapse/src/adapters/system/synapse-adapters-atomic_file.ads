--  Replacing a file whole, so that a reader sees the old file or the new one
--  and never half of either.

package Synapse.Adapters.Atomic_File is

   --  Writes Bytes to a temporary file beside Path and renames it over Path,
   --  creating the directory first when there is none. The temporary file is
   --  removed when anything fails.
   procedure Write (Path, Bytes : String);

end Synapse.Adapters.Atomic_File;
