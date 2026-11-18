--  `synapse-pipeline configure <harness>`: installs the skills of this
--  program for Claude Code, Codex or OpenCode.
--
--  Each skill under `skills/` in the folder SYNAPSE_CONTENT_ROOT names is
--  copied, with everything beside its SKILL.md, into the harness's skills
--  folder in the home directory, replacing the copy that is there. A manifest
--  in that folder records the names written, so that a skill that is no longer
--  shipped is removed on the next run; nothing the manifest does not list is
--  touched.

package Synapse.Pipeline.Commands.Configure is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

end Synapse.Pipeline.Commands.Configure;
