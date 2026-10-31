with Ada.Command_Line;
with Ada.Strings.Unbounded;

with Synapse.Adapters.System_Clock;
with Synapse.Adapters.System_Console;
with Synapse.Adapters.System_Process;
with Synapse.Adapters.System_Variables;
with Synapse.Pipeline.Commands.Dispatch;
with Synapse.Pipeline.System_Files;
with Synapse.Pipeline.System_Inspector;
with Synapse.Pipeline.System_Process;

--  The `synapse-pipeline` executable: the subcommands over the real console,
--  process environment, clock and process runner.

procedure Synapse_Pipeline_Main is
   use Synapse.Pipeline;

   Console : aliased Synapse.Adapters.System_Console.System_Console;
   Vars    : aliased Synapse.Adapters.System_Variables.System_Variables;
   Runner  : aliased Synapse.Adapters.System_Process.System_Runner;
   Clock   : aliased Synapse.Adapters.System_Clock.System_Clock;
   Files   : aliased Synapse.Pipeline.System_Files.System_Files;
   Inspector :
     aliased Synapse.Pipeline.System_Inspector.System_Transport;
   Sessions : aliased Synapse.Pipeline.System_Process.System_Process;

   Env  : constant Commands.Environment :=
     (Console => Console'Access, Vars => Vars'Access,
      Runner  => Runner'Access, Clock => Clock'Access,
      Files   => Files'Access, Inspector => Inspector'Access,
      Sessions => Sessions'Access,
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
end Synapse_Pipeline_Main;
