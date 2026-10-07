--  The link subcommands over a vault's own graph of wikilinks.
package Synapse.Commands.Vault_Links is

   --  `vault-backlinks <path>`: `node<TAB>count` per note linking to it.
   function Run_Backlinks
     (Env : Environment; Args : Lists.Vector) return Exit_Code;

   --  `vault-links <path>`: each note it links to, one per line.
   function Run_Links
     (Env : Environment; Args : Lists.Vector) return Exit_Code;

   --  `vault-unresolved`: `source<TAB>target<TAB>count` per broken link.
   function Run_Unresolved
     (Env : Environment; Args : Lists.Vector) return Exit_Code;

   --  `vault-orphans`: the notes nothing links to.
   function Run_Orphans
     (Env : Environment; Args : Lists.Vector) return Exit_Code;

   --  `vault-deadends`: the notes with no link to a note.
   function Run_Deadends
     (Env : Environment; Args : Lists.Vector) return Exit_Code;

   --  `vault-ambiguous`: `source<TAB>target<TAB>candidate<TAB>count` per
   --  source and candidate of a link that names several notes.
   function Run_Ambiguous
     (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Vault_Links;
