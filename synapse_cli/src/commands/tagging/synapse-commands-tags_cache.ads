with Synapse.Adapters.Tags_Cache;

--  `tags-cache`: the cache of every file's tags, kept up to date by content
--  hash, and the views of it.
package Synapse.Commands.Tags_Cache is

   --  `tags-cache --repo-root <dir> --cache <file> --paths <tsv>` brings the
   --  cache up to date for the listed `path<TAB>hash` pairs; `--dump <file>`
   --  says what it holds, `--load <file>` builds one from `--dump`'s text on
   --  standard input, and `--refs <file>` prints its `_refs.tsv` rows.
   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

   --  Tags whatever the cache lacks for Requested and commits it, under
   --  Repo_Root. A file the extractor cannot handle is recorded as such, so
   --  it is not tried again. False when it could not be done: the grammar
   --  settings are unreadable, or the commit failed. Nothing is said, since a
   --  caller that refreshes in passing does not fail for it; the cache is
   --  read after this returns, never across it.
   type Backfill_Outcome is (Done, Could_Not_Tag, Could_Not_Commit);

   --  The same, saying which part failed: the settings or the extraction
   --  that tags, or the commit that records it. The files to tag are cut
   --  into slices of Chunk (at least 500 when it is 0, or enough to give
   --  each processor one), and each slice is tagged by a task with an
   --  extractor of its own; the slices are put back in order before the one
   --  commit, so the cache does not depend on how many tasks there were.
   function Backfill_Detailed
     (Env       :        Environment; Repo_Root : String;
      Cache     : in out Adapters.Tags_Cache.Cache;
      Requested :        Adapters.Tags_Cache.Path_Hash_Vectors.Vector;
      Chunk     :        Natural := 0) return Backfill_Outcome;

   function Backfill
     (Env       :        Environment; Repo_Root : String;
      Cache     : in out Adapters.Tags_Cache.Cache;
      Requested : Adapters.Tags_Cache.Path_Hash_Vectors.Vector) return Boolean;

end Synapse.Commands.Tags_Cache;
