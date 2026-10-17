--  `vault-read`, `vault-list` and `vault-doc-map`: reading notes by their
--  whole vault path.
package Synapse.Commands.Vault_Read is

   --  `vault-read <path>`: the note's whole text.
   function Run_Read (Env : Environment; Args : Lists.Vector) return Exit_Code;

   --  `vault-list`: every note's path, one per line.
   function Run_List (Env : Environment; Args : Lists.Vector) return Exit_Code;

   --  `vault-doc-map <path>`: `kind<TAB>value` for every heading path, block
   --  id and frontmatter key a `vault-patch` could name.
   function Run_Doc_Map
     (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Vault_Read;
