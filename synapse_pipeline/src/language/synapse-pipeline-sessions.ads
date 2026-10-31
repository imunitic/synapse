with Synapse.Core.JSON;
with Synapse.Core.Optional_Text;
with Synapse.Pipeline.Configs;
with Synapse.Pipeline.Envelopes;
with Synapse.Pipeline.Failures;
with Synapse.Pipeline.Resolved;
with Synapse.Pipeline.States;

--  One agent session as the engine asks for it and as it comes back: what the
--  runner is given to run, and what it hands back, a result that has already
--  been checked or the reason there is none.

package Synapse.Pipeline.Sessions is

   use type Failures.Failure_Kind;

   --  What a harness reported about a session, where it reported anything.
   type Usage_Report is record
      Reported        : Boolean := False;
      Input_Tokens    : Natural := 0;
      Output_Tokens   : Natural := 0;

      --  How long the session took, as the runner measured it.
      Elapsed_Seconds : Natural := 0;
   end record;

   --  Everything a session is run from. The step says what to do and how;
   --  the rest is the run's state and settings, which are the same however
   --  the session is run.
   type Session_Request is record
      Step            : Resolved.Step;
      Initial_Input   : Synapse.Core.JSON.Value;
      Previous_Output : Synapse.Core.JSON.Value;
      Settings        : Configs.Config;

      --  How long the session may take: the step's own limit, else the
      --  configuration's.
      Timeout_Seconds : Positive := Configs.Default_Timeout;

      --  Which try this is for the step, from 1.
      Attempt         : Positive := 1;
   end record;

   --  The request to run Item as the next session of the run in State.
   function Request_For
     (Item     : Resolved.Step;
      Run      : States.State;
      Settings : Configs.Config;
      Attempt  : Positive := 1) return Session_Request;

   --  What a session came to: a result that passed the envelope's checks, or
   --  a failure. A runner never reports that the ceiling was reached; only the
   --  engine counts steps.
   type Session_Result (Succeeded : Boolean := False) is record
      Usage      : Usage_Report;

      --  The file the session's transcript was kept in, when it was kept.
      Transcript : Synapse.Core.Optional_Text.Option;

      case Succeeded is
         when True =>
            Result  : Envelopes.Envelope;

         when False =>
            Failure : Failures.Failure;
      end case;
   end record;

   function Success
     (Item       : Envelopes.Envelope;
      Used       : Usage_Report := (others => <>);
      Transcript : Synapse.Core.Optional_Text.Option :=
        Synapse.Core.Optional_Text.None) return Session_Result;

   function Failed
     (Item       : Failures.Failure;
      Used       : Usage_Report := (others => <>);
      Transcript : Synapse.Core.Optional_Text.Option :=
        Synapse.Core.Optional_Text.None) return Session_Result
   with Pre => Item.Kind /= Failures.Ceiling_Reached;

end Synapse.Pipeline.Sessions;
