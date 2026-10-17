with Ada.Command_Line;
with Ada.Strings.Unbounded;

with Synapse.Adapters.Null_Extractors;
with Synapse.Adapters.System_Clock;
with Synapse.Adapters.System_Console;
with Synapse.Adapters.System_Process;
with Synapse.Adapters.System_Variables;
with Synapse.Commands;
with Synapse.Hooks.Dispatch;

--  The `synapse-hook` executable: the four Claude Code hooks over the real
--  console, environment, clock and process runner. It links no grammar, and
--  its exit code is 0 whatever happens, but for a hook name it does not know.
procedure Synapse_Hook_Main is
   use Synapse;

   Console    : aliased Adapters.System_Console.System_Console;
   Vars       : aliased Adapters.System_Variables.System_Variables;
   Runner     : aliased Adapters.System_Process.System_Runner;
   Clock      : aliased Adapters.System_Clock.System_Clock;
   Extractors : aliased Adapters.Null_Extractors.Null_Factory;

   Env  : constant Commands.Environment :=
     (Console => Console'Access, Vars => Vars'Access, Runner => Runner'Access,
      Clock   => Clock'Access, Extractors => Extractors'Access,
      Argv0   =>
        Ada.Strings.Unbounded.To_Unbounded_String
          (Ada.Command_Line.Command_Name));
   Args : Commands.Lists.Vector;
begin
   for I in 1 .. Ada.Command_Line.Argument_Count loop
      Args.Append
        (Ada.Strings.Unbounded.To_Unbounded_String
           (Ada.Command_Line.Argument (I)));
   end loop;
   Ada.Command_Line.Set_Exit_Status
     (Ada.Command_Line.Exit_Status (Hooks.Dispatch.Run (Env, Args)));
end Synapse_Hook_Main;
