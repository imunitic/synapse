with Ada.Finalization;
with Ada.Strings.Unbounded;

with Synapse.Core.Options;
with Synapse.Adapters.File_Byte_Source;
with Synapse.Core.Index_Map_Format;
with Synapse.Core.Text_Lists;

--  The reverse index as a file that is opened, asked and rewritten. It sits
--  beside the tags cache in the work directory, derived and never in the
--  vault, and is read by the staleness hook on every edit, so a write must
--  never be seen half done.

package Synapse.Adapters.Index_Map is

   use Ada.Strings.Unbounded;

   --  Why Open did not use the file it found. None: it was read, or there is
   --  none.
   type Issue is
     (None, Not_An_Index, Version_Mismatch, Truncated, Checksum_Mismatch,
      Offset_Out_Of_Range,
      --  There is a file, and it could not be opened.
      Unreadable);

   type Map is limited private;

   --  The index at Path. A missing, unreadable, damaged or other-version file
   --  opens as an empty index and not as an error, and Discarded says which:
   --  it can be recomputed from the work directory's lists, so there is no
   --  migration, and the next build replaces whatever was there, a leftover
   --  JSON index included.
   procedure Open (M : in out Map; Path : String);

   procedure Close (M : in out Map);

   function Discarded (M : Map) return Issue;

   --  The number of paths with an owner, of nodes, and of unassigned paths.
   function Count (M : Map) return Natural;
   function Node_Count (M : Map) return Natural;
   function Unassigned_Count (M : Map) return Natural;

   package Maybe_Nodes_Options is new Synapse.Core.Options
     (Core.Text_Lists.Vector);

   subtype Maybe_Nodes is Maybe_Nodes_Options.Option;

   --  The nodes that claim a path, ascending. None is ordinary: the path is
   --  unassigned, or was never listed; Unassigned is where that distinction
   --  lives.
   function Nodes_For (M : in out Map; Path : String) return Maybe_Nodes;

   function Unassigned (M : in out Map) return Core.Text_Lists.Vector;

   --  Writes Bytes to Path through a temporary file and a rename, so that a
   --  reader sees the old index whole or the new one, never half of either.
   procedure Write_File (Path : String; Bytes : String);

   --  Adds Extra to the unassigned list in the file the map was opened from
   --  and opens the new file; False when it was already there and nothing was
   --  written. Raises Program_Error for a map that opened nothing.
   function Add_Unassigned (M : in out Map; Extra : String) return Boolean;

private

   type Map is limited new Ada.Finalization.Limited_Controlled with record
      Path   : Unbounded_String;
      Source : File_Byte_Source.Source;
      Opened : Boolean := False;
      Head   : Core.Index_Map_Format.Header;
      Why    : Issue   := None;
   end record;

   overriding procedure Finalize (M : in out Map);

end Synapse.Adapters.Index_Map;
