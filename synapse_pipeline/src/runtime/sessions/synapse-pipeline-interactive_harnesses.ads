with Ada.Strings.Unbounded;

with Synapse.Core.Text_Lists;
with Synapse.Pipeline.File_System;
with Synapse.Pipeline.Harness_Commands;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Resolved;

--  What each harness is asked and what it leaves behind when a step runs
--  interactively: the command line that starts the harness on the terminal the
--  pipeline was given, where the transcript of that session is, and what a
--  transcript says about the latest turn. The harness writes the transcript
--  itself, so none of this needs the harness's output to pass through the
--  pipeline. Pure, so each harness is covered with a transcript it really
--  wrote.
--
--  A harness that implements `Interactive` can run a step with
--  `--interactive`.

package Synapse.Pipeline.Interactive_Harnesses is

   --  What the runner knows about a session it starts.
   type Session_Handle is record
      --  A text that is unique to the session, which the runner chooses. A
      --  harness that takes a session id is given it as one, so it is a UUID;
      --  a harness that does not has it put in the prompt, to find the
      --  session by.
      Id        : Ada.Strings.Unbounded.Unbounded_String;

      --  The directory the harness is run in.
      Directory : Ada.Strings.Unbounded.Unbounded_String;

      --  The home directory of the user the harness runs as.
      Home      : Ada.Strings.Unbounded.Unbounded_String;

      --  The local date the session was started, as `YYYY/MM/DD`, which
      --  names the folder a harness that sorts its sessions by day keeps
      --  them in.
      Day       : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   --  Where the transcript of a session is read from: a file the harness
   --  writes, or the output of a command that prints it.
   type Source_Kind is (Not_Yet, From_File, From_Command);

   type Transcript_Source (Kind : Source_Kind) is record
      case Kind is
         when Not_Yet       => null;
         when From_File     =>
            Path : Ada.Strings.Unbounded.Unbounded_String;
         when From_Command  =>
            Run  : Harness_Commands.Command;
      end case;
   end record;

   --  What a transcript says about the latest turn: whether the agent has
   --  finished it and, if so, the text of its final message. A turn is
   --  finished when the agent has stopped to hand control back, not while it
   --  is still working or waiting on a tool.
   type Turn_State is record
      Finished : Boolean := False;
      Final    : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   type Interactive is interface;

   --  The command that starts Step as an interactive session, with Prompt as
   --  its first message. Skill_Directory is the directory of the step's skill,
   --  empty when it has none. The harness inherits the terminal, so the
   --  command has no standard input.
   function Build
     (Item            : Interactive;
      Step            : Resolved.Step;
      Prompt          : String;
      Skill_Directory : String;
      Session         : Session_Handle)
      return Harness_Commands.Command_Results.Result is abstract;

   --  Where the transcript of Session is read from, or `Not_Yet` when that
   --  cannot be told, which includes a harness that has not yet started
   --  writing it. A command prints the transcript when it succeeds, and a
   --  session that does not exist yet makes it fail.
   function Locate
     (Item    : Interactive;
      Session : Session_Handle;
      Files   : File_System.File_System'Class)
      return Transcript_Source is abstract;

   --  What Transcript, the text of that source as read so far, says about
   --  the latest turn. A last line still being written is ignored.
   function Read_Turns
     (Item       : Interactive;
      Transcript : String) return Turn_State is abstract;

   --  The implementation of Kind, or null when that harness cannot run a step
   --  interactively. It lives as long as the program.
   function For_Harness
     (Kind : Harnesses.Harness_Kind) return access constant Interactive'Class;

   --  Which harnesses can run a step interactively.
   type Support is array (Harnesses.Harness_Kind) of Boolean;

   --  The support there is: a harness that has an implementation.
   function Implemented return Support;

   --  What stops Item from being run interactively, one line for each step
   --  whose harness cannot run a step that way, naming the step and the
   --  harness. Empty when every step can.
   function Problems
     (Item : Resolved.Pipeline; Can : Support := Implemented)
      return Synapse.Core.Text_Lists.Vector;

end Synapse.Pipeline.Interactive_Harnesses;
