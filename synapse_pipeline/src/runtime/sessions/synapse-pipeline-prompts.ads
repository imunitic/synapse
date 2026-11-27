with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.JSON;

--  The text a session is started with: who the agent is, what it is to do,
--  what the pipeline has handed it so far, and how to report. The same for
--  every harness.

package Synapse.Pipeline.Prompts is

   --  What a prompt is made of. The role and the assignment are the author's
   --  words; the rest is added to every step: the line saying
   --  which step it is and whether a person can answer, what the run was
   --  started with, what the step before reported, and how to report.
   type Part_Kind is
     (Role_Part, Assignment_Part, Protocol_Part, Input_Part, Previous_Part,
      Contract_Part);

   --  The name of a kind in the description of a prompt.
   function Name_Of (Kind : Part_Kind) return String is
     (case Kind is
        when Role_Part       => "role",
        when Assignment_Part => "assignment",
        when Protocol_Part   => "protocol",
        when Input_Part      => "input",
        when Previous_Part   => "previous",
        when Contract_Part   => "contract");

   type Part is record
      Kind : Part_Kind;
      Text : Ada.Strings.Unbounded.Unbounded_String;
   end record;

   package Part_Vectors is new Ada.Containers.Vectors (Positive, Part);

   --  Role and Assignment may be empty. Step is the step's name; Initial_Input
   --  is what the run began with and Previous_Output what the step before this
   --  one reported, null for the first. Outcomes is what the step declares it
   --  may end with, null when it declares none: the words and what each means
   --  are then the ones the reply is to choose from. In an interactive session
   --  a person can answer in the terminal, so the agent is told to ask when it
   --  needs to and to give the reply only when it is done; the reply it is
   --  asked for is the same.
   --  The parts of the prompt, in order, without the ones that are empty.
   function Parts
     (Role            : String;
      Assignment      : String;
      Step            : String;
      Initial_Input   : Synapse.Core.JSON.Value;
      Previous_Output : Synapse.Core.JSON.Value;
      Outcomes        : Synapse.Core.JSON.Value :=
        Synapse.Core.JSON.Null_Value;
      Interactive     : Boolean := False) return Part_Vectors.Vector;

   --  The prompt the parts make: each followed by a blank line.
   function Text_Of (Parts : Part_Vectors.Vector) return String;

   --  The prompt: its parts, each followed by a blank line.
   function Build
     (Role            : String;
      Assignment      : String;
      Step            : String;
      Initial_Input   : Synapse.Core.JSON.Value;
      Previous_Output : Synapse.Core.JSON.Value;
      Outcomes        : Synapse.Core.JSON.Value :=
        Synapse.Core.JSON.Null_Value;
      Interactive     : Boolean := False) return String;

end Synapse.Pipeline.Prompts;
