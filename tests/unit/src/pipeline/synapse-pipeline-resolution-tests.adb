with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.JSON;
with Synapse.Core.Optional_Text;
with Synapse.Core.Text_Lists;
with Synapse.Pipeline.Definitions;
with Synapse.Pipeline.Fake_Files;
with Synapse.Pipeline.Search_Paths;
with Synapse.Pipeline.Step_Data;

package body Synapse.Pipeline.Resolution.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Resolved.Origin_Kind;
   use type Harnesses.Harness_Kind;
   use type Synapse.Core.JSON.Value;
   use type Synapse.Core.JSON.Kind;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   package JSON renames Synapse.Core.JSON;

   No_Default : constant Harnesses.Kind_Options.Option :=
     Harnesses.Kind_Options.None;

   procedure Add_Definitions (F : in out Fake_Files.Fake_Files) is
   begin
      F.Add_File
        ("/defs/Reviewer.synapse",
         "Agent Reviewer [Prompt => ""You are a reviewer.""];");
      F.Add_File
        ("/defs/Tester.synapse", "Agent Tester [Prompt => Tester_Role];");
      F.Add_File
        ("/defs/Tester_Role.synapse",
         "Prompt Tester_Role [Prompt => ""You are a tester.""];");
      F.Add_File
        ("/defs/Own_Task.synapse",
         "Prompt Own_Task [Description => ""A task."", "
         & "Prompt => ""Own task.""];");
      F.Add_File
        ("/defs/Doubler.synapse", "Agent Doubler [Prompt => Own_Task];");
      F.Add_File
        ("/defs/Base.synapse",
         "System Base [Agent => Reviewer, Harness => Codex, "
         & "Model => ""big-model"", Permissions => Read_Only, "
         & "Timeout => ""10m"", Retries => 2, "
         & "Prompt => ""System task.""];");
      F.Add_File
        ("/defs/Plain.synapse",
         "Pipeline Plain { A [Harness => Claude, Prompt => ""do a"", "
         & "Model => Opus, Timeout => ""90s"", "
         & "Retries => 1]; }");
      F.Add_File
        ("/defs/Inherits.synapse",
         "Pipeline Inherits { A [System => Base];"
         & " B [System => Base, Harness => Claude, Retries => 0, "
         & "Timeout => ""1h"", Agent => Tester, Prompt => Own_Task];"
         & " C [System => Base, Prompt => ""Own text.""]; }");
      F.Add_File
        ("/defs/Named.synapse",
         "Pipeline Named { A [Harness => Claude, Prompt => Own_Task]; }");
      F.Add_File
        ("/defs/Twice.synapse",
         "Pipeline Twice { A [Harness => Claude, Agent => Doubler, "
         & "Prompt => Own_Task]; }");
      F.Add_File
        ("/defs/Lost.synapse",
         "Pipeline Lost { A [Harness => Claude, Prompt => Nowhere]; }");
      F.Add_File
        ("/defs/Edges.synapse",
         "Pipeline Edges { A [Harness => Claude, Prompt => ""x""];"
         & " B [Harness => Claude, Prompt => ""x""];"
         & " A -> B; B -> A [When => Changes_Requested, Max_Iterations => 3];"
         & " A -> A [When => {""=="": [{""var"": ""data.n""}, 1]}, "
         & "Max_Iterations => 2]; }");
      F.Add_File
        ("/defs/Judge.synapse",
         "System Judge [Harness => Claude, Prompt => ""Judge."", Outcomes => "
         & "{""Approved"": ""Fine."", ""Rejected"": ""Not fine.""}];");
      F.Add_File
        ("/defs/Judged.synapse",
         "Pipeline Judged { A [System => Judge];"
         & " B [System => Judge, Outcomes => {""Maybe"": ""Unsure.""}];"
         & " C [Harness => Claude, Prompt => ""x""]; }");
      F.Add_File
        ("/defs/Declared.synapse",
         "Pipeline Declared [Input => {""fields"": {""task_id"": "
         & "{""type"": ""string"", ""required"": true, "
         & """description"": ""The task.""}}}] "
         & "{ A [Harness => Claude, Prompt => ""x""]; }");
      F.Add_File
        ("/defs/Shaper.synapse",
         "System Shaper [Harness => Claude, Prompt => ""Shape."", Data => "
         & "{""fields"": {""shape"": {""type"": ""string"", "
         & """description"": ""The shape.""}}}];");
      F.Add_File
        ("/defs/Declaring.synapse",
         "Pipeline Declaring "
         & "{ A [Harness => Claude, Prompt => ""x"", Data => "
         & "{""fields"": {""item"": {""type"": ""string"", "
         & """description"": ""The item.""}}}];"
         & " B [System => Shaper];"
         & " C [System => Shaper, Data => {""fields"": {""size"": "
         & "{""type"": ""integer"", ""description"": ""The size.""}}}]; }");
      F.Add_File
        ("/defs/Namer.synapse",
         "System Namer [Harness => Claude, Prompt => ""Name."", "
         & "Data => [""remaining""]];");
      F.Add_File
        ("/defs/Shared.synapse",
         "Pipeline Shared [Data => {""fields"": {"
         & """task_note"": {""type"": ""string"", ""required"": true, "
         & """description"": ""The task note.""}, "
         & """remaining"": {""type"": ""integer"", "
         & """description"": ""Items left.""}, "
         & """problems"": {""type"": ""array"", "
         & """description"": ""What to fix.""}}}] "
         & "{ A [Harness => Claude, Prompt => ""x"", "
         & "Data => [""task_note"", ""remaining""], "
         & "Outcomes => {""Done"": ""Finished."", "
         & """Rejected"": {""meaning"": ""Not fine."", "
         & """data"": [""problems"", ""task_note""]}}];"
         & " B [System => Namer];"
         & " C [Harness => Claude, Prompt => ""x"", Data => "
         & "{""fields"": {""item"": {""type"": ""string"", "
         & """description"": ""The item.""}}}]; }");
      F.Add_File
        ("/defs/Bare.synapse", "Pipeline Bare { A [Prompt => ""x""]; }");
      F.Add_File
        ("/defs/Ghosts.synapse",
         "Pipeline Ghosts { A [Harness => Claude, Prompt => ""x"", "
         & "Agent => Nobody]; }");
      F.Add_File
        ("/defs/Misspelt.synapse",
         "Pipeline Misspelt { A [Harness => Cluade, Prompt => ""x""]; }");
      F.Add_File
        ("/defs/Effortful.synapse",
         "System Effortful [Harness => Claude, Prompt => ""x"", "
         & "Effort => Medium];");
      F.Add_File
        ("/defs/Efforted.synapse",
         "Pipeline Efforted { A [System => Effortful, Effort => High];"
         & " B [System => Effortful];"
         & " C [Harness => Claude, Prompt => ""x""];"
         & " D [Harness => Codex, Prompt => ""x"", Effort => ""xhigh""];"
         & " E [Harness => Opencode, Prompt => ""x"", Model => ""p/m"", "
         & "Effort => ""Deep-1""]; }");
      F.Add_File
        ("/defs/Too_Little.synapse",
         "Pipeline Too_Little { A [Harness => Claude, Prompt => ""x"", "
         & "Effort => minimal]; }");
      F.Add_File
        ("/defs/Too_Much.synapse",
         "Pipeline Too_Much { A [Harness => Codex, Prompt => ""x"", "
         & "Effort => extreme]; }");
      F.Add_File
        ("/defs/Modelless.synapse",
         "Pipeline Modelless { A [Harness => Opencode, Prompt => ""x"", "
         & "Effort => high]; }");
      F.Add_File
        ("/defs/Defaulted.synapse",
         "Pipeline Defaulted { A [Prompt => ""x"", Effort => minimal]; }");
   end Add_Definitions;

   function Defs_Of (F : Fake_Files.Fake_Files) return Namespaces.Namespace is
      Roots : Search_Paths.Root_Vectors.Vector;
   begin
      Roots.Append
        (Search_Paths.Root'(Path => To_Unbounded_String ("/defs"),
                            Required => True));
      return Definitions.Load (F, Roots).Definitions;
   end Defs_Of;

   --  The resolved pipeline called Name, which must resolve.
   function Resolve_OK
     (Name : String; Default : Harnesses.Kind_Options.Option := No_Default)
      return Resolved.Pipeline
   is
      F : Fake_Files.Fake_Files;
   begin
      Add_Definitions (F);
      declare
         R : constant Resolve_Results.Result :=
           Resolve (Defs_Of (F), Name, Default);
      begin
         Assert
           (Resolve_Results.Is_Success (R),
            "resolves: "
            & (if Resolve_Results.Is_Success (R) then ""
               else Source_Errors.Image (Resolve_Results.Error (R))));
         return Resolve_Results.Value_Or (R, (others => <>));
      end;
   end Resolve_OK;

   function Is_Instruction
     (Item : Resolved.Instruction; Text : String) return Boolean is
     (Item.Present and then To_String (Item.Text) = Text);

   --  Whether Item is an origin of the given kind, name and file.
   function Is_Origin
     (Item : Resolved.Origin; Kind : Resolved.Origin_Kind;
      Name, File : String) return Boolean is
     (Item.Kind = Kind and then To_String (Item.Name) = Name
      and then To_String (Item.File) = File);

   function Text_Of (Item : Synapse.Core.Optional_Text.Option) return String is
     (if Item.Found then To_String (Item.Value) else "<none>");

   procedure A_Step_With_Everything_Inline_Needs_No_System
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P : constant Resolved.Pipeline := Resolve_OK ("Plain");
      S : constant Resolved.Step := P.Steps (1);
   begin
      Assert (To_String (P.Name) = "Plain", "the pipeline's name");
      Assert (Natural (P.Steps.Length) = 1, "one step");
      Assert
        (To_String (S.Name) = "A" and then S.Harness = Harnesses.Claude,
         "its name and harness");
      Assert (not S.Role.Present, "no agent, no role");
      Assert
        (Is_Instruction (S.Assignment, "do a"),
         "its own prompt");
      Assert (Text_Of (S.Model) = "Opus", "a model, from a name");
      Assert (Text_Of (S.Permissions) = "<none>", "no permissions");
      Assert
        (S.Timeout_Seconds = 90 and then S.Retries = 1,
         "a timeout in seconds, and retries");
      Assert (S.Origins.Is_Empty, "nothing came from a definition");
   end A_Step_With_Everything_Inline_Needs_No_System;

   procedure A_Step_Takes_What_It_Does_Not_Set_From_Its_System
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S : constant Resolved.Step := Resolve_OK ("Inherits").Steps (1);
   begin
      Assert (S.Harness = Harnesses.Codex, "the system's harness");
      Assert
        (Is_Instruction
           (S.Role, "You are a reviewer."),
         "the role, from the system's agent");
      Assert
        (Is_Instruction (S.Assignment, "System task."),
         "the assignment, from the system");
      Assert
        (Text_Of (S.Model) = "big-model"
         and then Text_Of (S.Permissions) = "Read_Only",
         "model and permissions");
      Assert
        (S.Timeout_Seconds = 600 and then S.Retries = 2,
         "timeout and retries");
      Assert
        (Natural (S.Origins.Length) = 2
         and then S.Origins (1).Kind = Resolved.System_Origin
         and then To_String (S.Origins (1).Name) = "Base"
         and then To_String (S.Origins (1).File) = "/defs/Base.synapse"
         and then S.Origins (2).Kind = Resolved.Agent_Origin
         and then To_String (S.Origins (2).Name) = "Reviewer"
         and then To_String (S.Origins (2).File) = "/defs/Reviewer.synapse",
         "where its system and its agent came from");
   end A_Step_Takes_What_It_Does_Not_Set_From_Its_System;

   procedure A_Step_Overrides_Its_System (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      S : constant Resolved.Step := Resolve_OK ("Inherits").Steps (2);
   begin
      Assert (S.Harness = Harnesses.Claude, "its own harness");
      Assert
        (S.Retries = 0 and then S.Timeout_Seconds = 3600,
         "its own retries, even none, and timeout");
      Assert
        (Is_Instruction (S.Role, "You are a tester."),
         "its own agent, not the system's");
      Assert
        (Is_Instruction (S.Assignment, "Own task."),
         "its own prompt replaces the system's prompt whole");
      Assert
        (Text_Of (S.Model) = "big-model",
         "and what it does not set still comes from the system");
      Assert
        (Natural (S.Origins.Length) >= 2
         and then To_String (S.Origins (2).Name) = "Tester",
         "its own agent is the origin of its role");
   end A_Step_Overrides_Its_System;

   procedure A_Steps_Prompt_Name_Gives_The_Prompts_Text_As_The_Assignment
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S : constant Resolved.Step := Resolve_OK ("Named").Steps (1);
   begin
      Assert
        (Is_Instruction (S.Assignment, "Own task."),
         "the assignment is the named prompt's own text");
      Assert (not S.Role.Present, "no agent, no role");
   end A_Steps_Prompt_Name_Gives_The_Prompts_Text_As_The_Assignment;

   procedure An_Agents_Prompt_Name_Gives_The_Role
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S : constant Resolved.Step := Resolve_OK ("Inherits").Steps (2);
   begin
      Assert
        (Is_Instruction (S.Role, "You are a tester."),
         "the role is the text of the prompt the agent names");
   end An_Agents_Prompt_Name_Gives_The_Role;

   procedure A_Named_Prompt_Is_An_Origin_With_Its_File
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S     : constant Resolved.Step := Resolve_OK ("Inherits").Steps (2);
      Twice : constant Resolved.Step := Resolve_OK ("Twice").Steps (1);
      Plain : constant Resolved.Step := Resolve_OK ("Inherits").Steps (3);
   begin
      Assert
        (Natural (S.Origins.Length) = 4
         and then Is_Origin
                    (S.Origins (1), Resolved.System_Origin, "Base",
                     "/defs/Base.synapse")
         and then Is_Origin
                    (S.Origins (2), Resolved.Agent_Origin, "Tester",
                     "/defs/Tester.synapse")
         and then Is_Origin
                    (S.Origins (3), Resolved.Prompt_Origin, "Tester_Role",
                     "/defs/Tester_Role.synapse")
         and then Is_Origin
                    (S.Origins (4), Resolved.Prompt_Origin, "Own_Task",
                     "/defs/Own_Task.synapse"),
         "the system, the agent, then the role's and the assignment's "
         & "prompts");
      Assert
        (Natural (Twice.Origins.Length) = 2
         and then Is_Origin
                    (Twice.Origins (2), Resolved.Prompt_Origin, "Own_Task",
                     "/defs/Own_Task.synapse"),
         "a prompt used for both the role and the assignment is listed once");
      Assert
        (Natural (Plain.Origins.Length) = 2,
         "a prompt written in place is no origin");
   end A_Named_Prompt_Is_An_Origin_With_Its_File;

   procedure The_Steps_Prompt_Replaces_The_Systems_Whether_Text_Or_Name
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P : constant Resolved.Pipeline := Resolve_OK ("Inherits");
   begin
      Assert
        (Is_Instruction (P.Steps (2).Assignment, "Own task."),
         "a name replaces the system's prompt");
      Assert
        (Is_Instruction (P.Steps (3).Assignment, "Own text."),
         "a string replaces the system's prompt");
      Assert
        (Is_Instruction (P.Steps (1).Assignment, "System task."),
         "without one of its own, the step takes the system's");
   end The_Steps_Prompt_Replaces_The_Systems_Whether_Text_Or_Name;

   procedure The_Default_Harness_Fills_A_Missing_One
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      Add_Definitions (F);
      Assert
        (Resolve_OK
           ("Bare", Harnesses.Kind_Options.Of_Value (Harnesses.Opencode))
           .Steps (1).Harness = Harnesses.Opencode,
         "the default");
      declare
         R : constant Resolve_Results.Result :=
           Resolve (Defs_Of (F), "Bare", No_Default);
      begin
         Assert
           (not Resolve_Results.Is_Success (R)
            and then Ada.Strings.Fixed.Index
                       (To_String (Resolve_Results.Error (R).Message),
                        "step 'A' has no harness") > 0,
            "without one it fails, and does not raise");
      end;
   end The_Default_Harness_Fills_A_Missing_One;

   procedure Edges_Carry_Their_Guards_And_Bounds (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P : constant Resolved.Pipeline := Resolve_OK ("Edges");
   begin
      Assert (Natural (P.Edges.Length) = 3, "three edges, in order");
      Assert
        (To_String (P.Edges (1).From) = "A"
         and then To_String (P.Edges (1).To) = "B"
         and then not P.Edges (1).Has_Guard
         and then P.Edges (1).Max_Iterations = 0,
         "an unconditional, unbounded edge");
      Assert
        (P.Edges (2).Has_Guard and then P.Edges (2).Max_Iterations = 3,
         "a guarded, bounded one");
      Assert
        (P.Edges (2).Guard =
         JSON.Parse ("{""=="": [{""var"": ""outcome""}, "
                     & """Changes_Requested""]}").Item,
         "a bare name is a test of the outcome");
      Assert
        (P.Edges (3).Guard =
         JSON.Parse ("{""=="": [{""var"": ""data.n""}, 1]}").Item
         and then P.Edges (3).Max_Iterations = 2,
         "a JSON guard is kept as written");
   end Edges_Carry_Their_Guards_And_Bounds;

   procedure What_Cannot_Be_Resolved_Is_A_Failure_Not_A_Raise
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      Add_Definitions (F);
      declare
         Defs : constant Namespaces.Namespace := Defs_Of (F);
         Unknown : constant Resolve_Results.Result :=
           Resolve (Defs, "Nope", No_Default);
         Not_One : constant Resolve_Results.Result :=
           Resolve (Defs, "Reviewer", No_Default);
         Ghost   : constant Resolve_Results.Result :=
           Resolve (Defs, "Ghosts", No_Default);
         Typo    : constant Resolve_Results.Result :=
           Resolve (Defs, "Misspelt", No_Default);
         Lost    : constant Resolve_Results.Result :=
           Resolve (Defs, "Lost", No_Default);
      begin
         Assert
           (not Resolve_Results.Is_Success (Unknown)
            and then not Resolve_Results.Is_Success (Not_One),
            "a name that is no pipeline");
         Assert
           (not Resolve_Results.Is_Success (Ghost)
            and then Ada.Strings.Fixed.Index
                       (To_String (Resolve_Results.Error (Ghost).Message),
                        "names agent 'Nobody'") > 0
            and then To_String (Resolve_Results.Error (Ghost).File) =
                     "/defs/Ghosts.synapse",
            "an agent that is not there, in its file");
         Assert
           (not Resolve_Results.Is_Success (Typo)
            and then Ada.Strings.Fixed.Index
                       (To_String (Resolve_Results.Error (Typo).Message),
                        "a harness that does not exist") > 0,
            "a harness that does not exist");
         Assert
           (not Resolve_Results.Is_Success (Lost)
            and then Ada.Strings.Fixed.Index
                       (To_String (Resolve_Results.Error (Lost).Message),
                        "step 'A' names prompt 'Nowhere', which there is not")
                     > 0,
            "a prompt that is not there");
      end;
   end What_Cannot_Be_Resolved_Is_A_Failure_Not_A_Raise;

   procedure Outcomes_Come_From_The_Step_Else_Its_System
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P : constant Resolved.Pipeline := Resolve_OK ("Judged");
   begin
      Assert
        (JSON.Has_Member (P.Steps (1).Outcomes, "Approved")
         and then JSON.Has_Member (P.Steps (1).Outcomes, "Rejected")
         and then JSON.As_String
                    (JSON.Member_Value (P.Steps (1).Outcomes, "Approved")) =
                  "Fine.",
         "a step takes its system's outcomes with their meanings");
      Assert
        (JSON.Length (P.Steps (2).Outcomes) = 1
         and then JSON.Has_Member (P.Steps (2).Outcomes, "Maybe"),
         "its own replace the system's whole");
      Assert
        (JSON.Kind_Of (P.Steps (3).Outcomes) = JSON.JSON_Null,
         "a step that declares none has none");
   end Outcomes_Come_From_The_Step_Else_Its_System;

   procedure A_Pipelines_Input_Is_Resolved_As_Declared
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P     : constant Resolved.Pipeline := Resolve_OK ("Declared");
      Field : JSON.Value;
   begin
      Assert
        (JSON.Kind_Of (P.Input) = JSON.JSON_Object
         and then JSON.Has_Member (P.Input, "fields"),
         "the declaration is carried as an object");
      Field :=
        JSON.Member_Value (JSON.Member_Value (P.Input, "fields"), "task_id");
      Assert
        (JSON.As_String (JSON.Member_Value (Field, "description")) =
           "The task."
         and then JSON.As_String (JSON.Member_Value (Field, "type")) =
                  "string",
         "its fields are as written");
   end A_Pipelines_Input_Is_Resolved_As_Declared;

   procedure A_Pipeline_Without_Input_Resolves_With_A_Null_Input
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (JSON.Kind_Of (Resolve_OK ("Plain").Input) = JSON.JSON_Null,
         "no Input is a null Input");
   end A_Pipeline_Without_Input_Resolves_With_A_Null_Input;

   procedure A_Steps_Data_Is_Resolved_As_Declared
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P : constant Resolved.Pipeline := Resolve_OK ("Declaring");
   begin
      Assert
        (JSON.Kind_Of (P.Steps (1).Data) = JSON.JSON_Object
         and then JSON.Has_Member
                    (JSON.Member_Value (P.Steps (1).Data, "fields"), "item"),
         "a step's own Data is resolved as written");
      Assert
        (JSON.Length (JSON.Member_Value (P.Steps (3).Data, "fields")) = 1
         and then JSON.Has_Member
                    (JSON.Member_Value (P.Steps (3).Data, "fields"), "size"),
         "a step's own Data replaces its system's whole");
   end A_Steps_Data_Is_Resolved_As_Declared;

   procedure A_Step_Takes_Its_Systems_Data_When_It_Declares_None
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P : constant Resolved.Pipeline := Resolve_OK ("Declaring");
   begin
      Assert
        (JSON.Has_Member
           (JSON.Member_Value (P.Steps (2).Data, "fields"), "shape"),
         "the step has its system's Data");
   end A_Step_Takes_Its_Systems_Data_When_It_Declares_None;

   procedure Without_It_Data_Resolves_To_Null (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P : constant Resolved.Pipeline := Resolve_OK ("Plain");
   begin
      for S of P.Steps loop
         Assert
           (JSON.Kind_Of (S.Data) = JSON.JSON_Null, "no Data is a null Data");
      end loop;
   end Without_It_Data_Resolves_To_Null;

   --  The member Name of Value, null when Value is no object holding it.
   function Field_Of (Value : JSON.Value; Name : String) return JSON.Value is
     (if JSON.Kind_Of (Value) = JSON.JSON_Object
        and then JSON.Has_Member (Value, Name)
      then JSON.Member_Value (Value, Name) else JSON.Null_Value);

   function Description_Of (Field : JSON.Value) return String is
     (if JSON.Kind_Of (Field) = JSON.JSON_Object
        and then JSON.Has_Member (Field, "description")
      then JSON.As_String (JSON.Member_Value (Field, "description"))
      else "<none>");

   procedure A_Pipelines_Data_Is_Resolved_As_Declared
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P : constant Resolved.Pipeline := Resolve_OK ("Shared");
   begin
      Assert
        (JSON.Kind_Of (P.Data) = JSON.JSON_Object
         and then JSON.Length (Field_Of (P.Data, "fields")) = 3
         and then Description_Of
                    (Field_Of (Field_Of (P.Data, "fields"), "task_note")) =
                  "The task note.",
         "the pipeline's Data is carried as written");
      Assert
        (JSON.Kind_Of (Resolve_OK ("Plain").Data) = JSON.JSON_Null,
         "no pipeline Data is a null Data");
   end A_Pipelines_Data_Is_Resolved_As_Declared;

   procedure A_Steps_Named_Data_Becomes_The_Declared_Fields
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P      : constant Resolved.Pipeline := Resolve_OK ("Shared");
      Fields : constant JSON.Value := Field_Of (P.Steps (1).Data, "fields");
   begin
      Assert
        (JSON.Kind_Of (Fields) = JSON.JSON_Object
         and then JSON.Length (Fields) = 2
         and then JSON.Member_Key (Fields, 1) = "task_note"
         and then JSON.Member_Key (Fields, 2) = "remaining",
         "the names become fields, in the list's order");
      Assert
        (Description_Of (Field_Of (Fields, "task_note")) = "The task note."
         and then Description_Of (Field_Of (Fields, "remaining")) =
                  "Items left.",
         "each field is the pipeline's declaration");
   end A_Steps_Named_Data_Becomes_The_Declared_Fields;

   procedure A_Systems_Named_Data_Becomes_The_Declared_Fields
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P      : constant Resolved.Pipeline := Resolve_OK ("Shared");
      Fields : constant JSON.Value := Field_Of (P.Steps (2).Data, "fields");
   begin
      Assert
        (JSON.Kind_Of (Fields) = JSON.JSON_Object
         and then JSON.Length (Fields) = 1
         and then Description_Of (Field_Of (Fields, "remaining")) =
                  "Items left.",
         "the system's names become the pipeline's fields");
   end A_Systems_Named_Data_Becomes_The_Declared_Fields;

   procedure An_Outcomes_Named_Data_Becomes_The_Declared_Fields
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P    : constant Resolved.Pipeline := Resolve_OK ("Shared");
      Data : constant JSON.Value :=
        Field_Of (Field_Of (P.Steps (1).Outcomes, "Rejected"), "data");
   begin
      Assert
        (JSON.Kind_Of (Data) = JSON.JSON_Object
         and then JSON.Length (Data) = 2
         and then JSON.Member_Key (Data, 1) = "problems"
         and then Description_Of (Field_Of (Data, "problems")) =
                  "What to fix.",
         "the outcome's names become the declared fields");
      Assert
        (JSON.Kind_Of (Field_Of (P.Steps (1).Outcomes, "Done")) =
           JSON.JSON_String,
         "a string outcome is unchanged");
   end An_Outcomes_Named_Data_Becomes_The_Declared_Fields;

   procedure Named_Fields_Lists_The_Names_A_Step_Took
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P     : constant Resolved.Pipeline := Resolve_OK ("Shared");
      Names : constant Synapse.Core.Text_Lists.Vector :=
        P.Steps (1).Named_Fields;
   begin
      Assert
        (Natural (Names.Length) = 3
         and then To_String (Names (1)) = "task_note"
         and then To_String (Names (2)) = "remaining"
         and then To_String (Names (3)) = "problems",
         "each name once, Data first, then the outcomes");
      Assert
        (Natural (P.Steps (2).Named_Fields.Length) = 1
         and then To_String (P.Steps (2).Named_Fields (1)) = "remaining",
         "a name from the system counts");
   end Named_Fields_Lists_The_Names_A_Step_Took;

   procedure A_Step_With_Inline_Data_Has_No_Named_Fields
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Resolve_OK ("Shared").Steps (3).Named_Fields.Is_Empty,
         "inline Data names nothing");
      Assert
        (Resolve_OK ("Declaring").Steps (1).Named_Fields.Is_Empty,
         "nor does it without a pipeline Data");
   end A_Step_With_Inline_Data_Has_No_Named_Fields;

   procedure A_Step_That_Names_Its_Data_Is_Checked_Like_Inline
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      P      : constant Resolved.Pipeline := Resolve_OK ("Shared");
      Parsed : constant JSON.Parse_Result :=
        JSON.Parse
          ("{""outcome"": ""Done"", ""summary"": ""s"", "
           & """data"": {""remaining"": 1}}");
      Found  : Boolean := False;
   begin
      Assert (Parsed.Ok, "the sample is JSON");
      for Problem of Step_Data.Problems (P.Steps (1), Parsed.Item) loop
         if To_String (Problem) = "data.task_note: required field is missing"
         then
            Found := True;
         end if;
      end loop;
      Assert (Found, "a named required field is required");
   end A_Step_That_Names_Its_Data_Is_Checked_Like_Inline;

   --  The message of the failure that resolving Name ends with; empty when
   --  it resolves.
   function Failure_Of
     (Name : String; Default : Harnesses.Kind_Options.Option := No_Default)
      return String
   is
      F : Fake_Files.Fake_Files;
   begin
      Add_Definitions (F);
      declare
         R : constant Resolve_Results.Result :=
           Resolve (Defs_Of (F), Name, Default);
      begin
         return
           (if Resolve_Results.Is_Success (R) then ""
            else To_String (Resolve_Results.Error (R).Message));
      end;
   end Failure_Of;

   procedure A_Steps_Effort_Overrides_Its_Systems
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Text_Of (Resolve_OK ("Efforted").Steps (1).Effort) = "high",
         "the step's own effort, not its system's");
   end A_Steps_Effort_Overrides_Its_Systems;

   procedure A_Step_Takes_Its_Systems_Effort (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Text_Of (Resolve_OK ("Efforted").Steps (2).Effort) = "medium",
         "the system's effort");
   end A_Step_Takes_Its_Systems_Effort;

   procedure A_Step_Without_Effort_Resolves_With_None
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (not Resolve_OK ("Efforted").Steps (3).Effort.Found,
         "no effort");
      Assert
        (not Resolve_OK ("Plain").Steps (1).Effort.Found,
         "no effort, in a pipeline that never names one");
   end A_Step_Without_Effort_Resolves_With_None;

   procedure Effort_High_Is_Stored_As_High_For_Claude
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S : constant Resolved.Step := Resolve_OK ("Efforted").Steps (1);
   begin
      Assert
        (S.Harness = Harnesses.Claude and then Text_Of (S.Effort) = "high",
         "lower case, as Claude is given it");
   end Effort_High_Is_Stored_As_High_For_Claude;

   procedure Codex_Takes_Effort_Xhigh (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      S : constant Resolved.Step := Resolve_OK ("Efforted").Steps (4);
   begin
      Assert
        (S.Harness = Harnesses.Codex and then Text_Of (S.Effort) = "xhigh",
         "Codex's xhigh");
   end Codex_Takes_Effort_Xhigh;

   procedure Claude_Refuses_Effort_Minimal_Naming_Its_Efforts
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Failure_Of ("Too_Little") =
           "step 'A' asks Claude for effort 'minimal'; Claude offers "
           & "low, medium, high, xhigh, max",
         "refused, with what Claude offers: " & Failure_Of ("Too_Little"));
   end Claude_Refuses_Effort_Minimal_Naming_Its_Efforts;

   procedure Codex_Refuses_Effort_Extreme (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert
        (Ada.Strings.Fixed.Index
           (Failure_Of ("Too_Much"),
            "step 'A' asks Codex for effort 'extreme'; Codex offers ") = 1,
         "refused: " & Failure_Of ("Too_Much"));
   end Codex_Refuses_Effort_Extreme;

   procedure Opencode_Keeps_A_Variant_As_Written_With_A_Model
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      S : constant Resolved.Step := Resolve_OK ("Efforted").Steps (5);
   begin
      Assert
        (S.Harness = Harnesses.Opencode
         and then Text_Of (S.Model) = "p/m"
         and then Text_Of (S.Effort) = "Deep-1",
         "the variant, as written");
   end Opencode_Keeps_A_Variant_As_Written_With_A_Model;

   procedure An_Opencode_Variant_Without_A_Model_Is_Refused
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Failure_Of ("Modelless") =
           "step 'A' names an OpenCode variant but no Model; OpenCode takes "
           & "the variant as part of the model",
         "refused: " & Failure_Of ("Modelless"));
   end An_Opencode_Variant_Without_A_Model_Is_Refused;

   procedure The_Effort_Is_Checked_Against_The_Default_Harness
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Text_Of
           (Resolve_OK
              ("Defaulted",
               Harnesses.Kind_Options.Of_Value (Harnesses.Codex))
            .Steps (1).Effort) = "minimal",
         "Codex, the default, offers minimal");
      Assert
        (Ada.Strings.Fixed.Index
           (Failure_Of
              ("Defaulted",
               Harnesses.Kind_Options.Of_Value (Harnesses.Claude)),
            "asks Claude for effort 'minimal'") > 0,
         "Claude, the default, does not");
   end The_Effort_Is_Checked_Against_The_Default_Harness;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Resolution");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Pipelines_Input_Is_Resolved_As_Declared'Access,
         "A pipeline's Input is resolved as declared");
      Register_Routine
        (T, A_Pipeline_Without_Input_Resolves_With_A_Null_Input'Access,
         "A pipeline without Input resolves with a null Input");
      Register_Routine
        (T, Outcomes_Come_From_The_Step_Else_Its_System'Access,
         "Outcomes come from the step, else its system");
      Register_Routine
        (T, A_Steps_Data_Is_Resolved_As_Declared'Access,
         "A step's Data is resolved as declared");
      Register_Routine
        (T, A_Step_Takes_Its_Systems_Data_When_It_Declares_None'Access,
         "A step takes its system's Data when it declares none");
      Register_Routine
        (T, Without_It_Data_Resolves_To_Null'Access,
         "Without it, Data resolves to null");
      Register_Routine
        (T, A_Pipelines_Data_Is_Resolved_As_Declared'Access,
         "A pipeline's Data is resolved as declared");
      Register_Routine
        (T, A_Steps_Named_Data_Becomes_The_Declared_Fields'Access,
         "A step's named Data becomes the declared fields");
      Register_Routine
        (T, A_Systems_Named_Data_Becomes_The_Declared_Fields'Access,
         "A system's named Data becomes the declared fields");
      Register_Routine
        (T, An_Outcomes_Named_Data_Becomes_The_Declared_Fields'Access,
         "An outcome's named data becomes the declared fields");
      Register_Routine
        (T, Named_Fields_Lists_The_Names_A_Step_Took'Access,
         "Named_Fields lists the names a step took from the pipeline");
      Register_Routine
        (T, A_Step_With_Inline_Data_Has_No_Named_Fields'Access,
         "A step with inline Data has no named fields");
      Register_Routine
        (T, A_Step_That_Names_Its_Data_Is_Checked_Like_Inline'Access,
         "A step that names its data is checked like one that writes it "
         & "inline");
      Register_Routine
        (T, A_Step_With_Everything_Inline_Needs_No_System'Access,
         "A step with everything inline needs no system");
      Register_Routine
        (T, A_Step_Takes_What_It_Does_Not_Set_From_Its_System'Access,
         "A step takes what it does not set from its system");
      Register_Routine
        (T, A_Step_Overrides_Its_System'Access,
         "A step overrides its system");
      Register_Routine
        (T, The_Default_Harness_Fills_A_Missing_One'Access,
         "The default harness fills a missing one");
      Register_Routine
        (T, Edges_Carry_Their_Guards_And_Bounds'Access,
         "Edges carry their guards and bounds");
      Register_Routine
        (T, What_Cannot_Be_Resolved_Is_A_Failure_Not_A_Raise'Access,
         "What cannot be resolved is a failure, not a raise");
      Register_Routine
        (T,
         A_Steps_Prompt_Name_Gives_The_Prompts_Text_As_The_Assignment'Access,
         "A step's Prompt name gives the prompt's text as the assignment");
      Register_Routine
        (T, An_Agents_Prompt_Name_Gives_The_Role'Access,
         "An agent's Prompt name gives the role");
      Register_Routine
        (T, A_Named_Prompt_Is_An_Origin_With_Its_File'Access,
         "A named prompt is an origin with its file");
      Register_Routine
        (T,
         The_Steps_Prompt_Replaces_The_Systems_Whether_Text_Or_Name'Access,
         "The step's Prompt replaces the system's whether text or name");
      Register_Routine
        (T, A_Steps_Effort_Overrides_Its_Systems'Access,
         "A step's Effort overrides its system's");
      Register_Routine
        (T, A_Step_Takes_Its_Systems_Effort'Access,
         "A step takes its system's Effort");
      Register_Routine
        (T, A_Step_Without_Effort_Resolves_With_None'Access,
         "A step without Effort resolves with none");
      Register_Routine
        (T, Effort_High_Is_Stored_As_High_For_Claude'Access,
         "Effort => High is stored as high for Claude");
      Register_Routine
        (T, Codex_Takes_Effort_Xhigh'Access,
         "Codex takes Effort => ""xhigh""");
      Register_Routine
        (T, Claude_Refuses_Effort_Minimal_Naming_Its_Efforts'Access,
         "Claude refuses effort minimal, naming the efforts it offers");
      Register_Routine
        (T, Codex_Refuses_Effort_Extreme'Access,
         "Codex refuses effort extreme");
      Register_Routine
        (T, Opencode_Keeps_A_Variant_As_Written_With_A_Model'Access,
         "OpenCode keeps a variant as written when the step has a Model");
      Register_Routine
        (T, An_Opencode_Variant_Without_A_Model_Is_Refused'Access,
         "An OpenCode variant without a Model is refused");
      Register_Routine
        (T, The_Effort_Is_Checked_Against_The_Default_Harness'Access,
         "The effort is checked against the default harness when the step "
         & "names none");
   end Register_Tests;

end Synapse.Pipeline.Resolution.Tests;
