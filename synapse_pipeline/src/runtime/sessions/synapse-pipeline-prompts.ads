with Synapse.Core.JSON;

--  The text a session is started with: who the agent is, what it is to do,
--  what the pipeline has handed it so far, and how to report. The same for
--  every harness.

package Synapse.Pipeline.Prompts is

   --  Role and Assignment may be empty. Step is the step's name; Initial_Input
   --  is what the run began with and Previous_Output what the step before this
   --  one reported, null for the first.
   function Build
     (Role            : String;
      Assignment      : String;
      Step            : String;
      Initial_Input   : Synapse.Core.JSON.Value;
      Previous_Output : Synapse.Core.JSON.Value) return String;

end Synapse.Pipeline.Prompts;
