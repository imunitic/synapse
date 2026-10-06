with Ada.Containers.Vectors;
with Ada.Finalization;
with Ada.Strings.Unbounded;

with Synapse.Adapters.File_Byte_Source;
with Synapse.Core.Graph_Model;
with Synapse.Core.Tags_Cache_Format;
with Synapse.Core.Text_Lists;

--  The tags cache: which files have been tagged, at what content hash, with
--  what result. What it decides is what needs tagging, what it holds is the
--  answers, and what it projects is `_refs.tsv`; running the extractor is
--  another part's job.
--
--  A path is current when the cache holds it at exactly the requested hash.
--  Commit merges onto what is there, so two callers covering different
--  subsets of a repository do not erase each other. A file with no usable
--  grammar is recorded as unsupported and not left out, or it would be tried
--  again forever. A commit also takes removals, so `_refs.tsv` never names a
--  deleted file's caller.
--
--  Which files are out of date is answered from the record table alone: the
--  payload, on a large repository hundreds of megabytes, is never read for
--  it, and is copied and not decoded when a commit keeps an entry.

package Synapse.Adapters.Tags_Cache is

   use Ada.Strings.Unbounded;

   --  Why Open did not use the file it found. None: it was read, or there is
   --  none.
   type Issue is
     (None, Not_A_Cache, Version_Mismatch, Truncated, Checksum_Mismatch,
      Offset_Out_Of_Range,
      --  There is a file, and it could not be opened. This says nothing about
      --  whether its content is good.
      Unreadable);

   --  A commit onto a cache whose file could not be read: merging onto an
   --  empty view and writing that over the original would discard however
   --  much good data the file still holds, for a failure that has nothing to
   --  do with its validity.
   Unreadable_Cache : exception;

   type Cache is limited private;

   --  The cache at Path. A missing file, a damaged one and one of another
   --  version all open as an empty cache and not as an error: the contents
   --  can be recomputed by tagging again, so there is no migration, and a file
   --  that is not a cache (the JSON one an earlier version left behind) is
   --  overwritten by the next commit. Discarded says why.
   procedure Open (C : in out Cache; Path : String);

   procedure Close (C : in out Cache);

   function Discarded (C : Cache) return Issue;

   function Count (C : Cache) return Natural;

   --  What the cache knows about one path.
   type Value is record
      Hash        : Core.Graph_Model.Hash;
      --  Core.Tag_Payload's encoding of every tag found. Empty means parsed
      --  and declared nothing, which is not the same as unsupported.
      Tags        : Unbounded_String;
      Unsupported : Boolean := False;
   end record;

   type Maybe_Value (Found : Boolean := False) is record
      case Found is
         when True =>
            Item : Value;

         when False =>
            null;
      end case;
   end record;

   function Get (C : in out Cache; Path : String) return Maybe_Value;

   --  A path and the content hash the caller currently sees for it.
   type Path_Hash is record
      Path : Unbounded_String;
      Hash : Core.Graph_Model.Hash;
   end record;

   package Path_Hash_Vectors is new Ada.Containers.Vectors
     (Positive, Path_Hash);

   use type Core.Graph_Model.Hash;

   --  The requested pairs not held at that hash, in order and without a
   --  repeated path (the first wins): the answer feeds an extractor, and a
   --  repeat would be tagged twice.
   function Needs_Tagging
     (C : in out Cache; Requested : Path_Hash_Vectors.Vector)
      return Path_Hash_Vectors.Vector;

   type Update is record
      Path  : Unbounded_String;
      Which : Value;
   end record;

   package Update_Vectors is new Ada.Containers.Vectors (Positive, Update);

   --  Applies Updates, drops Removals, writes a new file and renames it over
   --  the original, so that a reader never sees a half-written cache; then
   --  reads that file again. A removal of a path also being updated removes
   --  it. Returns the rows actually removed: a path the cache never held is
   --  not an error and is not counted. Raises Unreadable_Cache when Open could
   --  not read an existing file.
   --
   --  One writer: two commits racing against the same file both read the
   --  cache before either writes, and the loser's rename discards what the
   --  winner added. That costs a handful of entries that the next stale hash
   --  brings back whole, and nothing has hit it.
   function Commit
     (C        : in out Cache; Updates : Update_Vectors.Vector;
      Removals :        Core.Text_Lists.Vector) return Natural;

   type Row_Sink is access procedure (Row : String);

   --  Every cached tag as an `_refs.tsv` row, in path order, passed to Emit
   --  one at a time: the payloads are too big to hold. Unsupported and
   --  evicted entries contribute nothing. The sorting of the rows is the
   --  writer's job and not this one's. Returns the number of rows.
   function Write_Refs (C : in out Cache; Emit : Row_Sink) return Natural;

private

   type Cache is limited new Ada.Finalization.Limited_Controlled with record
      Path   : Unbounded_String;
      Source : File_Byte_Source.Source;
      Opened : Boolean := False;
      Head   : Core.Tags_Cache_Format.Header;
      Why    : Issue   := None;
   end record;

   overriding procedure Finalize (C : in out Cache);

end Synapse.Adapters.Tags_Cache;
