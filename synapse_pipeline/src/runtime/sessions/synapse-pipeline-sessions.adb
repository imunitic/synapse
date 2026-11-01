package body Synapse.Pipeline.Sessions is

   function Request_For
     (Item     : Resolved.Step;
      Run      : States.State;
      Settings : Configs.Config;
      Attempt  : Positive := 1) return Session_Request
   is
     (Step            => Item,
      Initial_Input   => Run.Initial_Input,
      Previous_Output => Run.Previous_Output,
      Settings        => Settings,
      Timeout_Seconds =>
        (if Item.Timeout_Seconds > 0 then Item.Timeout_Seconds
         else Settings.Default_Timeout_Seconds),
      Attempt         => Attempt);

   function Success
     (Item       : Envelopes.Envelope;
      Used       : Usage_Report := (others => <>);
      Transcript : Synapse.Core.Optional_Text.Option :=
        Synapse.Core.Optional_Text.None) return Session_Result
   is
     (Succeeded  => True, Usage => Used, Transcript => Transcript,
      Result     => Item);

   function Failed
     (Item       : Failures.Failure;
      Used       : Usage_Report := (others => <>);
      Transcript : Synapse.Core.Optional_Text.Option :=
        Synapse.Core.Optional_Text.None) return Session_Result
   is
     (Succeeded  => False, Usage => Used, Transcript => Transcript,
      Failure    => Item);

end Synapse.Pipeline.Sessions;
