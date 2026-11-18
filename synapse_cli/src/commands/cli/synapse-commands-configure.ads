--  `synapse configure <harness>`: installs Synapse for Claude Code, Codex or
--  OpenCode.
--
--  What is installed is found in the folder SYNAPSE_CONTENT_ROOT names, else
--  the folder above this program's own: the skills and commands, the hook
--  templates and plugin of each harness, and `synapse.conf.template`. The hook
--  program is the `synapse-hook` beside this program.
--
--    claude    skills and commands into ~/.claude, the hooks and
--              SYNAPSE_CONTENT_ROOT into ~/.claude/settings.json
--    codex     the hooks into ~/.codex/hooks.json, the skills into
--              ~/.codex/skills
--    opencode  the plugin, skills and commands into ~/.config/opencode
--
--  A file of a harness that holds more than Synapse's own is merged into, and
--  a copy of it is kept beside it as `.bak`. A manifest in each folder of
--  skills or commands records the names written, so that one that is no longer
--  shipped is removed on the next run and nothing else in the folder is
--  touched. A `synapse.conf` is made from its template when there is none.

package Synapse.Commands.Configure is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Commands.Configure;
