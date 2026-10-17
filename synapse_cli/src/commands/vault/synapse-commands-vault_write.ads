--  The subcommands that change the vault: write, patch, rename and delete a
--  note by its whole vault path, and the background push a write may start.
package Synapse.Commands.Vault_Write is

   --  `vault-write <path>`, the note's whole new text on standard input.
   function Run_Write
     (Env : Environment; Args : Lists.Vector) return Exit_Code;

   --  `vault-patch <path> --heading|--block|--frontmatter <t> [operation]
   --  [--create]`, the content on standard input.
   function Run_Patch
     (Env : Environment; Args : Lists.Vector) return Exit_Code;

   --  `vault-rename <old> <new>`.
   function Run_Rename
     (Env : Environment; Args : Lists.Vector) return Exit_Code;

   --  `vault-delete <path>`.
   function Run_Delete
     (Env : Environment; Args : Lists.Vector) return Exit_Code;

   --  `vault-git-pusher <vault>`: what a write starts in the background. It
   --  has no usage and is not meant to be typed.
   function Run_Git_Pusher
     (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Vault_Write;
