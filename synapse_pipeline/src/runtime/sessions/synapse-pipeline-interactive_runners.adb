with Ada.Calendar;
with Ada.Streams;
with Ada.Strings.Fixed;

with Synapse.Core.Optional_Text;
with Synapse.Pipeline.Entropy;
with Synapse.Pipeline.Envelopes;
with Synapse.Pipeline.Failures;
with Synapse.Pipeline.Harness_Commands;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Interactive_Harnesses;
with Synapse.Pipeline.Resolved;
with Synapse.Pipeline.Session_Support;

package body Synapse.Pipeline.Interactive_Runners is

   use Ada.Strings.Unbounded;
   use type Ada.Streams.Stream_Element;

   package Commands renames Harness_Commands;
   package Interactive renames Interactive_Harnesses;
   package Support renames Session_Support;

   --  How much of the end of a transcript file is read each time. A turn is
   --  at the end, and a long session writes far more than this.
   Tail_Bytes : constant := 1024 * 1024;

   --  How long the command that prints a transcript may take.
   Export_Seconds : constant := 30;

   Hex : constant String := "0123456789abcdef";

   --  A random UUID, version 4.
   function New_Id return String is
      Bytes  : Ada.Streams.Stream_Element_Array (1 .. 16);
      Ok     : Boolean;
      Result : String (1 .. 36);
      Next   : Positive := 1;
   begin
      Entropy.Fill (Bytes, Ok);
      if not Ok then
         Bytes := [others => 0];
      end if;
      Bytes (7) := (Bytes (7) and 16#0F#) or 16#40#;
      Bytes (9) := (Bytes (9) and 16#3F#) or 16#80#;
      for I in Bytes'Range loop
         if I in 5 | 7 | 9 | 11 then
            Result (Next) := '-';
            Next := Next + 1;
         end if;
         Result (Next) := Hex (Natural (Bytes (I)) / 16 + 1);
         Result (Next + 1) := Hex (Natural (Bytes (I)) mod 16 + 1);
         Next := Next + 2;
      end loop;
      return Result;
   end New_Id;

   function Two (Item : Natural) return String is
      Text : constant String :=
        Ada.Strings.Fixed.Trim (Natural'Image (Item), Ada.Strings.Left);
   begin
      return (if Text'Length = 1 then "0" & Text else Text);
   end Two;

   --  The local date as Codex names the folder of a day.
   function Today return String is
      Year  : Ada.Calendar.Year_Number;
      Month : Ada.Calendar.Month_Number;
      Day   : Ada.Calendar.Day_Number;
      Left  : Ada.Calendar.Day_Duration;
   begin
      Ada.Calendar.Split (Ada.Calendar.Clock, Year, Month, Day, Left);
      return Ada.Strings.Fixed.Trim (Natural'Image (Year), Ada.Strings.Left)
        & "/" & Two (Month) & "/" & Two (Day);
   end Today;

   --  The start of Text, short enough to say to a person.
   function Brief (Text : String) return String is
      Shown : constant String :=
        Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both);
   begin
      if Shown'Length > 400 then
         return Shown (Shown'First .. Shown'First + 399) & "...";
      end if;
      return Shown;
   end Brief;

   --  The transcript of the session as far as it is written, empty when
   --  there is none yet.
   function Transcript_Of
     (R       : Interactive_Runner;
      Adapter : Interactive.Interactive'Class;
      Session : Interactive.Session_Handle) return String
   is
      use type Interactive.Source_Kind;
      Source : constant Interactive.Transcript_Source :=
        Adapter.Locate (Session, R.Files.all);
   begin
      case Source.Kind is
         when Interactive.Not_Yet =>
            return "";
         when Interactive.From_File =>
            declare
               Read : constant File_System.Maybe_Content :=
                 R.Files.Read_End (To_String (Source.Path), Tail_Bytes);
            begin
               return (if Read.Found then To_String (Read.Value) else "");
            end;
         when Interactive.From_Command =>
            declare
               Asked : Session_Process.Process_Request;
               Ended : Session_Process.Process_Outcome;
            begin
               Asked.Program := Source.Run.Program;
               Asked.Arguments := Source.Run.Arguments;
               Asked.Environment := Source.Run.Environment;
               Asked.Timeout_Seconds := Export_Seconds;
               Ended := R.Process.Run (Asked);
               return (if Ended.Started and then Ended.Exit_Code = 0
                       then To_String (Ended.Output) else "");
            end;
      end case;
   end Transcript_Of;

   function Home_Of
     (V : Synapse.Ports.Variables.Variables'Class)
      return Ada.Strings.Unbounded.Unbounded_String
   is
      Home    : constant Synapse.Ports.Variables.Maybe_Value := V.Get ("HOME");
      Profile : constant Synapse.Ports.Variables.Maybe_Value :=
        V.Get ("USERPROFILE");
   begin
      if Home.Found and then Length (Home.Value) > 0 then
         return Home.Value;
      elsif Profile.Found then
         return Profile.Value;
      end if;
      return Null_Unbounded_String;
   end Home_Of;

   overriding
   function Run_Session
     (R       : in out Interactive_Runner;
      Request : Sessions.Session_Request) return Sessions.Session_Result
   is
      Step    : Resolved.Step renames Request.Step;
      Adapter : constant access constant Interactive.Interactive'Class :=
        Interactive.For_Harness (Step.Harness);
      Prompt  : Unbounded_String;
      Skills  : Unbounded_String;
      Problem : Unbounded_String;
   begin
      if Adapter = null then
         return Support.Failed_Session
           (Request, Failures.Execution_Error,
            Harnesses.Name_Of (Step.Harness)
            & " cannot run a step interactively");
      end if;
      Support.Prepare
        (R.Files.all, R.Skill_Roots, Request, True, Prompt, Skills, Problem);
      if Length (Problem) > 0 then
         return Support.Failed_Session
           (Request, Failures.Execution_Error, To_String (Problem));
      end if;

      declare
         Session : constant Interactive.Session_Handle :=
           (Id        => (if Length (R.Session_Id) > 0 then R.Session_Id
                          else To_Unbounded_String (New_Id)),
            Directory => Request.Settings.Working_Directory,
            Home      => R.Home,
            Day       => To_Unbounded_String (Today));
         Made    : constant Commands.Command_Results.Result :=
           Adapter.Build
             (Step, To_String (Prompt), To_String (Skills), Session);
      begin
         if not Commands.Command_Results.Is_Success (Made) then
            return Support.Failed_Session
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
            Asked.Directory := Request.Settings.Working_Directory;
            Support.Add_Settings (Asked.Environment, Request.Settings);

            declare
               Launched : constant Terminal_Process.Launch :=
                 R.Terminal.Start (Asked);
            begin
               if not Launched.Started then
                  return Support.Failed_Session
                    (Request, Failures.Execution_Error,
                     "cannot run " & Harnesses.Name_Of (Step.Harness) & ": "
                     & To_String (Launched.Problem));
               end if;
               declare
                  Id      : constant Terminal_Process.Handle := Launched.Id;
                  Heard   : Unbounded_String;
                  Waiting : Boolean := False;
                  Said    : Unbounded_String;

                  function Elapsed return Duration is
                    (Ada.Calendar."-" (Ada.Calendar.Clock, Began));

                  function Usage return Sessions.Usage_Report is
                    (Elapsed_Seconds => Natural (Duration'Max (Elapsed, 0.0)),
                     others          => <>);

                  function Kept return Synapse.Core.Optional_Text.Option is
                    (Support.Keep_Transcript
                       (R.Registry.all, Request, To_String (Heard)));

                  --  The session is over, however it ended.
                  procedure Settle is
                  begin
                     if Waiting and then R.Observer /= null then
                        Waiting := False;
                        R.Observer.Resumed (To_String (Step.Name));
                     end if;
                  end Settle;

                  procedure Hand_Back (Text : String) is
                  begin
                     if R.Observer /= null then
                        R.Observer.Waiting
                          (To_String (Step.Name), Brief (Text));
                     end if;
                  end Hand_Back;
               begin
                  loop
                     declare
                        Progress : constant Terminal_Process.Progress :=
                          R.Terminal.Look (Id);
                        Text     : constant String :=
                          Transcript_Of (R, Adapter.all, Session);
                        Turn     : constant Interactive.Turn_State :=
                          Adapter.Read_Turns (Text);
                     begin
                        Heard := To_Unbounded_String (Text);
                        if Turn.Finished then
                           declare
                              Checked : constant Envelopes.Envelope_Results
                                .Result :=
                                Envelopes.Parse
                                  (Support.Unfenced (To_String (Turn.Final)));
                           begin
                              if Envelopes.Envelope_Results.Is_Success
                                   (Checked)
                              then
                                 if Progress.Running then
                                    R.Terminal.Stop (Id);
                                 end if;
                                 Settle;
                                 return Sessions.Success
                                   (Envelopes.Envelope_Results.Value (Checked),
                                    Usage, Kept);
                              elsif not Waiting or else Turn.Final /= Said then
                                 Waiting := True;
                                 Said := Turn.Final;
                                 Hand_Back (To_String (Turn.Final));
                              end if;
                           end;
                        elsif Waiting then
                           Waiting := False;
                           Said := Null_Unbounded_String;
                           if R.Observer /= null then
                              R.Observer.Resumed (To_String (Step.Name));
                           end if;
                        end if;

                        if not Progress.Running then
                           Settle;
                           return Support.With_Transcript
                             (Support.Failed_Session
                                (Request, Failures.Execution_Error,
                                 Harnesses.Name_Of (Step.Harness)
                                 & " ended without a result"),
                              Kept);
                        elsif Elapsed > Duration (Request.Timeout_Seconds) then
                           R.Terminal.Stop (Id);
                           Settle;
                           return Support.With_Transcript
                             (Support.Failed_Session
                                (Request, Failures.Execution_Error,
                                 "timed out after"
                                 & Positive'Image (Request.Timeout_Seconds)
                                 & " seconds"),
                              Kept);
                        end if;
                     end;
                     delay R.Poll;
                  end loop;
               end;
            end;
         end;
      end;
   end Run_Session;

end Synapse.Pipeline.Interactive_Runners;
