--  `vault-check`: a read-only audit of every note that declares a schema.
package Synapse.Commands.Vault_Check is

   --  One `path<TAB>message` row for each schema-declaring note that does not
   --  conform, a summary line, and the advisory lints of the notes that do.
   --  Returns 1 when any note does not conform; a note with no schema is
   --  counted and never a violation.
   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Vault_Check;
