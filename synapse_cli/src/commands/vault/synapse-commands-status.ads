--  `synapse status [--format text|json]`: what in the vault currently needs a
--  human decision, read-only.
--
--  Five categories over `designs/` and `tasks/`: design notes still being
--  discussed, ready design notes with no compiled task, ready design notes
--  with open questions, open tasks with unchecked items, and tasks waiting for
--  review. The text is a section for each category that has items; the JSON is
--  `synapse-status/v1`, every category with its items and the path of each.

package Synapse.Commands.Status is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Status;
