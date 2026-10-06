with Interfaces;

with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.Graph_Model;
with Synapse.Core.Little_Endian;
with Synapse.Ports.Byte_Source;

--  The on-disk tags cache: bytes in, bytes out. A file maps each source path
--  to the hash of the content it was tagged at and the tags found there. The
--  question "which of these 4,000 files changed?" must touch the record table
--  and not the tag text, which on a large repository is hundreds of
--  megabytes, so the text lives out of line.
--
--    0          header, 40 bytes
--    40         record table, entry count * 43 bytes, sorted by path
--    paths_off  path region: every path's bytes, concatenated
--    blob_off   payload region: every entry's tags, concatenated
--
--  Records are fixed width and sorted by path bytes, so a lookup is a binary
--  search over a region small enough to stay cached. Every field is read and
--  written a byte at a time, least significant first, and the 43-byte record
--  keeps nothing aligned, so no shortcut can work by accident.
--
--  Opening costs the record table and the paths: everything Parse does is
--  bounded by blob_off, the checksum included. Covering the payload too made
--  opening a 800 MB cache slower than parsing the JSON it replaced, while
--  leaving it out costs only that a flipped bit inside a tag string goes
--  undetected, the same damage as a stale cache and cured by a rebuild. A bit
--  flipped in an offset is still caught.
--
--  A header that does not match is discarded and rebuilt: a cache holds
--  nothing that cannot be recomputed. Not_A_Cache and Version_Mismatch are
--  separate because the first usually means something else is at the path.

package Synapse.Core.Tags_Cache_Format is

   use Ada.Strings.Unbounded;
   use Little_Endian;
   use type Interfaces.Unsigned_32;

   --  Eight bytes with the NUL, so that the header's first field is aligned
   --  and the name shows in a dump.
   Magic : constant String := "SYNTAGS" & Character'Val (0);

   --  Bumped when the payload region changes shape, so that a cache written
   --  by an earlier version is read as a cache to rebuild and never as the
   --  bytes of this one.
   Version : constant := 2;

   Header_Size : constant := 40;
   Record_Size : constant := 43;

   type Header is record
      Version     : U32;
      Entry_Count : U32;
      Paths_Off   : U64;
      Blob_Off    : U64;
      --  Over everything from the end of the header to Blob_Off.
      Crc32       : U32;
   end record;

   --  One cached path. Offsets are into the path and payload regions and not
   --  into the file.
   type Table_Record is record
      Path_Off : U64;
      Path_Len : Natural;
      --  The raw 20 bytes of the hash and not its hex: half the table, and a
      --  comparison of bytes.
      Hash     : Graph_Model.Hash;
      Tags_Off : U64;
      Tags_Len : U32;
      Flags    : Natural;
   end record;

   --  No usable grammar. Distinct from no tags, which is a file that was
   --  parsed and declared nothing: conflating them tags a readable file again
   --  forever.
   Flag_Unsupported : constant := 1;

   function Unsupported (R : Table_Record) return Boolean is
     (R.Flags mod 2 = Flag_Unsupported);

   --  A whole entry, path included.
   type Entry_Type is record
      Path        : Unbounded_String;
      Hash        : Graph_Model.Hash;
      Tags        : Unbounded_String;
      Unsupported : Boolean := False;
   end record;

   package Entry_Vectors is new Ada.Containers.Vectors (Positive, Entry_Type);

   --  An entry as the record table sees it: the length of its tags and not the
   --  tags, for writing a file whose payloads are streamed from elsewhere and
   --  never held together.
   type Sized_Entry is record
      Path        : Unbounded_String;
      Hash        : Graph_Model.Hash;
      Tags_Length : Natural;
      Unsupported : Boolean := False;
   end record;

   package Sized_Vectors is new Ada.Containers.Vectors (Positive, Sized_Entry);

   --  Entries not in strictly increasing path order: they would encode and
   --  make every binary search wrong.
   Unsorted : exception;

   Path_Too_Long : exception;

   --  The header, the record table and the path region: everything before the
   --  payload. Its offsets are known once every path length is, and the
   --  checksum covers exactly this.
   function Encode_Prefix (Entries : Entry_Vectors.Vector) return String;

   function Encode_Prefix (Entries : Sized_Vectors.Vector) return String;

   --  The whole file: the prefix, then each entry's tags in order. For tests
   --  and small caches; a repository-sized one writes the payloads as a
   --  stream after the prefix.
   function Encode (Entries : Entry_Vectors.Vector) return String;

   type Parse_Error is
     (Not_A_Cache, Version_Mismatch, Truncated, Checksum_Mismatch,
      Offset_Out_Of_Range);

   type Parse_Result (Ok : Boolean := False) is record
      case Ok is
         when True =>
            Head : Header;

         when False =>
            Error : Parse_Error;
      end case;
   end record;

   --  Validates the file and returns its header. Every offset a reader
   --  below uses is checked here, so the readers need no checks of their
   --  own: the sums are made without overflow, since each is read from
   --  untrusted bytes.
   function Parse
     (Source : in out Ports.Byte_Source.Source'Class) return Parse_Result;

   --  The record at a position from 0, which must be below the count.
   function Record_At
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Index  :        Natural) return Table_Record with
     Pre => U32 (Index) < Head.Entry_Count;

   function Path_Of
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Item   :        Table_Record) return String;

   function Tags_Of
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Item   :        Table_Record) return String;

   type Maybe_Index (Found : Boolean := False) is record
      case Found is
         when True =>
            Index : Natural;

         when False =>
            null;
      end case;
   end record;

   --  The position of Path, by binary search: the sort order is this
   --  format's own promise, which Parse has checked.
   function Find
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Path   :        String) return Maybe_Index;

end Synapse.Core.Tags_Cache_Format;
