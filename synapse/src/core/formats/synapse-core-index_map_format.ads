with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;
with Interfaces;

with Synapse.Core.Results;
with Synapse.Core.Options;
with Synapse.Core.Little_Endian;
with Synapse.Core.Text_Lists;
with Synapse.Ports.Byte_Source;

--  The on-disk reverse index: bytes in, bytes out. It is derived and not part
--  of the vault, and holds which nodes claim a source path and which paths no
--  node claims.
--
--  A path maps to a list of nodes and not to one, since a file can be cited
--  by more than one subsystem. Node names are interned (a hundred names, a
--  hundred thousand records pointing at them by number) and not repeated per
--  record.
--
--    0              header, 64 bytes
--    64             record table, entry count * 15 bytes, sorted by path
--    paths_off      path region: every path's bytes, concatenated
--    ids_off        node-id region: one 4-byte number per (path, node) pair
--    nodes_off      node table, node count * 6 bytes, sorted by name,
--                   followed by the name bytes it points into
--    unassigned_off unassigned region: every path, each ended by a line feed
--
--  Records are fixed width and sorted by path bytes, and the node table is
--  sorted by name, so both are searched by bisection. Every field is read and
--  written a byte at a time, least significant first, and the 15-byte record
--  keeps nothing aligned.
--
--  The checksum covers everything after the header: the whole file is small
--  (a few megabytes on a repository of 125,000 files), so no region is left
--  unprotected. A header that does not match is discarded and rebuilt.
--  Not_An_Index and Version_Mismatch are separate because the first usually
--  means the JSON file this format replaced is still at the path.

package Synapse.Core.Index_Map_Format is

   use Ada.Strings.Unbounded;
   use Little_Endian;
   use type Interfaces.Unsigned_32;

   Magic : constant String := "SYNIDX" & Character'Val (0) & Character'Val (0);

   Version : constant := 1;

   Header_Size : constant := 64;
   Record_Size : constant := 15;
   Node_Size   : constant := 6;

   --  Refused and not truncated past this, which keeps the count of a path's
   --  nodes a byte: 255 claimants on one path is a clustering fault and not a
   --  case to support.
   Max_Nodes_Per_Path : constant := 255;

   type Header is record
      Version          : U32;
      --  Paths with at least one owning node. Unassigned paths are counted
      --  apart and are not in the record table.
      Entry_Count      : U32;
      Node_Count       : U32;
      Unassigned_Count : U32;
      Paths_Off        : U64;
      Ids_Off          : U64;
      --  The node table; the name bytes follow it.
      Nodes_Off        : U64;
      Unassigned_Off   : U64;
      --  Over everything after the header.
      Crc32            : U32;
   end record;

   type Table_Record is record
      Path_Off : U64;
      Path_Len : Natural;
      --  In 4-byte slots of the node-id region and not in bytes.
      Ids_At   : U32;
      --  Never zero: a path nobody owns is in the unassigned region.
      Ids_Len  : Natural;
   end record;

   --  A path and the nodes that claim it, ascending.
   type Entry_Type is record
      Path  : Unbounded_String;
      Nodes : Text_Lists.Vector;
   end record;

   package Entry_Vectors is new Ada.Containers.Vectors (Positive, Entry_Type);

   --  Paths not strictly ascending.
   Unsorted : exception;

   --  A path's nodes not strictly ascending.
   Unsorted_Nodes : exception;

   --  A record with no owner: the unassigned list says that better.
   No_Nodes : exception;

   Path_Too_Long           : exception;
   Node_Name_Too_Long      : exception;
   Too_Many_Nodes_For_Path : exception;

   --  A line feed in an unassigned path could not be told from the end of it.
   Path_Contains_Newline : exception;

   --  The whole file from entries already sorted by path. The unassigned
   --  paths are kept in the order given: they are a list, not an index, and
   --  their only reader walks all of it.
   function Encode
     (Entries : Entry_Vectors.Vector; Unassigned : Text_Lists.Vector)
      return String;

   type Parse_Error is
     (Not_An_Index, Version_Mismatch, Truncated, Checksum_Mismatch,
      Offset_Out_Of_Range);

   package Parse_Results is new Synapse.Core.Results (Header, Parse_Error);

   subtype Parse_Result is Parse_Results.Result;

   --  Validates the file and returns its header. Every offset a reader below
   --  uses is checked here: the regions are in order, a node number names a
   --  node, names and paths are ascending, and the unassigned region holds the
   --  count it claims, each ended by a line feed. The sums are made without
   --  overflow, since each is read from untrusted bytes.
   function Parse
     (Source : in out Ports.Byte_Source.Source'Class) return Parse_Result;

   function Record_At
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Index  :        Natural) return Table_Record with
     Pre => U32 (Index) < Head.Entry_Count;

   function Path_Of
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Item   :        Table_Record) return String;

   --  The name of the node with this number, below the node count.
   function Node_Name
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Id     :        Natural) return String with
     Pre => U32 (Id) < Head.Node_Count;

   --  The names of the nodes of a record, ascending.
   function Nodes_Of
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Item   :        Table_Record) return Text_Lists.Vector;

   package Maybe_Index_Options is new Synapse.Core.Options (Natural);

   subtype Maybe_Index is Maybe_Index_Options.Option;

   --  The position of a path, by bisection.
   function Find
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Path   :        String) return Maybe_Index;

   --  The number of a node name, by bisection over the node table.
   function Find_Node
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Name   :        String) return Maybe_Index;

   --  Every unassigned path, in the order stored.
   function Unassigned
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header)
      return Text_Lists.Vector;

   --  Everything the file says, decoded: what rebuilding it with one more
   --  unassigned path needs.
   type Decoded is record
      Entries    : Entry_Vectors.Vector;
      Unassigned : Text_Lists.Vector;
   end record;

   function Decode
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header)
      return Decoded;

end Synapse.Core.Index_Map_Format;
