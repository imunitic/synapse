with Synapse.Pipeline.Interactive_Runners;
with Synapse.Pipeline.Recorders;

--  Tells a run's record when an interactive session starts and stops waiting
--  for a person, so that the run says so to whoever asks.

package Synapse.Pipeline.Recording_Observers is

   type Recording_Observer
     (Recorder : not null access Recorders.Recorder)
   is limited new Interactive_Runners.Attention_Observer with null record;

   overriding
   procedure Waiting
     (O : in out Recording_Observer; Step, Reason : String);

   overriding
   procedure Resumed (O : in out Recording_Observer; Step : String);

end Synapse.Pipeline.Recording_Observers;
