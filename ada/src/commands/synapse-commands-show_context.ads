--  `synapse context`: what a session needs to use this checkout's graph: the
--  absolute namespace directory and the question to command map. The map the
--  session start hook injects, so what a person sees here is what a session
--  was told.

package Synapse.Commands.Show_Context is

   function Run (Env : Environment; Args : Lists.Vector) return Exit_Code;

   --  The graph directory line and then the map.
   function Text (Abs_Dir : String) return String;

end Synapse.Commands.Show_Context;
