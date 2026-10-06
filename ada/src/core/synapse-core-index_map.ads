with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.Index_Map_Format;
with Synapse.Core.Text_Lists;

--  The reverse index: which nodes claim a source path, and which paths no
--  node claims. This is the grouping that turns claims into the file's
--  bytes. The format demands strictly ascending paths and node lists, which
--  whatever produces the claims does not promise, so the grouping belongs
--  here, with its tests.

package Synapse.Core.Index_Map is

   use Ada.Strings.Unbounded;

   --  One claim, unordered, repeated per node for a path several nodes claim.
   type Pair is record
      Path : Unbounded_String;
      Node : Unbounded_String;
   end record;

   package Pair_Vectors is new Ada.Containers.Vectors (Positive, Pair);

   --  The file's bytes for unordered pairs. A repeated (path, node) pair is
   --  one claim, and a path under several nodes keeps all of them, ascending.
   --  Raises the exceptions of Index_Map_Format for what it refuses.
   function Build
     (Pairs : Pair_Vectors.Vector; Unassigned : Text_Lists.Vector)
      return String;

   type Maybe_Bytes (Found : Boolean := False) is record
      case Found is
         when True =>
            Bytes : Unbounded_String;

         when False =>
            null;
      end case;
   end record;

   --  The index's bytes again with Extra added to the unassigned list, or none
   --  when it is already there, so that repeating it does not grow the file.
   --  A whole re-encode, since every region's offsets move when one grows. It
   --  happens only for a genuinely new unclaimed path and not for each edit.
   --  The path is appended and not placed in order: the unassigned list is not
   --  sorted, and its reader walks all of it.
   --
   --  One writer, not locked: Current is a snapshot the caller already read,
   --  so two calls racing on one index can lose one addition. Only a new
   --  unclaimed path triggers it, and a missed path is flagged by the next
   --  edit or the next orientation.
   function With_Unassigned
     (Current : Index_Map_Format.Decoded; Extra : String) return Maybe_Bytes;

end Synapse.Core.Index_Map;
