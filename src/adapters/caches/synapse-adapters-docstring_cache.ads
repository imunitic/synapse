with Ada.Containers.Vectors;
with Ada.Finalization;
with Ada.Strings.Unbounded;

with Synapse.Core.Options;
with Synapse.Adapters.Conf_Files;
with Synapse.Adapters.File_Byte_Source;
with Synapse.Core.Docstring_Index_Format;
with Synapse.Core.Hashing;

--  The docstring index: which declarations' docstrings have been checked, at
--  what pair of content hashes, in a repository's work directory.
--
--  A (path, name, kind) is current when the index holds it at exactly the
--  requested pair of hashes. Commit merges onto what is there, so two callers
--  covering different subsets of a repository do not erase each other. A
--  mismatch on either hash is the reason for a fresh look: code changed under
--  an unchanged docstring, or a docstring changed over unchanged code, both
--  mean this pair needs one. A brand-new triple is a mismatch against an
--  absent baseline, looked at the first time it is written.
--
--  It is shaped like the tags cache, one writer and no lock for the same
--  reason, with two differences: the key is a triple, and there is no
--  payload to stream, so a commit writes the whole file at once.

package Synapse.Adapters.Docstring_Cache is

   use Ada.Strings.Unbounded;

   --  Opt-in and off by default: a setting
   --  (`SYNAPSE_DOCSTRING_STALENESS_DETECTION`) in the environment or in the
   --  configuration. Any non-empty value enables it, `false` included: there
   --  is no boolean parsing.
   function Enabled (V : Conf_Files.Variables) return Boolean;

   type Issue is
     (None, Not_A_Cache, Version_Mismatch, Truncated, Checksum_Mismatch,
      Offset_Out_Of_Range,
      --  There is a file, and it could not be opened.
      Unreadable);

   --  A commit onto an existing file that could not be read: writing a merge
   --  onto nothing would discard whatever good entries it holds.
   Unreadable_Cache : exception;

   --  What identifies one tracked docstring: which file, which declaration,
   --  and its kind (the vocabulary a tag's kind uses). The name and the kind
   --  together survive an edit elsewhere in the file without taking an
   --  untouched docstring as new; a genuine rename looks like a new triple.
   type Key is record
      Path : Unbounded_String;
      Name : Unbounded_String;
      Kind : Unbounded_String;
   end record;

   --  Path, then name, then kind, bytewise.
   function "<" (Left, Right : Key) return Boolean;

   --  What the index knows about one key.
   type Value is record
      Docstring_Hash  : Core.Hashing.Digest;
      Decl_Hash       : Core.Hashing.Digest;
      --  1-based and inclusive, as of the last time the pair was derived. A
      --  check that cannot parse re-hashes what is at these lines now; only
      --  the full check, which can, writes them.
      Docstring_Start : Natural := 0;
      Docstring_End   : Natural := 0;
      Decl_Start      : Natural := 0;
      Decl_End        : Natural := 0;
   end record;

   type Update is record
      Where : Key;
      Which : Value;
   end record;

   package Update_Vectors is new Ada.Containers.Vectors (Positive, Update);

   package Key_Vectors is new Ada.Containers.Vectors (Positive, Key);

   type Cache is limited private;

   --  The index at Path. A missing, damaged or other-version file opens as an
   --  empty index: it can be recomputed by checking again, so there is no
   --  migration. Discarded says why.
   procedure Open (C : in out Cache; Path : String);

   procedure Close (C : in out Cache);

   function Discarded (C : Cache) return Issue;

   function Count (C : Cache) return Natural;

   package Maybe_Value_Options is new Synapse.Core.Options (Value);

   subtype Maybe_Value is Maybe_Value_Options.Option;

   function Get (C : in out Cache; Where : Key) return Maybe_Value;

   --  Every tracked triple of one file, in the order stored: what a per-file
   --  check at read time scans, and what a sweep uses to find a triple that a
   --  fresh extraction no longer has, to evict it because the declaration or
   --  its docstring is gone.
   type File_Entry is record
      Name  : Unbounded_String;
      Kind  : Unbounded_String;
      Which : Value;
   end record;

   package File_Entry_Vectors is new Ada.Containers.Vectors
     (Positive, File_Entry);

   function Entries_For_Path
     (C : in out Cache; Path : String) return File_Entry_Vectors.Vector;

   --  The requested triples not held at exactly that pair of hashes, in order
   --  and without a repeated key, the first of two winning.
   function Needs_Check
     (C : in out Cache; Requested : Update_Vectors.Vector)
      return Update_Vectors.Vector;

   --  Applies Updates and drops Removals, writes the whole file and renames it
   --  over the original, then reads it again. A removal of a triple that is
   --  also being updated removes it. Returns the rows actually removed: a
   --  triple the index never held is not counted. Raises Unreadable_Cache for
   --  a file Open could not read. One writer, as the tags cache.
   function Commit
     (C        : in out Cache; Updates : Update_Vectors.Vector;
      Removals :        Key_Vectors.Vector) return Natural;

private

   type Cache is limited new Ada.Finalization.Limited_Controlled with record
      Path   : Unbounded_String;
      Source : File_Byte_Source.Source;
      Opened : Boolean := False;
      Head   : Core.Docstring_Index_Format.Header;
      Why    : Issue   := None;
   end record;

   overriding procedure Finalize (C : in out Cache);

end Synapse.Adapters.Docstring_Cache;
