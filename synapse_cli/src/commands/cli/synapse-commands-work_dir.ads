--  `synapse work-dir [--root | --list | --namespace <repo>@<branch>]`: where
--  Synapse keeps its working files.
--
--  With no argument, the folder of the namespace of the repository the command
--  is run in; with --namespace, that of another one; with --root, the work
--  directory root they are folders of. The root is the `SYNAPSE_WORK_DIR`
--  variable or setting, else `.cache/synapse/work` in the home directory.
--  With --list, each namespace that has a folder in the root and an index, a
--  reference index or a tags cache in it, one to a line: its name, a tab and
--  which of `index`, `refs` and `tags` it has. Nothing is created.

package Synapse.Commands.Work_Dir is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Work_Dir;
