--  `enumerate`: the tracked files worth graphing, written to the work
--  directory.
package Synapse.Commands.Enumerate is

   --  `enumerate [--reenumerate]`.
   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

   --  The command without its arguments, for the repository at Identity_Path
   --  (`.` for the command line).
   function Enumerate
     (Env : Environment; Identity_Path : String; Reenumerate : Boolean)
      return Exit_Code;

   --  Brings `all.txt` and `oversize.txt` up to date and reports on standard
   --  output: a banner when it rebuilds, the oversize report when anything
   --  was skipped, and `enumerated: N`. An existing non-empty `all.txt` is
   --  reused unless Reenumerate says to rebuild it. False, after saying why,
   --  when git cannot list the files.
   function Ensure
     (Env : Environment; Repo_Root, Work_Dir : String; Reenumerate : Boolean)
      return Boolean;

end Synapse.Commands.Enumerate;
