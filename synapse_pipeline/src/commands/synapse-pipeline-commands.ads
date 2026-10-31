with Ada.Strings.Unbounded;

with Synapse.Core.Text_Lists;
with Synapse.Ports.Clock;
with Synapse.Ports.Console;
with Synapse.Ports.Process_Runner;
with Synapse.Ports.Variables;
with Synapse.Pipeline.File_System;
with Synapse.Pipeline.Inspector_Transport;
with Synapse.Pipeline.Session_Process;

--  The subcommands of the `synapse-pipeline` executable. Each is a function
--  of its arguments and an Environment: what it may read, run and write, all
--  passed in, so a command is tested by calling it and looking at what it
--  printed and what it returned.

package Synapse.Pipeline.Commands is

   --  What the process returns: 0 for success, 1 for a failure the command
   --  explains, 2 for a usage error.
   subtype Exit_Code is Natural range 0 .. 255;

   --  Everything a command may reach for. Access discriminants, so that the
   --  things it points at can be local to the program or the test that builds
   --  it.
   type Environment
     (Console : not null access Synapse.Ports.Console.Console'Class;
      Vars    : not null access Synapse.Ports.Variables.Variables'Class;
      Runner  : not null access Synapse.Ports.Process_Runner.Runner'Class;
      Clock   : not null access Synapse.Ports.Clock.Clock'Class;
      Files   :
        not null access Synapse.Pipeline.File_System.File_System'Class;
      Inspector :
        not null access Synapse.Pipeline.Inspector_Transport.Transport'Class;
      Sessions  :
        not null access Synapse.Pipeline.Session_Process.Process'Class)
   is limited record
      --  How this program was started.
      Argv0 : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  Text to standard output, exactly as given.
   procedure Say (Env : Environment; Text : String);

   --  Text to standard error, exactly as given.
   procedure Complain (Env : Environment; Text : String);

   --  The text of a command's usage error, and the code it returns: 2.
   function Usage_Error
     (Env : Environment; Usage_Text : String) return Exit_Code;

   package Lists renames Synapse.Core.Text_Lists;

end Synapse.Pipeline.Commands;
