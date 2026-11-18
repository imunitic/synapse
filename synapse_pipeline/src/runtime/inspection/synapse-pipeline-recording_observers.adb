with Synapse.Pipeline.Inspection;

package body Synapse.Pipeline.Recording_Observers is

   overriding
   procedure Waiting
     (O : in out Recording_Observer; Step, Reason : String) is
   begin
      O.Recorder.Attend (Step, Inspection.Waiting, Reason);
   end Waiting;

   overriding
   procedure Resumed (O : in out Recording_Observer; Step : String) is
   begin
      O.Recorder.Attend (Step, Inspection.Running);
   end Resumed;

end Synapse.Pipeline.Recording_Observers;
