with Ada.Strings.Fixed;

with Synapse.Pipeline.Instructions;
with Synapse.Pipeline.Prompts;
with Synapse.Pipeline.Resolved;

package body Synapse.Pipeline.Session_Support is

   use Ada.Strings.Unbounded;

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

   function With_Transcript
     (Item       : Sessions.Session_Result;
      Transcript : Synapse.Core.Optional_Text.Option)
      return Sessions.Session_Result
   is
      Result : Sessions.Session_Result := Item;
   begin
      Result.Transcript := Transcript;
      return Result;
   end With_Transcript;

   function Transcript_Name
     (Request : Sessions.Session_Request) return String is
     (Ada.Strings.Fixed.Trim
        (Natural'Image (Request.Visit), Ada.Strings.Left) & "-"
      & To_String (Request.Step.Name) & "-"
      & Ada.Strings.Fixed.Trim
          (Natural'Image (Request.Attempt), Ada.Strings.Left)
      & ".jsonl");

   function Begin_Transcript
     (Registry : in out Registry_Store.Store'Class;
      Request  : Sessions.Session_Request) return String
   is
      Id   : constant String := To_String (Request.Execution_Id);
      Name : constant String := Transcript_Name (Request);
   begin
      if Id = "" or else not Registry.Write_Transcript (Id, Name, "") then
         return "";
      end if;
      return Registry.Transcript_Path (Id, Name);
   end Begin_Transcript;

   function Keep_Transcript
     (Registry : in out Registry_Store.Store'Class;
      Request  : Sessions.Session_Request;
      Output   : String) return Synapse.Core.Optional_Text.Option
   is
      Id   : constant String := To_String (Request.Execution_Id);
      Name : constant String := Transcript_Name (Request);
   begin
      if Id = ""
        or else not Registry.Write_Transcript (Id, Name, Output)
      then
         return Synapse.Core.Optional_Text.None;
      end if;
      return Synapse.Core.Optional_Text.Of_Value
        (To_Unbounded_String (Registry.Transcript_Path (Id, Name)));
   end Keep_Transcript;

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

   procedure Prepare
     (Files           : File_System.File_System'Class;
      Skill_Roots     : Search_Paths.Root_Vectors.Vector;
      Request         : Sessions.Session_Request;
      Interactive     : Boolean;
      Prompt          : out Unbounded_String;
      Skill_Directory : out Unbounded_String;
      Problem         : out Unbounded_String)
   is
      Step      : Resolved.Step renames Request.Step;
      Role      : Unbounded_String;
      Task_Text : Unbounded_String;
      Role_Dir  : Unbounded_String;
      Task_Dir  : Unbounded_String;
   begin
      Prompt := Null_Unbounded_String;
      Skill_Directory := Null_Unbounded_String;
      Instructions.Text_Of
        (Files, Skill_Roots, Step.Role, Role, Role_Dir, Problem);
      if Length (Problem) > 0 then
         return;
      end if;
      Instructions.Text_Of
        (Files, Skill_Roots, Step.Assignment, Task_Text, Task_Dir, Problem);
      if Length (Problem) > 0 then
         return;
      end if;
      Prompt := To_Unbounded_String
        (Prompts.Build
           (Role            => To_String (Role),
            Assignment      => To_String (Task_Text),
            Step            => To_String (Step.Name),
            Initial_Input   => Request.Initial_Input,
            Previous_Output => Request.Previous_Output,
            Outcomes        => Step.Outcomes,
            Interactive     => Interactive));
      Skill_Directory :=
        (if Length (Task_Dir) > 0 then Task_Dir else Role_Dir);
   end Prepare;

   procedure Add_Settings
     (Into     : in out Synapse.Core.Text_Lists.Vector;
      Settings : Configs.Config) is
   begin
      for Item in Settings.Environment.Iterate loop
         Into.Append
           (To_Unbounded_String
              (Configs.Environment_Maps.Key (Item) & "="
               & Configs.Environment_Maps.Element (Item)));
      end loop;
   end Add_Settings;

end Synapse.Pipeline.Session_Support;
