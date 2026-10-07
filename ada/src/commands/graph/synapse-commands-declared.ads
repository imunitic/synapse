--  `build-deps` and `build-namespaces`: the per-file facts a project declares
--  about itself, written as tab separated files into the work directory. Both
--  take their rules from a configuration file that ships empty, and write an
--  empty file when it is.
package Synapse.Commands.Declared is

   --  `build-deps [--repo <path>] [--out <path>]`: `_deps.tsv`, a row per
   --  file and library it declares a dependency on.
   function Run_Deps (Env : Environment; Args : Lists.Vector) return Exit_Code;

   --  `build-namespaces [--repo <path>] [--out <path>]`: `_namespaces.tsv`, a
   --  row per file and namespace it declares, more than one when its rule has
   --  aliases.
   function Run_Namespaces
     (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Declared;
