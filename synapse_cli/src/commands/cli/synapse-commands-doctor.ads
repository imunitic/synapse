--  `doctor [--repo <dir>] [--install] [--format text|json]`: every silent guard
--  of the system, said aloud. Checks are ordered as an install is built
--  (dependencies, the harnesses, configuration, vault, identity, namespace,
--  derived files, hooks), so a reader who stops at the first failure has
--  usually found the cause and not a symptom.
--
--  The programs are looked for on the PATH the command runs with, so that a
--  caller with another PATH, such as the one of a login shell, finds what a
--  terminal finds. A harness that is not installed is not a fault unless none
--  is: Synapse does nothing without one. The exit code is 1 when anything
--  failed, whichever the format. With --install only what is the install's is
--  checked and nothing of a checkout, for a caller that is not in one.
package Synapse.Commands.Doctor is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

   --  The command without its arguments, for the checkout at Repo.
   function Diagnose
     (Env     : Environment; Repo : String; As_Json : Boolean := False;
      Install : Boolean := False) return Exit_Code;

end Synapse.Commands.Doctor;
