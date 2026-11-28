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
--  is the only place a harness is told from another: each harness is one type
--  implementing `Headless`.

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

   --  A harness that can run one bounded, non-interactive session of a step.
   type Headless is interface;

   --  The command that runs Prompt as the session of Step. Fails, saying
   --  why, when the step asks for something the harness cannot do: a tool
   --  allowlist for a harness that has none.
   function Build
     (Item   : Headless;
      Step   : Resolved.Step;
      Prompt : String) return Command_Results.Result is abstract;

   --  What the process of this harness that ended as Ended came to. A harness
   --  that reports a quota or a rate limit is told from one that failed.
   function Interpret
     (Item  : Headless;
      Ended : Session_Process.Process_Outcome) return Reply is abstract;

   --  The implementation of Kind. It lives as long as the program.
   function For_Harness
     (Kind : Harnesses.Harness_Kind) return not null access constant
     Headless'Class;

   --  Adds the arguments that give Claude Code the permission level of Step:
   --  its permission mode and, for a read-only step, the tools that read.
   procedure Add_Claude_Permissions
     (Into : in out Synapse.Core.Text_Lists.Vector; Step : Resolved.Step);

   --  Adds the arguments that ask Step's harness for Step's model and effort:
   --  Claude `--model M --effort E`, Codex
   --  `-m M -c model_reasoning_effort="E"`, OpenCode `-m M#E`.
   --  Adds nothing for what the step does not name.
   procedure Add_Model_And_Effort
     (Into : in out Synapse.Core.Text_Lists.Vector; Step : Resolved.Step);

   --  The model reference OpenCode is given: Step's model, then "#" and its
   --  effort when it names one. Only called when Step names a model.
   function Opencode_Model (Step : Resolved.Step) return String;

   --  The name of the sandbox Codex gives Step: the level of its permissions.
   function Codex_Sandbox (Step : Resolved.Step) return String;

   --  The configuration an OpenCode session of Step is given in
   --  OPENCODE_CONFIG_CONTENT: the permissions of its level and, when
   --  With_Model is set and the step names one, its model. Empty when there is
   --  nothing to set.
   function Opencode_Config
     (Step : Resolved.Step; With_Model : Boolean) return String;

   --  Whether a harness's message says a quota or a rate limit was reached.
   function Is_Quota_Message (Text : String) return Boolean;

end Synapse.Pipeline.Harness_Commands;
