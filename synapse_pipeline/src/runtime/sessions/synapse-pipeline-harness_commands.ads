with Ada.Strings.Unbounded;

with Synapse.Core.Results;
with Synapse.Core.Text_Lists;
with Synapse.Pipeline.Failures;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Resolved;
with Synapse.Pipeline.Session_Process;
with Synapse.Pipeline.Sessions;

--  What each harness is asked and what it answers: the command line that runs
--  one non-interactive session of a step on a harness, and what a finished
--  process of that harness amounts to. Pure, so each harness is covered with
--  the output it really writes.
--
--  Permission levels become what the harness can enforce: Claude's permission
--  modes and tool set, Codex's sandbox modes, and OpenCode's permission
--  settings. Which program a harness is run as, and where its output is found,
--  is the only place a harness is told from another.

package Synapse.Pipeline.Harness_Commands is

   type Command is record
      Program        : Ada.Strings.Unbounded.Unbounded_String;
      Arguments      : Synapse.Core.Text_Lists.Vector;

      --  `NAME=value` entries the session needs added.
      Environment    : Synapse.Core.Text_Lists.Vector;
      Standard_Input : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Command_Results is new Synapse.Core.Results
     (Command, Ada.Strings.Unbounded.Unbounded_String);

   --  The command that runs Prompt as the session of Item. Skill_Directory is
   --  the directory of the step's skill, empty when it has none. Fails, saying
   --  why, when the step asks for something the harness cannot do: a tool
   --  allowlist for a harness that has none.
   function Build
     (Harness         : Harnesses.Harness_Kind;
      Item            : Resolved.Step;
      Prompt          : String;
      Skill_Directory : String) return Command_Results.Result;

   --  What a process that ran said.
   type Reply (Succeeded : Boolean := False) is record
      Usage : Sessions.Usage_Report;

      case Succeeded is
         when True =>
            --  The agent's final answer, to be checked as an envelope.
            Answer  : Ada.Strings.Unbounded.Unbounded_String;

         when False =>
            Failure : Failures.Failure;
      end case;
   end record;

   --  What the process of Harness that ended as Ended came to. A harness
   --  that reports a quota or a rate limit is told from one that failed.
   function Interpret
     (Harness : Harnesses.Harness_Kind;
      Ended   : Session_Process.Process_Outcome) return Reply;

   --  Whether a harness's message says a quota or a rate limit was reached.
   function Is_Quota_Message (Text : String) return Boolean;

end Synapse.Pipeline.Harness_Commands;
