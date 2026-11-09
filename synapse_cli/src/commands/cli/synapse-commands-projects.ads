--  `synapse projects`: the projects of `synapse-projects.conf`, the list of
--  `name=prefix` lines that says which folder a project's notes are in and
--  what its note ids start with.
--
--    projects [list] [--format json|text]   the projects, and the file
--    projects add <name> <prefix>           one more, checked first
--
--  The file is the one the skills find: the first that exists of
--  `$XDG_CONFIG_HOME/synapse/`, `~/.config/synapse/` and `~/.claude/`, and a
--  new one made in the first of those that can hold it.

package Synapse.Commands.Projects is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Projects;
