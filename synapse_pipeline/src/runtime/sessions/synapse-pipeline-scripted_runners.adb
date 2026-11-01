with Synapse.Core.JSON;
with Synapse.Core.Optional_Text;
with Synapse.Pipeline.Envelopes;
with Synapse.Pipeline.Failures;

package body Synapse.Pipeline.Scripted_Runners is

   use Ada.Strings.Unbounded;
   use type Synapse.Core.JSON.Kind;
   use type Failures.Failure_Kind;

   package JSON renames Synapse.Core.JSON;

   function Image (N : Natural) return String is
      Text : constant String := Natural'Image (N);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Image;

   function Parse (Text : String) return Script_Results.Result is
      Result  : Scripts.Script;
      Failed  : Boolean := False;
      Problem : Unbounded_String;

      procedure Fail (Where, What : String) is
      begin
         if not Failed then
            Failed := True;
            Problem := To_Unbounded_String (Where & ": " & What);
         end if;
      end Fail;

      --  What a failure entry says about the string member Key, or Default.
      function Text_Of
        (Entry_Object : JSON.Value; Key, Where, Default : String)
         return String is
      begin
         if not JSON.Has_Member (Entry_Object, Key) then
            return Default;
         elsif JSON.Kind_Of (JSON.Member_Value (Entry_Object, Key)) /=
               JSON.JSON_String
         then
            Fail (Where & "." & Key, "expected a string");
            return Default;
         end if;
         return JSON.As_String (JSON.Member_Value (Entry_Object, Key));
      end Text_Of;

      procedure Read_Failure
        (Step : String; Item : JSON.Value; Where : String; Pause : Duration)
      is
         Name : constant String := Text_Of (Item, "fail", Where, "");
         Cause : Failures.Failure;
      begin
         for I in 1 .. JSON.Length (Item) loop
            if JSON.Member_Key (Item, I) not in "fail" | "message" | "reset"
            then
               Fail
                 (Where,
                  "'" & JSON.Member_Key (Item, I) & "' is not allowed in a "
                  & "failure; an answer is a result or a failure, not both");
               return;
            end if;
         end loop;
         if Failed then
            return;
         elsif Name = "timeout" then
            Cause.Kind := Failures.Execution_Error;
            Cause.Message :=
              To_Unbounded_String
                (Text_Of
                   (Item, "message", Where,
                    "the session ran past its timeout"));
         else
            declare
               Kind : constant Failures.Kind_Options.Option :=
                 Failures.Find (Name);
            begin
               if not Kind.Found then
                  Fail
                    (Where & ".fail",
                     "'" & Name & "' is not a failure a script can give");
                  return;
               elsif Kind.Value = Failures.Ceiling_Reached then
                  Fail
                    (Where & ".fail",
                     "'ceiling_reached' cannot be scripted: only the engine "
                     & "counts steps");
                  return;
               end if;
               Cause.Kind := Kind.Value;
               Cause.Message :=
                 To_Unbounded_String
                   (Text_Of
                      (Item, "message", Where, "the script says so"));
            end;
         end if;
         if JSON.Has_Member (Item, "reset") then
            Cause.Reset :=
              Synapse.Core.Optional_Text.Of_Value
                (To_Unbounded_String (Text_Of (Item, "reset", Where, "")));
         end if;
         if not Failed then
            Scripts.Add (Result, Step, Sessions.Failed (Cause), Pause);
         end if;
      end Read_Failure;

      --  The members of Item but the one called Key.
      function Without (Item : JSON.Value; Key : String) return JSON.Value is
         Kept : JSON.Member_Array (1 .. JSON.Length (Item));
         Last : Natural := 0;
      begin
         for I in 1 .. JSON.Length (Item) loop
            if JSON.Member_Key (Item, I) /= Key then
               Last := Last + 1;
               Kept (Last) :=
                 (Key  => To_Unbounded_String (JSON.Member_Key (Item, I)),
                  Item => JSON.Member_At (Item, I));
            end if;
         end loop;
         return JSON.Make_Object (Kept (1 .. Last));
      end Without;

      --  How long an entry says its session takes: `delay_seconds`, a number
      --  from 0 to Longest_Pause, or nothing.
      function Pause_Of (Item : JSON.Value; Where : String) return Duration is
      begin
         if not JSON.Has_Member (Item, "delay_seconds") then
            return 0.0;
         end if;
         declare
            Given : constant JSON.Value :=
              JSON.Member_Value (Item, "delay_seconds");
            Seconds : Long_Float := -1.0;
         begin
            if JSON.Kind_Of (Given) = JSON.JSON_Integer then
               Seconds := Long_Float (JSON.As_Integer (Given));
            elsif JSON.Kind_Of (Given) = JSON.JSON_Float then
               Seconds := JSON.As_Float (Given);
            end if;
            if Seconds < 0.0 or else Seconds > Long_Float (Longest_Pause) then
               Fail
                 (Where & ".delay_seconds",
                  "expected a number from 0 to"
                  & Natural'Image (Longest_Pause));
               return 0.0;
            end if;
            return Duration (Seconds);
         end;
      end Pause_Of;

      procedure Read_Entry (Step : String; Item : JSON.Value; Where : String)
      is
      begin
         if JSON.Kind_Of (Item) /= JSON.JSON_Object then
            Fail (Where, "expected an object");
            return;
         end if;
         declare
            Pause : constant Duration := Pause_Of (Item, Where);
            Body_Of : constant JSON.Value := Without (Item, "delay_seconds");
         begin
            if Failed then
               return;
            elsif JSON.Has_Member (Body_Of, "fail") then
               Read_Failure (Step, Body_Of, Where, Pause);
            else
               declare
                  Checked : constant Envelopes.Envelope_Results.Result :=
                    Envelopes.From_JSON (Body_Of);
               begin
                  if Envelopes.Envelope_Results.Is_Success (Checked) then
                     Scripts.Add
                       (Result, Step,
                        Sessions.Success
                          (Envelopes.Envelope_Results.Value (Checked)),
                        Pause);
                  else
                     Fail
                       (Where,
                        To_String
                          (Envelopes.Envelope_Results.Error (Checked)));
                  end if;
               end;
            end if;
         end;
      end Read_Entry;

      Parsed : constant JSON.Parse_Result := JSON.Parse (Text);
   begin
      if not Parsed.Ok then
         return Script_Results.Failure
           (To_Unbounded_String
              ("script: not JSON: "
               & JSON.Parse_Error_Kind'Image (Parsed.Error) & " at byte"
               & Natural'Image (Parsed.Offset)));
      elsif JSON.Kind_Of (Parsed.Item) /= JSON.JSON_Object then
         return Script_Results.Failure
           (To_Unbounded_String ("script: expected an object"));
      end if;
      for I in 1 .. JSON.Length (Parsed.Item) loop
         declare
            Step    : constant String := JSON.Member_Key (Parsed.Item, I);
            Answers : constant JSON.Value := JSON.Member_At (Parsed.Item, I);
         begin
            if JSON.Kind_Of (Answers) /= JSON.JSON_Array then
               Fail ("script." & Step, "expected a list of answers");
            else
               for N in 1 .. JSON.Length (Answers) loop
                  Read_Entry
                    (Step, JSON.Element (Answers, N),
                     "script." & Step & "[" & Image (N) & "]");
                  exit when Failed;
               end loop;
            end if;
         end;
         exit when Failed;
      end loop;
      if Failed then
         return Script_Results.Failure (Problem);
      end if;
      return Script_Results.Success (Result);
   end Parse;

   function Load
     (Files : File_System.File_System'Class; Path : String)
      return Script_Results.Result
   is
      Content : constant File_System.Maybe_Content := Files.Read (Path);
   begin
      if not Content.Found then
         return Script_Results.Failure
           (To_Unbounded_String
              ("script " & Path & " cannot be read: it is missing, "
               & "unreadable or too large"));
      end if;
      return Parse (To_String (Content.Value));
   end Load;

   function Create (Item : Scripts.Script) return Scripted_Runner is
     (Session_Runner.Runner with Script => Item, Given => <>);

   function Remaining (R : Scripted_Runner; Step : String) return Natural is
     (Scripts.Count (R.Script, Step)
      - (if R.Given.Contains (Step) then R.Given.Element (Step) else 0));

   overriding
   function Run_Session
     (R : in out Scripted_Runner; Request : Sessions.Session_Request)
      return Sessions.Session_Result
   is
      Step  : constant String := To_String (Request.Step.Name);
      Total : constant Natural := Scripts.Count (R.Script, Step);
      Used  : constant Natural :=
        (if R.Given.Contains (Step) then R.Given.Element (Step) else 0);
   begin
      if Used >= Total then
         return Sessions.Failed
           ((Kind    => Failures.Execution_Error,
             Step    => Request.Step.Name,
             Message =>
               To_Unbounded_String
                 ("the script has no more answers for step '" & Step
                  & "'; it had" & Natural'Image (Total)),
             Reset   => <>));
      end if;
      R.Given.Include (Step, Used + 1);
      declare
         Given : Sessions.Session_Result :=
           Scripts.Answer (R.Script, Step, Used + 1);
         Pause : constant Duration := Scripts.Pause (R.Script, Step, Used + 1);
      begin
         if Pause > 0.0 then
            delay Pause;
         end if;
         if not Given.Succeeded then
            Given.Failure.Step := Request.Step.Name;
         end if;
         return Given;
      end;
   end Run_Session;

end Synapse.Pipeline.Scripted_Runners;
