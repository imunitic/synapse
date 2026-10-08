--  `doctor [--repo <dir>]`: every silent guard of the system, said aloud.
--  Checks are ordered as an install is built (dependencies, configuration,
--  vault, identity, namespace, derived files, hooks), so a reader who stops at
--  the first failure has usually found the cause and not a symptom.
package Synapse.Commands.Doctor is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

   --  The command without its arguments, for the checkout at Repo.
   function Diagnose (Env : Environment; Repo : String) return Exit_Code;

end Synapse.Commands.Doctor;
