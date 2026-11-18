with Ada.Strings.Fixed;

with Synapse.Core.JSON;
with Synapse.Pipeline.Json_Lines;

package body Synapse.Pipeline.Interactive_Harnesses is

   use Ada.Strings.Unbounded;
   use type Synapse.Core.JSON.Kind;

   package JSON renames Synapse.Core.JSON;
   package File_System renames Synapse.Pipeline.File_System;
   package Commands renames Harness_Commands;

   LF : constant Character := Character'Val (10);

   ---------------------------------------------------------------------------
   --  Claude Code
   ---------------------------------------------------------------------------

   --  Claude names the folder that holds a project's sessions after the
   --  project's directory, with every character that is not a letter or a
   --  digit replaced by `-`.
   function Folder_Name (Directory : String) return String is
      Result : String := Directory;
   begin
      for C of Result loop
         if C not in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' then
            C := '-';
         end if;
      end loop;
      return Result;
   end Folder_Name;

   type Claude is new Interactive with null record;

   overriding function Build
     (Item            : Claude;
      Step            : Resolved.Step;
      Prompt          : String;
      Skill_Directory : String;
      Session         : Session_Handle)
      return Commands.Command_Results.Result;

   overriding function Locate
     (Item    : Claude;
      Session : Session_Handle;
      Files   : File_System.File_System'Class)
      return Transcript_Source;

   overriding function Read_Turns
     (Item       : Claude;
      Transcript : String) return Turn_State;

   overriding function Build
     (Item            : Claude;
      Step            : Resolved.Step;
      Prompt          : String;
      Skill_Directory : String;
      Session         : Session_Handle)
      return Commands.Command_Results.Result
   is
      Made : Commands.Command;

      procedure Add (Item : String) is
      begin
         Made.Arguments.Append (To_Unbounded_String (Item));
      end Add;
   begin
      Made.Program := To_Unbounded_String ("claude");
      Add ("--session-id");
      Add (To_String (Session.Id));
      Commands.Add_Claude_Permissions (Made.Arguments, Step);
      if Step.Model.Found then
         Add ("--model");
         Add (To_String (Step.Model.Value));
      end if;
      if Skill_Directory /= "" then
         Add ("--add-dir");
         Add (Skill_Directory);
      end if;
      --  `--add-dir` and `--tools` take any number of values, so the prompt
      --  is set apart from them.
      Add ("--");
      Add (Prompt);
      --  Claude does not keep a session that a Claude session started, and
      --  the transcript is where the result is read from.
      Made.Environment.Append
        (To_Unbounded_String ("CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1"));
      return Commands.Command_Results.Success (Made);
   end Build;

   overriding function Locate
     (Item    : Claude;
      Session : Session_Handle;
      Files   : File_System.File_System'Class)
      return Transcript_Source is
     (Kind => From_File,
      Path => To_Unbounded_String
                (To_String (Session.Home) & "/.claude/projects/"
                 & Folder_Name (To_String (Session.Directory)) & "/"
                 & To_String (Session.Id) & ".jsonl"));

   --  The transcript is one record per line. A message of the agent is
   --  written as one record for each of its blocks, all with the message's id
   --  and its `stop_reason`, and a prompt of the person or the result of a
   --  tool is a `user` record. The agent has finished a turn when its latest
   --  message stopped with `end_turn` and has said something, which is not
   --  true yet while only its thinking has been written.
   overriding function Read_Turns
     (Item       : Claude;
      Transcript : String) return Turn_State
   is
      Result  : Turn_State;
      Message : Unbounded_String;
      Spoke   : Boolean := False;

      procedure Add_Text (Blocks : JSON.Value) is
      begin
         if JSON.Kind_Of (Blocks) /= JSON.JSON_Array then
            return;
         end if;
         for I in 1 .. JSON.Length (Blocks) loop
            declare
               Block : constant JSON.Value := JSON.Element (Blocks, I);
            begin
               if Json_Lines.Text_Member (Block, "type") = "text" then
                  Append
                    (Result.Final, Json_Lines.Text_Member (Block, "text"));
                  Spoke := True;
               end if;
            end;
         end loop;
      end Add_Text;

      procedure Read (Event : JSON.Value) is
         Kind    : constant String := Json_Lines.Text_Member (Event, "type");
         Inner   : constant JSON.Value :=
           Json_Lines.Object_Member (Event, "message");
         Aside   : constant JSON.Value :=
           Json_Lines.Object_Member (Event, "isSidechain");
      begin
         if Kind not in "user" | "assistant"
           or else (JSON.Kind_Of (Aside) = JSON.JSON_Boolean
                    and then JSON.As_Boolean (Aside))
         then
            return;
         end if;
         if Kind = "user" then
            Result := (Finished => False, Final => Null_Unbounded_String);
            Message := Null_Unbounded_String;
            Spoke := False;
            return;
         end if;

         if Json_Lines.Text_Member (Inner, "id") /= To_String (Message) then
            Message :=
              To_Unbounded_String (Json_Lines.Text_Member (Inner, "id"));
            Result.Final := Null_Unbounded_String;
            Spoke := False;
         end if;
         Add_Text (Json_Lines.Object_Member (Inner, "content"));
         Result.Finished :=
           Spoke and then Json_Lines.Text_Member (Inner, "stop_reason") =
                          "end_turn";
      end Read;
   begin
      Json_Lines.For_Each_Line (Transcript, Read'Access);
      if not Result.Finished then
         Result.Final := Null_Unbounded_String;
      end if;
      return Result;
   end Read_Turns;

   ---------------------------------------------------------------------------
   --  Codex
   ---------------------------------------------------------------------------

   --  Codex takes no session id, so the session is found by this text, which
   --  the prompt ends with and so the first message of the person holds.
   function Marker_Of (Session : Session_Handle) return String is
     ("pipeline-session: " & To_String (Session.Id));

   type Codex is new Interactive with null record;

   overriding function Build
     (Item            : Codex;
      Step            : Resolved.Step;
      Prompt          : String;
      Skill_Directory : String;
      Session         : Session_Handle)
      return Commands.Command_Results.Result;

   overriding function Locate
     (Item    : Codex;
      Session : Session_Handle;
      Files   : File_System.File_System'Class)
      return Transcript_Source;

   overriding function Read_Turns
     (Item       : Codex;
      Transcript : String) return Turn_State;

   overriding function Build
     (Item            : Codex;
      Step            : Resolved.Step;
      Prompt          : String;
      Skill_Directory : String;
      Session         : Session_Handle)
      return Commands.Command_Results.Result
   is
      Made : Commands.Command;

      procedure Add (Item : String) is
      begin
         Made.Arguments.Append (To_Unbounded_String (Item));
      end Add;
   begin
      Made.Program := To_Unbounded_String ("codex");
      Add ("-s");
      Add (Commands.Codex_Sandbox (Step));
      if Step.Model.Found then
         Add ("-m");
         Add (To_String (Step.Model.Value));
      end if;
      --  A prompt that begins with a dash is read as an option unless it
      --  follows `--`.
      Add ("--");
      Add (Prompt & LF & LF & Marker_Of (Session));
      return Commands.Command_Results.Success (Made);
   end Build;

   --  Whether a line of a rollout is a message of the person that holds
   --  Marker.
   function Is_Prompt_With
     (Event : JSON.Value; Marker : String) return Boolean
   is
      Payload : constant JSON.Value :=
        Json_Lines.Object_Member (Event, "payload");
      Content : constant JSON.Value :=
        Json_Lines.Object_Member (Payload, "content");
   begin
      if Json_Lines.Text_Member (Event, "type") /= "response_item"
        or else Json_Lines.Text_Member (Payload, "type") /= "message"
        or else Json_Lines.Text_Member (Payload, "role") /= "user"
        or else JSON.Kind_Of (Content) /= JSON.JSON_Array
      then
         return False;
      end if;
      for I in 1 .. JSON.Length (Content) loop
         if Ada.Strings.Fixed.Index
              (Json_Lines.Text_Member (JSON.Element (Content, I), "text"),
               Marker) > 0
         then
            return True;
         end if;
      end loop;
      return False;
   end Is_Prompt_With;

   function Holds_Prompt_With (Rollout, Marker : String) return Boolean is
      Found : Boolean := False;

      procedure Read (Event : JSON.Value) is
      begin
         if Is_Prompt_With (Event, Marker) then
            Found := True;
         end if;
      end Read;
   begin
      Json_Lines.For_Each_Line (Rollout, Read'Access);
      return Found;
   end Holds_Prompt_With;

   --  Codex writes a session to a file named after when it began, in the
   --  folder of that day, so the newest files of the day are tried first.
   overriding function Locate
     (Item    : Codex;
      Session : Session_Handle;
      Files   : File_System.File_System'Class)
      return Transcript_Source
   is
      Directory : constant String :=
        To_String (Session.Home) & "/.codex/sessions/"
        & To_String (Session.Day);
      Names     : constant Synapse.Core.Text_Lists.Vector :=
        Files.List (Directory, ".jsonl");
   begin
      for I in reverse Names.First_Index .. Names.Last_Index loop
         declare
            Path : constant String :=
              Directory & "/" & To_String (Names (I));
            Read : constant File_System.Maybe_Content := Files.Read (Path);
         begin
            if Read.Found
              and then Holds_Prompt_With
                         (To_String (Read.Value), Marker_Of (Session))
            then
               return (Kind => From_File, Path => To_Unbounded_String (Path));
            end if;
         end;
      end loop;
      return (Kind => Not_Yet);
   end Locate;

   --  A turn begins with a `task_started` event and ends with a
   --  `task_complete` one that holds the agent's last message.
   overriding function Read_Turns
     (Item       : Codex;
      Transcript : String) return Turn_State
   is
      Result : Turn_State;

      procedure Read (Event : JSON.Value) is
         Payload : constant JSON.Value :=
           Json_Lines.Object_Member (Event, "payload");
         What    : constant String := Json_Lines.Text_Member (Payload, "type");
      begin
         if Json_Lines.Text_Member (Event, "type") /= "event_msg" then
            return;
         elsif What = "task_started" then
            Result := (Finished => False, Final => Null_Unbounded_String);
         elsif What = "task_complete" then
            Result :=
              (Finished => True,
               Final    => To_Unbounded_String
                             (Json_Lines.Text_Member
                                (Payload, "last_agent_message")));
         end if;
      end Read;
   begin
      Json_Lines.For_Each_Line (Transcript, Read'Access);
      return Result;
   end Read_Turns;

   ---------------------------------------------------------------------------
   --  OpenCode
   ---------------------------------------------------------------------------

   --  OpenCode takes only an id that begins with `ses`, followed by letters
   --  and digits, so the id is the session's own without its dashes.
   function Opencode_Id (Session : Session_Handle) return String is
      Result : String := To_String (Session.Id);
      Last   : Natural := 0;
   begin
      for C of Result loop
         if C /= '-' then
            Last := Last + 1;
            Result (Last) := C;
         end if;
      end loop;
      return "ses_" & Result (Result'First .. Result'First + Last - 1);
   end Opencode_Id;

   type Opencode is new Interactive with null record;

   overriding function Build
     (Item            : Opencode;
      Step            : Resolved.Step;
      Prompt          : String;
      Skill_Directory : String;
      Session         : Session_Handle)
      return Commands.Command_Results.Result;

   overriding function Locate
     (Item    : Opencode;
      Session : Session_Handle;
      Files   : File_System.File_System'Class)
      return Transcript_Source;

   overriding function Read_Turns
     (Item       : Opencode;
      Transcript : String) return Turn_State;

   --  OpenCode is run on a private server, which reads this process's
   --  environment, with the session id the runner gives it. Its permissions
   --  and model are set through the environment, and its prompt as one
   --  argument so that a prompt that begins with a dash is not read as an
   --  option. It is not told to approve what is not denied, so the person is
   --  asked.
   overriding function Build
     (Item            : Opencode;
      Step            : Resolved.Step;
      Prompt          : String;
      Skill_Directory : String;
      Session         : Session_Handle)
      return Commands.Command_Results.Result
   is
      Made   : Commands.Command;
      Config : constant String :=
        Commands.Opencode_Config (Step, With_Model => True);

      procedure Add (Item : String) is
      begin
         Made.Arguments.Append (To_Unbounded_String (Item));
      end Add;
   begin
      Made.Program := To_Unbounded_String ("opencode");
      Add ("--standalone");
      Add ("--session");
      Add (Opencode_Id (Session));
      Add ("--prompt=" & Prompt);
      if Config /= "" then
         Made.Environment.Append
           (To_Unbounded_String ("OPENCODE_CONFIG_CONTENT=" & Config));
      end if;
      return Commands.Command_Results.Success (Made);
   end Build;

   --  The session is kept in a database, which `session export` prints as one
   --  JSON document. A session that does not exist yet makes it fail.
   overriding function Locate
     (Item    : Opencode;
      Session : Session_Handle;
      Files   : File_System.File_System'Class)
      return Transcript_Source
   is
      Made : Commands.Command;
   begin
      Made.Program := To_Unbounded_String ("opencode");
      Made.Arguments.Append (To_Unbounded_String ("session"));
      Made.Arguments.Append (To_Unbounded_String ("export"));
      Made.Arguments.Append (To_Unbounded_String (Opencode_Id (Session)));
      return (Kind => From_Command, Run => Made);
   end Locate;

   --  The messages of the export are the person's prompts (`user`), the
   --  agent's messages (`assistant`) and a record `idle` that follows the last
   --  message of a turn.
   overriding function Read_Turns
     (Item       : Opencode;
      Transcript : String) return Turn_State
   is
      Result : Turn_State;
      Parsed : constant JSON.Parse_Result := JSON.Parse (Transcript);
      Last   : Unbounded_String;
   begin
      if not Parsed.Ok
        or else JSON.Kind_Of (Parsed.Item) /= JSON.JSON_Object
      then
         return Result;
      end if;
      declare
         Messages : constant JSON.Value :=
           Json_Lines.Object_Member (Parsed.Item, "messages");
      begin
         if JSON.Kind_Of (Messages) /= JSON.JSON_Array then
            return Result;
         end if;
         for I in 1 .. JSON.Length (Messages) loop
            declare
               Message : constant JSON.Value := JSON.Element (Messages, I);
               Kind    : constant String :=
                 Json_Lines.Text_Member (Message, "type");
               Blocks  : constant JSON.Value :=
                 Json_Lines.Object_Member (Message, "content");
            begin
               if Kind = "idle" then
                  Result := (Finished => True, Final => Last);
               elsif Kind in "user" | "assistant" then
                  Result :=
                    (Finished => False, Final => Null_Unbounded_String);
                  Last := Null_Unbounded_String;
                  if Kind = "assistant"
                    and then JSON.Kind_Of (Blocks) = JSON.JSON_Array
                  then
                     for J in 1 .. JSON.Length (Blocks) loop
                        if Json_Lines.Text_Member
                             (JSON.Element (Blocks, J), "type") = "text"
                        then
                           Append
                             (Last,
                              Json_Lines.Text_Member
                                (JSON.Element (Blocks, J), "text"));
                        end if;
                     end loop;
                  end if;
               end if;
            end;
         end loop;
      end;
      return Result;
   end Read_Turns;

   Claude_Harness   : aliased constant Claude := (null record);
   Codex_Harness    : aliased constant Codex := (null record);
   Opencode_Harness : aliased constant Opencode := (null record);

   function For_Harness
     (Kind : Harnesses.Harness_Kind)
      return access constant Interactive'Class is
     (case Kind is
        when Harnesses.Claude   => Claude_Harness'Access,
        when Harnesses.Codex    => Codex_Harness'Access,
        when Harnesses.Opencode => Opencode_Harness'Access);

   function Implemented return Support is
     ([for Kind in Harnesses.Harness_Kind => For_Harness (Kind) /= null]);

   function Problems
     (Item : Resolved.Pipeline; Can : Support := Implemented)
      return Synapse.Core.Text_Lists.Vector
   is
      Result : Synapse.Core.Text_Lists.Vector;
   begin
      for Step of Item.Steps loop
         if not Can (Step.Harness) then
            Result.Append
              (To_Unbounded_String
                 ("step " & To_String (Step.Name) & " runs on "
                  & Harnesses.Name_Of (Step.Harness)
                  & ", which cannot run a step interactively"));
         end if;
      end loop;
      return Result;
   end Problems;

end Synapse.Pipeline.Interactive_Harnesses;
