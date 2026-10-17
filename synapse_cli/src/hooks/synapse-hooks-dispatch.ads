with Synapse.Commands;

--  `synapse-hook <hook>`: the four hooks, and the pull `session-start` starts
--  detached. A hook that fails is not allowed to be seen to: whatever goes
--  wrong inside one, the exit code is 0. Only a name that is not a hook is an
--  error.
package Synapse.Hooks.Dispatch is

   function Run
     (Env : Environment; Args : Synapse.Commands.Lists.Vector)
      return Synapse.Commands.Exit_Code;

end Synapse.Hooks.Dispatch;
