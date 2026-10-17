--  `comments-sweep [--reenumerate]`: every tracked file's docstrings against
--  the docstring index.
package Synapse.Commands.Comments_Sweep is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

   --  The command without its arguments, for the repository at Identity_Path
   --  (`.` for the command line).
   function Sweep
     (Env : Environment; Identity_Path : String; Reenumerate : Boolean)
      return Exit_Code;

end Synapse.Commands.Comments_Sweep;
