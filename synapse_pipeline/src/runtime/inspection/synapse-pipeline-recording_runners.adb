with Synapse.Core.JSON;

package body Synapse.Pipeline.Recording_Runners is

   use Ada.Strings.Unbounded;

   package JSON renames Synapse.Core.JSON;

   function Member (Key : String; Item : JSON.Value) return JSON.Member is
     (Key => To_Unbounded_String (Key), Item => Item);

   overriding
   function Run_Session
     (R       : in out Recording_Runner;
      Request : Sessions.Session_Request) return Sessions.Session_Result
   is
      Stamped : Sessions.Session_Request := Request;
   begin
      Stamped.Execution_Id := R.Id;
      declare
         Answer : constant Sessions.Session_Result :=
           R.Inner.Run_Session (Stamped);
      begin
         R.Recorder.Record_Event
           ("session.finished", To_String (Request.Step.Name),
            JSON.Make_Object
              ([Member
                  ("attempt",
                   JSON.Make_Integer (Long_Long_Integer (Request.Attempt))),
               Member ("succeeded", JSON.Make_Boolean (Answer.Succeeded)),
               Member
                 ("transcript",
                  (if Answer.Transcript.Found
                   then JSON.Make_String (To_String (Answer.Transcript.Value))
                   else JSON.Null_Value))]));
         return Answer;
      end;
   end Run_Session;

end Synapse.Pipeline.Recording_Runners;
