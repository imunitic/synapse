--  `vocab`: the evidence for clustering a repository, six tables keyed by
--  one grouping of its files, written to the work directory:
--  `counts.tsv`, `groupwords.tsv`, `groupexts.tsv`, `namespaces.tsv`,
--  `parseable.tsv` and `distinctive.tsv`. What it prints is a number of
--  groups, files, code files and pairs, so a repository with no vocabulary is
--  not an empty file nobody notices.
--
--  Tagging and reducing are two passes, so raw tags never pile up: the first
--  tags only what the cache lacks and commits it, the second reduces the
--  vocabulary of every code file out of the now current cache.
package Synapse.Commands.Vocab is

   --  `vocab [--repo <path>] [--depth N] [--chunk N] [--out <dir>]
   --  [--lists <dir>] [--distinctive-top N] [--distinctive-k N]`. Files are
   --  grouped by the directory prefix of `--depth` segments, or with
   --  `--lists` by the node that lists them. Files the cache lacks are tagged
   --  by one task per processor, each taking `--chunk` files (at least 500
   --  when it is not given).
   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Vocab;
