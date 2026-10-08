--  The docstring style rubric: the text of `synapse-comment-style-rules.conf`,
--  found through the configuration tiers, or nothing. Plain English applied by
--  inference and not parsed.
package Synapse.Commands.Style_Rubric is

   function Text (Env : Environment) return String;

end Synapse.Commands.Style_Rubric;
