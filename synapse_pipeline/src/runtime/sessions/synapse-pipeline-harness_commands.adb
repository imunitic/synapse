with Ada.Characters.Handling;
with Ada.Strings.Fixed;

with Synapse.Core.JSON;
with Synapse.Core.Optional_Text;
with Synapse.Pipeline.Envelopes;
with Synapse.Pipeline.Json_Lines;
with Synapse.Pipeline.Permission_Levels;

package body Synapse.Pipeline.Harness_Commands is

   use Ada.Strings.Unbounded;
   use type Failures.Failure_Kind;
   use type Harnesses.Harness_Kind;
   use type Permission_Levels.Level;
   use type Synapse.Core.JSON.Kind;

   package JSON renames Synapse.Core.JSON;

   LF : constant Character := Character'Val (10);

   ---------------------------------------------------------------------------
   --  Small helpers
   ---------------------------------------------------------------------------

   function Lower (Text : String) return String
   renames Ada.Characters.Handling.To_Lower;

   function Contains (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   --  Text without the white space round it.
   function Stripped (Text : String) return String is
      First : Positive := Text'First;
      Last  : Natural := Text'Last;

      function Blank (C : Character) return Boolean is
        (C in ' ' | LF | Character'Val (13) | Character'Val (9));
   begin
      while First <= Last and then Blank (Text (First)) loop
         First := First + 1;
      end loop;
      while Last >= First and then Blank (Text (Last)) loop
         Last := Last - 1;
      end loop;
      return Text (First .. Last);
   end Stripped;

   function Is_Quota_Message (Text : String) return Boolean is
      Seen : constant String := Lower (Text);
   begin
      return Contains (Seen, "usage limit")
        or else Contains (Seen, "hit your limit")
        or else Contains (Seen, "rate limit")
        or else Contains (Seen, "rate_limit")
        or else Contains (Seen, "limit reached")
        or else Contains (Seen, "quota")
        or else Contains (Seen, "too many requests");
   end Is_Quota_Message;

   --  What a message says about when a quota resets: the words after
   --  `resets`, up to the end of the line.
   function Reset_Of
     (Text : String) return Synapse.Core.Optional_Text.Option
   is
      Key   : constant String := "resets ";
      Seen  : constant String := Lower (Text);
      Where : constant Natural := Ada.Strings.Fixed.Index (Seen, Key);
   begin
      if Where = 0 then
         return Synapse.Core.Optional_Text.None;
      end if;
      declare
         First : constant Positive := Where + Key'Length;
         Last  : Natural := Text'Last;
      begin
         for I in First .. Text'Last loop
            if Text (I) in LF | '"' then
               Last := I - 1;
               exit;
            end if;
         end loop;
         declare
            Said : constant String := Stripped (Text (First .. Last));
         begin
            if Said = "" then
               return Synapse.Core.Optional_Text.None;
            end if;
            return Synapse.Core.Optional_Text.Of_Value
              (To_Unbounded_String (Said));
         end;
      end;
   end Reset_Of;

   --  The start of Text, short enough to put in a message.
   function Brief (Text : String) return String is
      Shown : constant String := Stripped (Text);
   begin
      if Shown'Length > 400 then
         return Shown (Shown'First .. Shown'First + 399) & "...";
      end if;
      return Shown;
   end Brief;

   function Failed_With
     (Message : String; Quota_Status : Boolean := False) return Reply
   is
      Result : Reply (False);
   begin
      if Quota_Status or else Is_Quota_Message (Message) then
         Result.Failure.Kind := Failures.Quota_Exhausted;
         Result.Failure.Reset := Reset_Of (Message);
      else
         Result.Failure.Kind := Failures.Execution_Error;
      end if;
      Result.Failure.Message := To_Unbounded_String (Brief (Message));
      return Result;
   end Failed_With;

   --  A process that ended without a usable answer, said by how it ended.
   function Ended_Badly
     (Name : String; Ended : Session_Process.Process_Outcome) return Reply
   is
      Errors : constant String := To_String (Ended.Errors);
   begin
      if Ended.Exit_Code /= 0 then
         return Failed_With
           (Name & " exited with code" & Integer'Image (Ended.Exit_Code)
            & (if Brief (Errors) = "" then "" else ": " & Brief (Errors))
            & (if Is_Quota_Message (Errors) then " " & Errors else ""));
      end if;
      return Failed_With
        (Name & " finished without an answer"
         & (if Brief (Errors) = "" then "" else ": " & Brief (Errors)));
   end Ended_Badly;

   function Text_Member (Item : JSON.Value; Key : String) return String
   renames Json_Lines.Text_Member;

   function Object_Member (Item : JSON.Value; Key : String) return JSON.Value
   renames Json_Lines.Object_Member;

   function Count_Member (Item : JSON.Value; Key : String) return Natural is
   begin
      if JSON.Kind_Of (Item) = JSON.JSON_Object
        and then JSON.Has_Member (Item, Key)
        and then JSON.Kind_Of (JSON.Member_Value (Item, Key)) =
                 JSON.JSON_Integer
      then
         declare
            Given : constant Long_Long_Integer :=
              JSON.As_Integer (JSON.Member_Value (Item, Key));
         begin
            if Given < 0 then
               return 0;
            elsif Given > Long_Long_Integer (Natural'Last) then
               return Natural'Last;
            end if;
            return Natural (Given);
         end;
      end if;
      return 0;
   end Count_Member;

   function Sum (A, B : Natural) return Natural is
     (if A > Natural'Last - B then Natural'Last else A + B);

   procedure For_Each_Line
     (Text : String; Each : not null access procedure (Item : JSON.Value))
   renames Json_Lines.For_Each_Line;

   --  The message in an error a harness reported. It is often itself a JSON
   --  document with the message inside it.
   function Message_In (Text : String) return String is
      Parsed : constant JSON.Parse_Result :=
        (if Text'Length > 0 and then Text (Text'First) = '{'
         then JSON.Parse (Text)
         else (Ok => False, Error => JSON.Unexpected_End, Offset => 0));
   begin
      if Parsed.Ok then
         declare
            Inner : constant String :=
              Text_Member (Object_Member (Parsed.Item, "error"), "message");
         begin
            if Inner /= "" then
               return Inner;
            end if;
         end;
      end if;
      return Text;
   end Message_In;

   ---------------------------------------------------------------------------
   --  Commands
   ---------------------------------------------------------------------------

   procedure Add (Into : in out Synapse.Core.Text_Lists.Vector; Item : String)
   is
   begin
      Into.Append (To_Unbounded_String (Item));
   end Add;

   function Level_Of
     (Item : Resolved.Step) return Permission_Levels.Level is
   begin
      if Item.Permissions.Found then
         declare
            Named : constant Permission_Levels.Level_Options.Option :=
              Permission_Levels.Find (To_String (Item.Permissions.Value));
         begin
            if Named.Found then
               return Named.Value;
            end if;
         end;
      end if;
      return Permission_Levels.Default;
   end Level_Of;

   procedure Add_Claude_Permissions
     (Into : in out Synapse.Core.Text_Lists.Vector; Step : Resolved.Step) is
   begin
      Add (Into, "--permission-mode");
      case Level_Of (Step) is
         when Permission_Levels.Read_Only =>
            Add (Into, "dontAsk");
            Add (Into, "--tools");
            Add (Into, "Read,Grep,Glob");
         when Permission_Levels.Workspace_Write =>
            Add (Into, "auto");
         when Permission_Levels.Full_Access =>
            Add (Into, "bypassPermissions");
      end case;
   end Add_Claude_Permissions;

   function Opencode_Model (Step : Resolved.Step) return String is
     (To_String (Step.Model.Value)
      & (if Step.Effort.Found then "#" & To_String (Step.Effort.Value)
         else ""));

   procedure Add_Model_And_Effort
     (Into : in out Synapse.Core.Text_Lists.Vector; Step : Resolved.Step) is
   begin
      case Step.Harness is
         when Harnesses.Claude =>
            if Step.Model.Found then
               Add (Into, "--model");
               Add (Into, To_String (Step.Model.Value));
            end if;
            if Step.Effort.Found then
               Add (Into, "--effort");
               Add (Into, To_String (Step.Effort.Value));
            end if;
         when Harnesses.Codex =>
            if Step.Model.Found then
               Add (Into, "-m");
               Add (Into, To_String (Step.Model.Value));
            end if;
            if Step.Effort.Found then
               Add (Into, "-c");
               Add
                 (Into,
                  "model_reasoning_effort=""" & To_String (Step.Effort.Value)
                  & """");
            end if;
         when Harnesses.Opencode =>
            if Step.Model.Found then
               Add (Into, "-m");
               Add (Into, Opencode_Model (Step));
            end if;
      end case;
   end Add_Model_And_Effort;

   function Claude_Command
     (Item : Resolved.Step; Prompt : String) return Command_Results.Result
   is
      Made : Command;
   begin
      Made.Program := To_Unbounded_String ("claude");
      Add (Made.Arguments, "-p");
      Add (Made.Arguments, "--output-format");
      Add (Made.Arguments, "stream-json");
      Add (Made.Arguments, "--verbose");
      Add (Made.Arguments, "--json-schema");
      Add (Made.Arguments, JSON.To_String (Envelopes.Schema));
      Add (Made.Arguments, "--no-session-persistence");
      Add_Claude_Permissions (Made.Arguments, Item);
      Add_Model_And_Effort (Made.Arguments, Item);
      Made.Standard_Input := To_Unbounded_String (Prompt);
      return Command_Results.Success (Made);
   end Claude_Command;

   function Codex_Sandbox (Step : Resolved.Step) return String is
     (case Level_Of (Step) is
        when Permission_Levels.Read_Only       => "read-only",
        when Permission_Levels.Workspace_Write => "workspace-write",
        when Permission_Levels.Full_Access     => "danger-full-access");

   function Codex_Command
     (Item : Resolved.Step; Prompt : String) return Command_Results.Result
   is
      Made : Command;
   begin
      Made.Program := To_Unbounded_String ("codex");
      Add (Made.Arguments, "exec");
      Add (Made.Arguments, "--json");
      Add (Made.Arguments, "--ephemeral");
      Add (Made.Arguments, "--skip-git-repo-check");
      Add (Made.Arguments, "-s");
      Add (Made.Arguments, Codex_Sandbox (Item));
      Add_Model_And_Effort (Made.Arguments, Item);
      Made.Standard_Input := To_Unbounded_String (Prompt);
      return Command_Results.Success (Made);
   end Codex_Command;

   --  What makes a level hold in OpenCode: file tools stay inside the working
   --  directory, and a read-only session may not edit, run commands or fetch.
   --  Null when the level has no restriction.
   function Opencode_Permission
     (Level : Permission_Levels.Level) return JSON.Value
   is
      function Deny (Key : String) return JSON.Member is
        (Key => To_Unbounded_String (Key), Item => JSON.Make_String ("deny"));
   begin
      case Level is
         when Permission_Levels.Read_Only =>
            return JSON.Make_Object
              ([Deny ("edit"), Deny ("bash"), Deny ("webfetch"),
                Deny ("external_directory")]);
         when Permission_Levels.Workspace_Write =>
            return JSON.Make_Object ([1 => Deny ("external_directory")]);
         when Permission_Levels.Full_Access =>
            return JSON.Null_Value;
      end case;
   end Opencode_Permission;

   function Opencode_Config
     (Step : Resolved.Step; With_Model : Boolean) return String
   is
      Permission : constant JSON.Value :=
        Opencode_Permission (Level_Of (Step));
      Members    : JSON.Member_Array (1 .. 2);
      Count      : Natural := 0;
   begin
      if JSON.Kind_Of (Permission) = JSON.JSON_Object then
         Count := Count + 1;
         Members (Count) :=
           (Key => To_Unbounded_String ("permission"), Item => Permission);
      end if;
      if With_Model and then Step.Model.Found then
         Count := Count + 1;
         Members (Count) :=
           (Key  => To_Unbounded_String ("model"),
            Item => JSON.Make_String (To_String (Step.Model.Value)));
      end if;
      return (if Count = 0 then ""
              else JSON.To_String (JSON.Make_Object (Members (1 .. Count))));
   end Opencode_Config;

   function Opencode_Command
     (Item : Resolved.Step; Prompt : String) return Command_Results.Result
   is
      Made     : Command;
      Settings : constant String :=
        Opencode_Config (Item, With_Model => False);
   begin
      Made.Program := To_Unbounded_String ("opencode");
      Add (Made.Arguments, "run");
      Add (Made.Arguments, "--standalone");
      Add (Made.Arguments, "--format");
      Add (Made.Arguments, "json");
      Add (Made.Arguments, "--auto");
      Add_Model_And_Effort (Made.Arguments, Item);
      Add (Made.Arguments, Prompt);
      if Settings /= "" then
         Add (Made.Environment, "OPENCODE_CONFIG_CONTENT=" & Settings);
      end if;
      return Command_Results.Success (Made);
   end Opencode_Command;

   ---------------------------------------------------------------------------
   --  Replies
   ---------------------------------------------------------------------------

   --  Claude writes its session as one event per line and ends with a
   --  `result` event, which holds what the session came to.
   function Claude_Reply (Ended : Session_Process.Process_Outcome) return Reply
   is
      Final : Unbounded_String;

      procedure Read (Event : JSON.Value) is
      begin
         if Text_Member (Event, "type") = "result" then
            Final := To_Unbounded_String (JSON.To_String (Event));
         end if;
      end Read;
   begin
      For_Each_Line (To_String (Ended.Output), Read'Access);
      if Length (Final) = 0 then
         return Ended_Badly ("claude", Ended);
      end if;
      declare
         Document : constant JSON.Value := JSON.Parse (To_String (Final)).Item;
         Used     : constant JSON.Value := Object_Member (Document, "usage");
         Result   : Reply (True);
      begin
         Result.Usage.Reported := JSON.Kind_Of (Used) = JSON.JSON_Object;
         Result.Usage.Input_Tokens :=
           Sum
             (Count_Member (Used, "input_tokens"),
              Sum
                (Count_Member (Used, "cache_creation_input_tokens"),
                 Count_Member (Used, "cache_read_input_tokens")));
         Result.Usage.Output_Tokens := Count_Member (Used, "output_tokens");

         if JSON.Has_Member (Document, "is_error")
           and then JSON.Kind_Of (JSON.Member_Value (Document, "is_error")) =
                    JSON.JSON_Boolean
           and then JSON.As_Boolean (JSON.Member_Value (Document, "is_error"))
         then
            declare
               Said    : constant String := Text_Member (Document, "result");
               Because : constant String :=
                 (if Said /= "" then Said
                  else "claude reported " & Text_Member (Document, "subtype"));
               Failed  : Reply :=
                 Failed_With
                   (Because,
                    Quota_Status =>
                      Count_Member (Document, "api_error_status") = 429);
            begin
               Failed.Usage := Result.Usage;
               return Failed;
            end;
         elsif Ended.Exit_Code /= 0 then
            return Ended_Badly ("claude", Ended);
         end if;

         declare
            Structured : constant JSON.Value :=
              Object_Member (Document, "structured_output");
            Said       : constant String := Text_Member (Document, "result");
         begin
            if JSON.Kind_Of (Structured) = JSON.JSON_Object then
               return (Succeeded => True, Usage => Result.Usage,
                       Answer => To_Unbounded_String
                                   (JSON.To_String (Structured)));
            elsif Said /= "" then
               return (Succeeded => True, Usage => Result.Usage,
                       Answer => To_Unbounded_String (Said));
            end if;
         end;
         return Ended_Badly ("claude", Ended);
      end;
   end Claude_Reply;

   function Codex_Reply (Ended : Session_Process.Process_Outcome) return Reply
   is
      Answer    : Unbounded_String;
      Problem   : Unbounded_String;
      Completed : Boolean := False;
      Used      : Sessions.Usage_Report;

      procedure Read (Event : JSON.Value) is
         Kind : constant String := Text_Member (Event, "type");
      begin
         if Kind = "item.completed" then
            declare
               Done : constant JSON.Value := Object_Member (Event, "item");
            begin
               if Text_Member (Done, "type") = "agent_message" then
                  Answer := To_Unbounded_String (Text_Member (Done, "text"));
               end if;
            end;
         elsif Kind = "turn.completed" then
            Completed := True;
            declare
               Counts : constant JSON.Value := Object_Member (Event, "usage");
            begin
               Used.Reported := True;
               Used.Input_Tokens := Count_Member (Counts, "input_tokens");
               Used.Output_Tokens := Count_Member (Counts, "output_tokens");
            end;
         elsif Kind = "turn.failed" then
            Problem := To_Unbounded_String
              (Message_In
                 (Text_Member (Object_Member (Event, "error"), "message")));
         elsif Kind = "error" and then Length (Problem) = 0 then
            Problem := To_Unbounded_String
              (Message_In (Text_Member (Event, "message")));
         end if;
      end Read;
   begin
      For_Each_Line (To_String (Ended.Output), Read'Access);
      if Length (Problem) > 0 then
         declare
            Failed : Reply := Failed_With (To_String (Problem));
         begin
            Failed.Usage := Used;
            return Failed;
         end;
      elsif Ended.Exit_Code /= 0 or else not Completed
        or else Length (Answer) = 0
      then
         return Ended_Badly ("codex", Ended);
      end if;
      return (Succeeded => True, Usage => Used, Answer => Answer);
   end Codex_Reply;

   function Opencode_Reply
     (Ended : Session_Process.Process_Outcome) return Reply
   is
      Answer  : Unbounded_String;
      Message : Unbounded_String;
      Problem : Unbounded_String;
      Used    : Sessions.Usage_Report;

      procedure Read (Event : JSON.Value) is
         Kind : constant String := Text_Member (Event, "type");
         Part : constant JSON.Value := Object_Member (Event, "part");
      begin
         if Kind = "text" then
            declare
               From : constant String := Text_Member (Part, "messageID");
            begin
               if From /= To_String (Message) then
                  Message := To_Unbounded_String (From);
                  Answer := Null_Unbounded_String;
               end if;
               Append (Answer, Text_Member (Part, "text"));
            end;
         elsif Kind = "step_finish" then
            declare
               Counts : constant JSON.Value := Object_Member (Part, "tokens");
               Cached : constant JSON.Value :=
                 Object_Member (Counts, "cache");
            begin
               Used.Reported := True;
               Used.Input_Tokens :=
                 Sum
                   (Used.Input_Tokens,
                    Sum
                      (Count_Member (Counts, "input"),
                       Sum
                         (Count_Member (Cached, "read"),
                          Count_Member (Cached, "write"))));
               Used.Output_Tokens :=
                 Sum (Used.Output_Tokens, Count_Member (Counts, "output"));
            end;
         elsif Kind = "error" and then Length (Problem) = 0 then
            declare
               Err  : constant JSON.Value := Object_Member (Event, "error");
               Data : constant JSON.Value := Object_Member (Err, "data");
               Said : constant String :=
                 (if Text_Member (Data, "message") /= ""
                  then Text_Member (Data, "message")
                  elsif Text_Member (Err, "message") /= ""
                  then Text_Member (Err, "message")
                  else Text_Member (Err, "name"));
            begin
               Problem := To_Unbounded_String
                 (if Said /= "" then Said else "opencode reported an error");
            end;
         end if;
      end Read;
   begin
      For_Each_Line (To_String (Ended.Output), Read'Access);
      if Length (Problem) > 0 then
         declare
            Failed : Reply := Failed_With (To_String (Problem));
         begin
            Failed.Usage := Used;
            return Failed;
         end;
      elsif Ended.Exit_Code /= 0 or else Length (Answer) = 0 then
         return Ended_Badly ("opencode", Ended);
      end if;
      return (Succeeded => True, Usage => Used, Answer => Answer);
   end Opencode_Reply;

   ---------------------------------------------------------------------------
   --  The harnesses
   ---------------------------------------------------------------------------

   type Claude is new Headless with null record;

   overriding function Build
     (Item   : Claude;
      Step   : Resolved.Step;
      Prompt : String) return Command_Results.Result is
     (Claude_Command (Step, Prompt));

   overriding function Interpret
     (Item  : Claude;
      Ended : Session_Process.Process_Outcome) return Reply is
     (Claude_Reply (Ended));

   type Codex is new Headless with null record;

   overriding function Build
     (Item   : Codex;
      Step   : Resolved.Step;
      Prompt : String) return Command_Results.Result is
     (Codex_Command (Step, Prompt));

   overriding function Interpret
     (Item  : Codex;
      Ended : Session_Process.Process_Outcome) return Reply is
     (Codex_Reply (Ended));

   type Opencode is new Headless with null record;

   overriding function Build
     (Item   : Opencode;
      Step   : Resolved.Step;
      Prompt : String) return Command_Results.Result is
     (Opencode_Command (Step, Prompt));

   overriding function Interpret
     (Item  : Opencode;
      Ended : Session_Process.Process_Outcome) return Reply is
     (Opencode_Reply (Ended));

   Claude_Harness   : aliased constant Claude := (null record);
   Codex_Harness    : aliased constant Codex := (null record);
   Opencode_Harness : aliased constant Opencode := (null record);

   function For_Harness
     (Kind : Harnesses.Harness_Kind) return not null access constant
     Headless'Class is
     (case Kind is
        when Harnesses.Claude   => Claude_Harness'Access,
        when Harnesses.Codex    => Codex_Harness'Access,
        when Harnesses.Opencode => Opencode_Harness'Access);

end Synapse.Pipeline.Harness_Commands;
