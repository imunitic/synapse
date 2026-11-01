with Ada.Strings.Unbounded;

with Synapse.Pipeline.Envelopes;
with Synapse.Pipeline.Failures;
with Synapse.Pipeline.Guards;
with Synapse.Pipeline.Sessions;

package body Synapse.Pipeline.Engine is

   use Ada.Strings.Unbounded;
   use type Failures.Failure_Kind;

   --  The position of the step called Name, or 0.
   function Index_Of (Pipeline : Resolved.Pipeline; Name : String)
      return Natural is
   begin
      for I in Pipeline.Steps.First_Index .. Pipeline.Steps.Last_Index loop
         if To_String (Pipeline.Steps (I).Name) = Name then
            return I;
         end if;
      end loop;
      return 0;
   end Index_Of;

   --  The run, as it was, but failed for the reason given.
   function Failed_Run
     (Run : States.State; Cause : Failures.Failure) return States.State
   is
      Result : States.State := Run;
   begin
      Result.Status := States.Failed;
      Result.Failure := Cause;
      return Result;
   end Failed_Run;

   function Failed_Run
     (Run     : States.State; Kind : Failures.Failure_Kind; Step : String;
      Message : String) return States.State is
     (Failed_Run
        (Run,
         (Kind => Kind, Step => To_Unbounded_String (Step),
          Message => To_Unbounded_String (Message), Reset => <>)));

   function Unknown_Step (Run : States.State) return States.State is
      Name : constant String := To_String (Run.Current_Step);
   begin
      return Failed_Run
        (Run, Failures.Execution_Error, Name,
         "the run is at step '" & Name & "', which the pipeline does not "
         & "have");
   end Unknown_Step;

   function Over_Ceiling
     (Run : States.State; Settings : Configs.Config) return Boolean is
     (Run.Steps_Run >= Settings.Step_Ceiling);

   function Ceiling_Reached (Run : States.State) return States.State is
     (Failed_Run
        (Run, Failures.Ceiling_Reached, To_String (Run.Current_Step),
         "the run has taken" & Natural'Image (Run.Steps_Run)
         & " steps, the most it may"));

   function Hold_To_Ceiling
     (Run : States.State; Settings : Configs.Config) return States.State is
     (if Run.Status = States.Running and then Over_Ceiling (Run, Settings)
      then Ceiling_Reached (Run) else Run);

   function Advance
     (Pipeline : Resolved.Pipeline;
      Run      : States.State;
      Output   : Synapse.Core.JSON.Value) return States.State
   is
      Name  : constant String := To_String (Run.Current_Step);
      Index : constant Natural := Index_Of (Pipeline, Name);
   begin
      if Index = 0 then
         return Unknown_Step (Run);
      end if;
      declare
         Route : constant Guards.Route_Results.Result :=
           Guards.Route_After (Pipeline.Edges, Run.Fired, Name, Output);
         Next  : States.State := Run;
      begin
         if not Guards.Route_Results.Is_Success (Route) then
            return Failed_Run
              (Run, Failures.Execution_Error, Name,
               To_String (Guards.Route_Results.Error (Route)));
         end if;

         Next.Previous_Output := Output;
         Next.Steps_Run := Run.Steps_Run + 1;
         if Guards.Route_Results.Value (Route).Fires then
            declare
               Taken : constant Positive :=
                 Guards.Route_Results.Value (Route).Edge;
            begin
               while Next.Fired.Last_Index < Taken loop
                  Next.Fired.Append (0);
               end loop;
               Next.Fired.Replace_Element (Taken, Next.Fired (Taken) + 1);
               Next.Current_Step := Pipeline.Edges (Taken).To;
            end;
         elsif Index < Pipeline.Steps.Last_Index then
            Next.Current_Step := Pipeline.Steps (Index + 1).Name;
         else
            Next.Status := States.Completed;
            Next.Current_Step := Null_Unbounded_String;
         end if;
         return Next;
      end;
   end Advance;

   function Execute_Step
     (Pipeline : Resolved.Pipeline;
      Run      : States.State;
      Settings : Configs.Config;
      Runner   : in out Session_Runner.Runner'Class) return States.State
   is
      Name  : constant String := To_String (Run.Current_Step);
      Index : constant Natural := Index_Of (Pipeline, Name);
   begin
      if Index = 0 then
         return Unknown_Step (Run);
      elsif Over_Ceiling (Run, Settings) then
         return Ceiling_Reached (Run);
      end if;

      declare
         Step   : constant Resolved.Step := Pipeline.Steps (Index);
         Answer : Sessions.Session_Result;
      begin
         for Attempt in 1 .. Step.Retries + 1 loop
            Answer :=
              Runner.Run_Session
                (Sessions.Request_For (Step, Run, Settings, Attempt));
            exit when Answer.Succeeded
              or else Answer.Failure.Kind = Failures.Quota_Exhausted;
         end loop;

         if not Answer.Succeeded then
            declare
               Cause : Failures.Failure := Answer.Failure;
            begin
               if Length (Cause.Step) = 0 then
                  Cause.Step := Step.Name;
               end if;
               return Failed_Run (Run, Cause);
            end;
         end if;

         return Advance (Pipeline, Run, Envelopes.To_JSON (Answer.Result));
      end;
   end Execute_Step;

end Synapse.Pipeline.Engine;
