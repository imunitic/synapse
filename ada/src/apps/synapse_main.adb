with Ada.Command_Line;
with Ada.Strings.Unbounded;

with Synapse.Adapters.System_Clock;
with Synapse.Adapters.System_Console;
with Synapse.Adapters.System_Process;
with Synapse.Adapters.System_Variables;
with Synapse.Commands.Dispatch;

--  The `synapse` executable: the subcommands over the real console, process
--  environment, clock and process runner.

procedure Synapse_Main is
   use Synapse;

   Console : aliased Adapters.System_Console.System_Console;
   Vars    : aliased Adapters.System_Variables.System_Variables;
   Runner  : aliased Adapters.System_Process.System_Runner;
   Clock   : aliased Adapters.System_Clock.System_Clock;

   Env  : constant Commands.Environment :=
     (Console => Console'Access, Vars => Vars'Access, Runner => Runner'Access,
      Clock   => Clock'Access,
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
     (Ada.Command_Line.Exit_Status (Commands.Dispatch.Run (Env, Args)));
end Synapse_Main;
