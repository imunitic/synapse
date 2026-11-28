with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Core.Optional_Text;
with Synapse.Core.Text_Lists;
with Synapse.Pipeline.Durations;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Limits;

--  A pipeline with everything it refers to settled: each step holds the
--  values it will run with, and no name is left to look up. This is what a
--  running execution works from and what its snapshot holds.

package Synapse.Pipeline.Resolved is

   --  What an agent or a step tells the agent session: the text of its
   --  prompt, written in place or taken from a Prompt definition. Nothing
   --  when none was given.
   type Instruction (Present : Boolean := False) is record
      case Present is
         when True =>
            Text : Ada.Strings.Unbounded.Unbounded_String;

         when False =>
            null;
      end case;
   end record;

   --  A definition a step was built from, and the file it came from.
   type Origin_Kind is (System_Origin, Agent_Origin, Prompt_Origin);

   type Origin is record
      Kind : Origin_Kind;
      Name : Ada.Strings.Unbounded.Unbounded_String;
      File : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Origin_Vectors is new Ada.Containers.Vectors (Positive, Origin);

   type Step is record
      Name        : Ada.Strings.Unbounded.Unbounded_String;
      Harness     : Harnesses.Harness_Kind;

      --  The role, from the step's agent: who the session is.
      Role        : Instruction;

      --  The assignment, from the step itself or else its system: what to
      --  do.
      Assignment  : Instruction;

      Model       : Synapse.Core.Optional_Text.Option;

      --  How much effort the model is asked to put in, as the harness is
      --  given it; nothing when neither the step nor its system names one.
      Effort      : Synapse.Core.Optional_Text.Option;

      Permissions : Synapse.Core.Optional_Text.Option;

      --  Zero when the configuration's default applies.
      Timeout_Seconds : Durations.Timeout_Seconds := 0;
      Retries     : Limits.Repeat_Count := 0;

      --  The outcomes the step may end with, an object from each word to its
      --  meaning; null when the step declares none and may end with any word.
      --  An outcome's `data` that names fields the pipeline declares holds
      --  their declarations instead of the names.
      Outcomes    : Synapse.Core.JSON.Value := Synapse.Core.JSON.Null_Value;

      --  The step's Data declaration, from the step itself or else its
      --  system: the fields it puts in data whatever its outcome. A list of
      --  names is replaced by the pipeline's declarations of those names, as
      --  `{"fields": ...}`; inline Data is as written. Null when neither
      --  declares one.
      Data        : Synapse.Core.JSON.Value := Synapse.Core.JSON.Null_Value;

      --  The names the step's Data and its outcomes' data took from the
      --  pipeline's Data, each once, in the order first met: Data first,
      --  then the outcomes in declared order. Empty when the step names
      --  none.
      Named_Fields : Synapse.Core.Text_Lists.Vector;

      --  The system, the agent and the prompts the step's values came from.
      Origins     : Origin_Vectors.Vector;
   end record;

   package Step_Vectors is new Ada.Containers.Vectors (Positive, Step);

   type Edge is record
      From           : Ada.Strings.Unbounded.Unbounded_String;
      To             : Ada.Strings.Unbounded.Unbounded_String;

      --  Whether the edge has a guard; without one it is unconditional.
      Has_Guard      : Boolean := False;

      --  The guard as a JsonLogic expression over the finished step's result.
      Guard          : Synapse.Core.JSON.Value;

      --  How many times the edge may fire; zero when it is not bounded.
      Max_Iterations : Limits.Repeat_Count := 0;
   end record;

   package Edge_Vectors is new Ada.Containers.Vectors (Positive, Edge);

   type Pipeline is record
      Name  : Ada.Strings.Unbounded.Unbounded_String;

      --  In the order they were declared.
      Steps : Step_Vectors.Vector;

      --  In the order they were written; the first true guard of the edges
      --  leaving a step is the one that fires.
      Edges : Edge_Vectors.Vector;

      --  The pipeline's Input declaration as written, which an input is
      --  checked against; null when the pipeline declares none.
      Input : Synapse.Core.JSON.Value := Synapse.Core.JSON.Null_Value;

      --  The pipeline's Data declaration as written, the shapes its steps
      --  name; null when the pipeline declares none. The steps already hold
      --  these shapes in place of the names.
      Data  : Synapse.Core.JSON.Value := Synapse.Core.JSON.Null_Value;
   end record;

end Synapse.Pipeline.Resolved;
