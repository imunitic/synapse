with Synapse.Hooks.Common;
--  `prompt-context`: UserPromptSubmit. One standing line per turn, in a
--  repository with a namespace: the graph exists, query it before grepping.
--  No search, no node list, no network. `SYNAPSE_DISABLE_PROMPT_INJECTION`,
--  set to anything, turns it off.
--
--  Phrased as an instruction and not advice, with an explicit order ("do not
--  grep until Synapse has named the file"): advice was treated as advice.
--  The graph and the code cache are named apart, each only when it is there.
package Synapse.Hooks.Prompt_Context is

   procedure Run (Env : Environment);

   --  The line, or none when nothing should be said, for the repository at
   --  Cwd.
   function Build (Env : Environment; Cwd : String) return Common.Maybe_Text;

end Synapse.Hooks.Prompt_Context;
