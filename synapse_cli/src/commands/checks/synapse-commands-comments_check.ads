--  `comments-check <path>`: one file's docstrings against the docstring
--  index, the index refreshed with what a parse finds.
package Synapse.Commands.Comments_Check is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Comments_Check;
