--  `tags`: the tags of one file, of every file of a list in one batch, and
--  the extensions that have a usable grammar.
--
--  Exit codes: 0 for tags printed (in a batch whenever the batch ran, even if
--  some extensions had no grammar), 1 for what cannot be done now (no
--  extension, an unsupported entry, a missing file, a grammar that would not
--  build), 2 for an extension with no registry entry at all, so the caller
--  can run grammar discovery and try again. Only a single file can answer 2.
package Synapse.Commands.Tags is

   --  `tags <file>`, `tags --paths <list-file>` or `tags --list-extensions`.
   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Tags;
