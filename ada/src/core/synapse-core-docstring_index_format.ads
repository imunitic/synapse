with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Interfaces;

with Synapse.Core.Hashing;
with Synapse.Core.Little_Endian;
with Synapse.Ports.Byte_Source;

--  The on-disk docstring index: bytes in, bytes out. It follows the layout of
--  the tags cache, with one record per docstring and not one per file, since
--  a file can hold many. The key is the path, the name of a declaration and
--  its kind, and not the path alone: a name and a kind survive an edit
--  elsewhere in the file, so an untouched docstring is not falsely taken as
--  new, at the cost that a genuine rename looks like a new entry, which is a
--  reason to look again and not a verdict.
--
--    0              header, 32 bytes
--    32             record table, entry count * 109 bytes, sorted by path,
--                   then name, then kind
--    strings_off    string region: each record's path, name and kind bytes,
--                   concatenated
--
--  There is no payload region: a record's data is two 32-byte hashes and two
--  line ranges, all of which fit in the row, so the checksum covers the whole
--  file after the header. Every field is read and written a byte at a time,
--  least significant first.
--
--  The two hashes are SHA-256, the hash a node's `grounded_in` digests
--  already use: a docstring and its declaration are both sub-ranges of a
--  file. The line ranges (1-based, inclusive, as of the last time the pair was
--  derived) let a check re-hash whatever is at those lines now without
--  parsing again.
--
--  A header that does not match is discarded and rebuilt.

package Synapse.Core.Docstring_Index_Format is

   use Ada.Strings.Unbounded;
   use Little_Endian;
   use type Interfaces.Unsigned_32;

   Magic : constant String := "SYNDOCS" & Character'Val (0);

   Version : constant := 1;

   Header_Size : constant := 32;
   Record_Size : constant := 109;

   type Header is record
      Version     : U32;
      Entry_Count : U32;
      Strings_Off : U64;
      --  Over everything after the header.
      Crc32       : U32;
   end record;

   type Table_Record is record
      Path_Off, Name_Off, Kind_Off : U64;
      Path_Len, Name_Len, Kind_Len : Natural;
      --  SHA-256 of the docstring's comment text, and of the declaration's
      --  body.
      Docstring_Hash               : Hashing.Digest;
      Decl_Hash                    : Hashing.Digest;
      Docstring_Start              : U32;
      Docstring_End                : U32;
      Decl_Start                   : U32;
      Decl_End                     : U32;
   end record;

   --  A whole entry, key included. A line number past what a Natural holds is
   --  not a line number of any file; it is clamped on the way in.
   type Entry_Type is record
      Path            : Unbounded_String;
      Name            : Unbounded_String;
      Kind            : Unbounded_String;
      Docstring_Hash  : Hashing.Digest;
      Decl_Hash       : Hashing.Digest;
      Docstring_Start : Natural := 0;
      Docstring_End   : Natural := 0;
      Decl_Start      : Natural := 0;
      Decl_End        : Natural := 0;
   end record;

   package Entry_Vectors is new Ada.Containers.Vectors (Positive, Entry_Type);

   --  Entries not in strictly increasing order of path, then name, then kind:
   --  they would encode and make every binary search wrong.
   Unsorted : exception;

   Path_Too_Long : exception;
   Name_Too_Long : exception;

   --  The kind must fit one byte.
   Kind_Too_Long : exception;

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

   --  Validates the file and returns its header: the table fits, the strings
   --  region follows it, the checksum matches, every record's three strings
   --  lie inside the region (the sums made without overflow), and the keys are
   --  in strictly increasing order.
   function Parse
     (Source : in out Ports.Byte_Source.Source'Class) return Parse_Result;

   function Record_At
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Index  :        Natural) return Table_Record with
     Pre => U32 (Index) < Head.Entry_Count;

   function Path_Of
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Item   :        Table_Record) return String;

   function Name_Of
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Item   :        Table_Record) return String;

   function Kind_Of
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Item   :        Table_Record) return String;

   --  The record as a whole entry.
   function Entry_Of
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Item   :        Table_Record) return Entry_Type;

   type Maybe_Index (Found : Boolean := False) is record
      case Found is
         when True =>
            Index : Natural;

         when False =>
            null;
      end case;
   end record;

   --  The position of the exact (path, name, kind).
   function Find
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Path   :        String; Name : String; Kind : String) return Maybe_Index;

   --  Positions From up to but not including To of every entry of one file:
   --  contiguous, since the path is the primary key, and empty (From = To)
   --  for a file with no tracked docstrings.
   type Range_Of_Entries is record
      From, To : Natural;
   end record;

   function Path_Range
     (Source : in out Ports.Byte_Source.Source'Class; Head : Header;
      Path   :        String) return Range_Of_Entries;

end Synapse.Core.Docstring_Index_Format;
