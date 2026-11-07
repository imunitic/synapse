--  `synapse work-dir [--root | --namespace <repo>@<branch>]`: where Synapse
--  keeps its working files.
--
--  With no argument, the folder of the namespace of the repository the command
--  is run in; with --namespace, that of another one; with --root, the work
--  directory root they are folders of. The root is the `SYNAPSE_WORK_DIR`
--  variable or setting, else `.cache/synapse/work` in the home directory.
--  Nothing is created.

package Synapse.Commands.Work_Dir is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Work_Dir;
