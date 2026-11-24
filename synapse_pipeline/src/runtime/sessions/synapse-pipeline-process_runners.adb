with Ada.Calendar;
with Ada.Strings.Unbounded;

with Synapse.Core.Optional_Text;
with Synapse.Pipeline.Envelopes;
with Synapse.Pipeline.Failures;
with Synapse.Pipeline.Harness_Commands;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Resolved;
with Synapse.Pipeline.Session_Support;

package body Synapse.Pipeline.Process_Runners is

   use Ada.Strings.Unbounded;

   package Commands renames Harness_Commands;

   package Support renames Session_Support;

   function Failed_Session
     (Request : Sessions.Session_Request;
      Kind    : Failures.Failure_Kind;
      Message : String;
      Used    : Sessions.Usage_Report := (others => <>))
      return Sessions.Session_Result renames Support.Failed_Session;

   function With_Transcript
     (Item       : Sessions.Session_Result;
      Transcript : Synapse.Core.Optional_Text.Option)
      return Sessions.Session_Result renames Support.With_Transcript;

   overriding
   function Run_Session
     (R       : in out Process_Runner;
      Request : Sessions.Session_Request) return Sessions.Session_Result
   is
      Step      : Resolved.Step renames Request.Step;
      Harness   : constant Harnesses.Harness_Kind := Step.Harness;
      Adapter   : constant not null access constant Commands.Headless'Class :=
        Commands.For_Harness (Harness);
      Prompt    : Unbounded_String;
      Skill_Dir : Unbounded_String;
      Problem   : Unbounded_String;
   begin
      Support.Prepare
        (R.Files.all, R.Skill_Roots, Request, False, Prompt, Skill_Dir,
         Problem);
      if Length (Problem) > 0 then
         return Failed_Session
           (Request, Failures.Execution_Error, To_String (Problem));
      end if;

      declare
         Made   : constant Commands.Command_Results.Result :=
           Adapter.Build (Step, To_String (Prompt), To_String (Skill_Dir));
      begin
         if not Commands.Command_Results.Is_Success (Made) then
            return Failed_Session
              (Request, Failures.Execution_Error,
               To_String (Commands.Command_Results.Error (Made)));
         end if;
         declare
            Command : constant Commands.Command :=
              Commands.Command_Results.Value (Made);
            Asked   : Session_Process.Process_Request;
            Began   : constant Ada.Calendar.Time := Ada.Calendar.Clock;
         begin
            Asked.Program := Command.Program;
            Asked.Arguments := Command.Arguments;
            Asked.Environment := Command.Environment;
            Asked.Standard_Input := Command.Standard_Input;
            Asked.Directory := Request.Settings.Working_Directory;
            Asked.Timeout_Seconds := Request.Timeout_Seconds;
            Support.Add_Settings (Asked.Environment, Request.Settings);
            Asked.Output_Path := To_Unbounded_String
              (Support.Begin_Transcript (R.Registry.all, Request));

            declare
               Ended : constant Session_Process.Process_Outcome :=
                 R.Process.Run (Asked);
               Taken : constant Duration :=
                 Ada.Calendar."-" (Ada.Calendar.Clock, Began);
               Saved : constant Synapse.Core.Optional_Text.Option :=
                 (if Ended.Started
                  then Support.Keep_Transcript
                         (R.Registry.all, Request, To_String (Ended.Output))
                  else Synapse.Core.Optional_Text.None);
            begin
               if not Ended.Started then
                  return Failed_Session
                    (Request, Failures.Execution_Error,
                     "cannot run " & Harnesses.Name_Of (Harness) & ": "
                     & To_String (Ended.Problem));
               elsif Ended.Timed_Out then
                  return With_Transcript
                    (Failed_Session
                       (Request, Failures.Execution_Error,
                        "timed out after"
                        & Positive'Image (Request.Timeout_Seconds)
                        & " seconds"),
                     Saved);
               end if;
               declare
                  Said : Commands.Reply := Adapter.Interpret (Ended);
               begin
                  Said.Usage.Elapsed_Seconds :=
                    Natural (Duration'Max (Taken, 0.0));
                  if not Said.Succeeded then
                     Said.Failure.Step := Step.Name;
                     return Sessions.Failed (Said.Failure, Said.Usage, Saved);
                  end if;
                  declare
                     Checked : constant Envelopes.Envelope_Results.Result :=
                       Envelopes.Parse
                         (Support.Unfenced (To_String (Said.Answer)));
                  begin
                     if Envelopes.Envelope_Results.Is_Success (Checked) then
                        return Sessions.Success
                          (Envelopes.Envelope_Results.Value (Checked),
                           Said.Usage, Saved);
                     end if;
                     return With_Transcript
                       (Failed_Session
                          (Request, Failures.Result_Contract_Failure,
                           To_String
                             (Envelopes.Envelope_Results.Error (Checked)),
                           Said.Usage),
                        Saved);
                  end;
               end;
            end;
         end;
      end;
   end Run_Session;

end Synapse.Pipeline.Process_Runners;
