--  `build-refs` and `callers`: the writer and the reader of `_refs.tsv`, the
--  index of every def and ref of a name in a checkout, sorted so a name is
--  found by bisection.
package Synapse.Commands.Refs is

   --  `build-refs [--cache <f>] [--out <f>]`: projects the tags cache into the
   --  index, written by a rename so a reader never sees half of it.
   function Run_Build
     (Env : Environment; Args : Lists.Vector) return Exit_Code;

   --  `callers <name> [--all] [--refs <f>|--namespace <repo>@<branch>]`: the
   --  calls of an exact name as `path:line<TAB>expression`, or with `--all`
   --  every def and ref as `def|ref<TAB>kind<TAB>path:line<TAB>expression`.
   function Run_Callers
     (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Refs;
