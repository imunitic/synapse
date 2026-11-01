with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Core.Optional_Text;
with Synapse.Core.Options;
with Synapse.Pipeline.Harnesses;

--  A pipeline with everything it refers to settled: each step holds the
--  values it will run with, and no name is left to look up. This is what a
--  running execution works from and what its snapshot holds.

package Synapse.Pipeline.Resolved is

   type Instruction_Kind is (Prompt_Text, Skill_Name);

   --  What an agent or a step tells the agent session: the text of a
   --  prompt, or the name of a skill. Nothing when none was given.
   type Instruction (Present : Boolean := False) is record
      case Present is
         when True =>
            Kind : Instruction_Kind;
            Text : Ada.Strings.Unbounded.Unbounded_String;

         when False =>
            null;
      end case;
   end record;

   --  A definition a step was built from, and the file it came from.
   type Origin_Kind is (System_Origin, Agent_Origin);

   type Origin is record
      Kind : Origin_Kind;
      Name : Ada.Strings.Unbounded.Unbounded_String;
      File : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Origin_Vectors is new Ada.Containers.Vectors (Positive, Origin);

   package Json_Options is new Synapse.Core.Options (Synapse.Core.JSON.Value);

   type Step is record
      Name        : Ada.Strings.Unbounded.Unbounded_String;
      Harness     : Harnesses.Harness_Kind;

      --  The role, from the step's agent: who the session is.
      Role        : Instruction;

      --  The assignment, from the step itself or else its system: what to
      --  do.
      Assignment  : Instruction;

      Model       : Synapse.Core.Optional_Text.Option;
      Permissions : Synapse.Core.Optional_Text.Option;

      --  A JSON list of the tools the session may use.
      Tools       : Json_Options.Option;

      --  Zero when the configuration's default applies.
      Timeout_Seconds : Natural := 0;
      Retries     : Natural := 0;

      --  The system and the agent the step's values came from.
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
      Max_Iterations : Natural := 0;
   end record;

   package Edge_Vectors is new Ada.Containers.Vectors (Positive, Edge);

   type Pipeline is record
      Name  : Ada.Strings.Unbounded.Unbounded_String;

      --  In the order they were declared.
      Steps : Step_Vectors.Vector;

      --  In the order they were written; the first true guard of the edges
      --  leaving a step is the one that fires.
      Edges : Edge_Vectors.Vector;
   end record;

end Synapse.Pipeline.Resolved;
