with Ada.Characters.Handling;
with Ada.Strings.Fixed;

with Synapse.Core.JSON;
with Synapse.Core.Optional_Text;
with Synapse.Pipeline.Envelopes;
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

   function Text_Member (Item : JSON.Value; Key : String) return String is
     (if JSON.Kind_Of (Item) = JSON.JSON_Object
        and then JSON.Has_Member (Item, Key)
        and then JSON.Kind_Of (JSON.Member_Value (Item, Key)) =
                 JSON.JSON_String
      then JSON.As_String (JSON.Member_Value (Item, Key)) else "");

   function Object_Member (Item : JSON.Value; Key : String) return JSON.Value
   is
     (if JSON.Kind_Of (Item) = JSON.JSON_Object
        and then JSON.Has_Member (Item, Key)
      then JSON.Member_Value (Item, Key) else JSON.Null_Value);

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

   --  Calls Each with every line of Text that is a JSON object.
   procedure For_Each_Line
     (Text : String; Each : not null access procedure (Item : JSON.Value))
   is
      Start : Positive := Text'First;

      procedure One (Line : String) is
      begin
         if Stripped (Line) = "" then
            return;
         end if;
         declare
            Parsed : constant JSON.Parse_Result := JSON.Parse (Line);
         begin
            if Parsed.Ok and then JSON.Kind_Of (Parsed.Item) = JSON.JSON_Object
            then
               Each (Parsed.Item);
            end if;
         end;
      end One;
   begin
      for I in Text'Range loop
         if Text (I) = LF then
            One (Text (Start .. I - 1));
            Start := I + 1;
         end if;
      end loop;
      if Start <= Text'Last then
         One (Text (Start .. Text'Last));
      end if;
   end For_Each_Line;

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

   function Has_Tools (Item : Resolved.Step) return Boolean is
     (Item.Tools.Found
      and then JSON.Kind_Of (Item.Tools.Value) = JSON.JSON_Array
      and then JSON.Length (Item.Tools.Value) > 0);

   function Cannot_Restrict_Tools (Name : String) return Command_Results.Result
   is
     (Command_Results.Failure
        (To_Unbounded_String
           (Name & " cannot restrict the tools of a session; take 'Tools' "
            & "out of the step or run it on Claude")));

   function Claude_Command
     (Item : Resolved.Step; Prompt : String; Skill_Directory : String)
      return Command_Results.Result
   is
      Made  : Command;
      Level : constant Permission_Levels.Level := Level_Of (Item);
   begin
      Made.Program := To_Unbounded_String ("claude");
      Add (Made.Arguments, "-p");
      Add (Made.Arguments, "--output-format");
      Add (Made.Arguments, "json");
      Add (Made.Arguments, "--json-schema");
      Add (Made.Arguments, JSON.To_String (Envelopes.Schema));
      Add (Made.Arguments, "--no-session-persistence");
      Add (Made.Arguments, "--permission-mode");
      case Level is
         when Permission_Levels.Read_Only =>
            Add (Made.Arguments, "dontAsk");
            Add (Made.Arguments, "--tools");
            Add (Made.Arguments, "Read,Grep,Glob");
         when Permission_Levels.Workspace_Write =>
            Add (Made.Arguments, "acceptEdits");
         when Permission_Levels.Full_Access =>
            Add (Made.Arguments, "bypassPermissions");
      end case;
      if Item.Model.Found then
         Add (Made.Arguments, "--model");
         Add (Made.Arguments, To_String (Item.Model.Value));
      end if;
      if Skill_Directory /= "" then
         Add (Made.Arguments, "--add-dir");
         Add (Made.Arguments, Skill_Directory);
      end if;
      if Has_Tools (Item) then
         Add (Made.Arguments, "--allowedTools");
         for I in 1 .. JSON.Length (Item.Tools.Value) loop
            Add
              (Made.Arguments,
               JSON.As_String (JSON.Element (Item.Tools.Value, I)));
         end loop;
      end if;
      Made.Standard_Input := To_Unbounded_String (Prompt);
      return Command_Results.Success (Made);
   end Claude_Command;

   function Codex_Command
     (Item : Resolved.Step; Prompt : String) return Command_Results.Result
   is
      Made  : Command;
      Level : constant Permission_Levels.Level := Level_Of (Item);
   begin
      if Has_Tools (Item) then
         return Cannot_Restrict_Tools ("Codex");
      end if;
      Made.Program := To_Unbounded_String ("codex");
      Add (Made.Arguments, "exec");
      Add (Made.Arguments, "--json");
      Add (Made.Arguments, "--ephemeral");
      Add (Made.Arguments, "--skip-git-repo-check");
      Add (Made.Arguments, "-s");
      Add
        (Made.Arguments,
         (case Level is
            when Permission_Levels.Read_Only       => "read-only",
            when Permission_Levels.Workspace_Write => "workspace-write",
            when Permission_Levels.Full_Access     => "danger-full-access"));
      if Item.Model.Found then
         Add (Made.Arguments, "-m");
         Add (Made.Arguments, To_String (Item.Model.Value));
      end if;
      Made.Standard_Input := To_Unbounded_String (Prompt);
      return Command_Results.Success (Made);
   end Codex_Command;

   --  The OpenCode settings that make a level hold: file tools stay inside
   --  the working directory, and a read-only session may not edit, run
   --  commands or fetch.
   function Opencode_Settings (Level : Permission_Levels.Level) return String
   is
      function Deny (Key : String) return JSON.Member is
        (Key => To_Unbounded_String (Key), Item => JSON.Make_String ("deny"));
   begin
      case Level is
         when Permission_Levels.Read_Only =>
            return JSON.To_String
              (JSON.Make_Object
                 ([1 =>
                     (Key  => To_Unbounded_String ("permission"),
                      Item => JSON.Make_Object
                        ([Deny ("edit"), Deny ("bash"), Deny ("webfetch"),
                          Deny ("external_directory")]))]));
         when Permission_Levels.Workspace_Write =>
            return JSON.To_String
              (JSON.Make_Object
                 ([1 =>
                     (Key  => To_Unbounded_String ("permission"),
                      Item => JSON.Make_Object
                        ([1 => Deny ("external_directory")]))]));
         when Permission_Levels.Full_Access =>
            return "";
      end case;
   end Opencode_Settings;

   function Opencode_Command
     (Item : Resolved.Step; Prompt : String) return Command_Results.Result
   is
      Made     : Command;
      Settings : constant String := Opencode_Settings (Level_Of (Item));
   begin
      if Has_Tools (Item) then
         return Cannot_Restrict_Tools ("OpenCode");
      end if;
      Made.Program := To_Unbounded_String ("opencode");
      Add (Made.Arguments, "run");
      Add (Made.Arguments, "--standalone");
      Add (Made.Arguments, "--format");
      Add (Made.Arguments, "json");
      Add (Made.Arguments, "--auto");
      if Item.Model.Found then
         Add (Made.Arguments, "-m");
         Add (Made.Arguments, To_String (Item.Model.Value));
      end if;
      Add (Made.Arguments, Prompt);
      if Settings /= "" then
         Add (Made.Environment, "OPENCODE_CONFIG_CONTENT=" & Settings);
      end if;
      return Command_Results.Success (Made);
   end Opencode_Command;

   function Build
     (Harness         : Harnesses.Harness_Kind;
      Item            : Resolved.Step;
      Prompt          : String;
      Skill_Directory : String) return Command_Results.Result is
     (case Harness is
        when Harnesses.Claude   =>
          Claude_Command (Item, Prompt, Skill_Directory),
        when Harnesses.Codex    => Codex_Command (Item, Prompt),
        when Harnesses.Opencode => Opencode_Command (Item, Prompt));

   ---------------------------------------------------------------------------
   --  Replies
   ---------------------------------------------------------------------------

   function Claude_Reply (Ended : Session_Process.Process_Outcome) return Reply
   is
      Parsed : constant JSON.Parse_Result :=
        JSON.Parse (To_String (Ended.Output));
   begin
      if not Parsed.Ok or else JSON.Kind_Of (Parsed.Item) /= JSON.JSON_Object
      then
         return Ended_Badly ("claude", Ended);
      end if;
      declare
         Document : constant JSON.Value := Parsed.Item;
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

   function Interpret
     (Harness : Harnesses.Harness_Kind;
      Ended   : Session_Process.Process_Outcome) return Reply is
     (case Harness is
        when Harnesses.Claude   => Claude_Reply (Ended),
        when Harnesses.Codex    => Codex_Reply (Ended),
        when Harnesses.Opencode => Opencode_Reply (Ended));

end Synapse.Pipeline.Harness_Commands;
