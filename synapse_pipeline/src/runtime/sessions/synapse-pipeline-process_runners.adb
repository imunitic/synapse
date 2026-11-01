with Ada.Calendar;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Synapse.Core.Optional_Text;
with Synapse.Pipeline.Configs;
with Synapse.Pipeline.Envelopes;
with Synapse.Pipeline.Failures;
with Synapse.Pipeline.Harness_Commands;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Prompts;
with Synapse.Pipeline.Resolved;
with Synapse.Pipeline.Skills;

package body Synapse.Pipeline.Process_Runners is

   use Ada.Strings.Unbounded;
   use type Resolved.Instruction_Kind;

   package Commands renames Harness_Commands;

   LF : constant Character := Character'Val (10);

   function Failed_Session
     (Request : Sessions.Session_Request;
      Kind    : Failures.Failure_Kind;
      Message : String;
      Used    : Sessions.Usage_Report := (others => <>))
      return Sessions.Session_Result is
     (Sessions.Failed
        (Failures.Failure'
           (Kind    => Kind,
            Step    => Request.Step.Name,
            Message => To_Unbounded_String (Message),
            Reset   => Synapse.Core.Optional_Text.None),
         Used));

   --  What an instruction says, ready for a prompt, and the directory of the
   --  skill it names when it names one. Problem is not empty when a skill
   --  cannot be read.
   procedure Text_Of
     (R         : Process_Runner;
      Item      : Resolved.Instruction;
      Text      : out Unbounded_String;
      Directory : out Unbounded_String;
      Problem   : out Unbounded_String)
   is
   begin
      Text := Null_Unbounded_String;
      Directory := Null_Unbounded_String;
      Problem := Null_Unbounded_String;
      if not Item.Present then
         return;
      elsif Item.Kind = Resolved.Prompt_Text then
         Text := Item.Text;
         return;
      end if;
      declare
         Name  : constant String := To_String (Item.Text);
         Found : constant Synapse.Core.Optional_Text.Option :=
           Skills.Find (R.Files.all, R.Skill_Roots, Name);
      begin
         if not Found.Found then
            Problem := To_Unbounded_String
              ("skill '" & Name & "' was not found in "
               & Skills.Searched (R.Skill_Roots));
            return;
         end if;
         declare
            Where   : constant String := To_String (Found.Value);
            Content : constant File_System.Maybe_Content :=
              R.Files.Read (Where & "/SKILL.md");
         begin
            if not Content.Found then
               Problem := To_Unbounded_String
                 ("skill '" & Name & "' has no readable SKILL.md in "
                  & Where);
               return;
            end if;
            Directory := Found.Value;
            Text := To_Unbounded_String
              ("Follow this skill. Its files are in " & Where & "." & LF & LF)
              & Content.Value;
         end;
      end;
   end Text_Of;

   --  An answer without the code fence a model sometimes puts round it.
   function Unfenced (Text : String) return String is
      Whole : constant String :=
        Ada.Strings.Fixed.Trim (Text, Ada.Strings.Both);
   begin
      if Whole'Length < 6
        or else Whole (Whole'First .. Whole'First + 2) /= "```"
      then
         return Whole;
      end if;
      declare
         Line_End : Natural := 0;
      begin
         for I in Whole'Range loop
            if Whole (I) = LF then
               Line_End := I;
               exit;
            end if;
         end loop;
         if Line_End = 0 or else Whole (Whole'Last - 2 .. Whole'Last) /= "```"
         then
            return Whole;
         end if;
         return Ada.Strings.Fixed.Trim
           (Whole (Line_End + 1 .. Whole'Last - 3), Ada.Strings.Both);
      end;
   end Unfenced;

   overriding
   function Run_Session
     (R       : in out Process_Runner;
      Request : Sessions.Session_Request) return Sessions.Session_Result
   is
      Step      : Resolved.Step renames Request.Step;
      Harness   : constant Harnesses.Harness_Kind := Step.Harness;
      Role      : Unbounded_String;
      Task_Text : Unbounded_String;
      Role_Dir  : Unbounded_String;
      Task_Dir  : Unbounded_String;
      Problem   : Unbounded_String;
   begin
      Text_Of (R, Step.Role, Role, Role_Dir, Problem);
      if Length (Problem) > 0 then
         return Failed_Session
           (Request, Failures.Execution_Error, To_String (Problem));
      end if;
      Text_Of (R, Step.Assignment, Task_Text, Task_Dir, Problem);
      if Length (Problem) > 0 then
         return Failed_Session
           (Request, Failures.Execution_Error, To_String (Problem));
      end if;

      declare
         Prompt : constant String :=
           Prompts.Build
             (Role            => To_String (Role),
              Assignment      => To_String (Task_Text),
              Step            => To_String (Step.Name),
              Initial_Input   => Request.Initial_Input,
              Previous_Output => Request.Previous_Output);
         Made   : constant Commands.Command_Results.Result :=
           Commands.Build
             (Harness, Step, Prompt,
              (if Length (Task_Dir) > 0 then To_String (Task_Dir)
               else To_String (Role_Dir)));
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
            for Item in Request.Settings.Environment.Iterate loop
               Asked.Environment.Append
                 (To_Unbounded_String
                    (Configs.Environment_Maps.Key (Item) & "="
                     & Configs.Environment_Maps.Element (Item)));
            end loop;

            declare
               Ended : constant Session_Process.Process_Outcome :=
                 R.Process.Run (Asked);
               Taken : constant Duration :=
                 Ada.Calendar."-" (Ada.Calendar.Clock, Began);
            begin
               if not Ended.Started then
                  return Failed_Session
                    (Request, Failures.Execution_Error,
                     "cannot run " & Harnesses.Name_Of (Harness) & ": "
                     & To_String (Ended.Problem));
               elsif Ended.Timed_Out then
                  return Failed_Session
                    (Request, Failures.Execution_Error,
                     "timed out after"
                     & Positive'Image (Request.Timeout_Seconds)
                     & " seconds");
               end if;
               declare
                  Said : Commands.Reply := Commands.Interpret (Harness, Ended);
               begin
                  Said.Usage.Elapsed_Seconds :=
                    Natural (Duration'Max (Taken, 0.0));
                  if not Said.Succeeded then
                     Said.Failure.Step := Step.Name;
                     return Sessions.Failed (Said.Failure, Said.Usage);
                  end if;
                  declare
                     Checked : constant Envelopes.Envelope_Results.Result :=
                       Envelopes.Parse (Unfenced (To_String (Said.Answer)));
                  begin
                     if Envelopes.Envelope_Results.Is_Success (Checked) then
                        return Sessions.Success
                          (Envelopes.Envelope_Results.Value (Checked),
                           Said.Usage);
                     end if;
                     return Failed_Session
                       (Request, Failures.Result_Contract_Failure,
                        To_String (Envelopes.Envelope_Results.Error (Checked)),
                        Said.Usage);
                  end;
               end;
            end;
         end;
      end;
   end Run_Session;

end Synapse.Pipeline.Process_Runners;
