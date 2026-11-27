with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Resolved;

package body Synapse.Pipeline.Descriptions.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   package JSON renames Synapse.Core.JSON;

   use type JSON.Kind;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   function Parsed (Text : String) return JSON.Value is
      Result : constant JSON.Parse_Result := JSON.Parse (Text);
   begin
      Assert (Result.Ok, "the sample is JSON: " & Text);
      return Result.Item;
   end Parsed;

   function U (Text : String) return Unbounded_String renames
     To_Unbounded_String;

   --  Two steps and two edges: the first step takes everything by default,
   --  the second sets everything.
   function Sample return Resolved.Pipeline is
      Result : Resolved.Pipeline;
      First  : Resolved.Step;
      Second : Resolved.Step;
   begin
      Result.Name := U ("P");
      First :=
        (Name => U ("A"), Harness => Harnesses.Claude,
         Role => (Present => True, Text => U ("Be careful.")),
         others => <>);
      Second :=
        (Name => U ("B"), Harness => Harnesses.Codex,
         Assignment => (Present => True, Text => U ("Test the feature.")),
         Model => (Found => True, Value => U ("m-1")),
         Permissions => (Found => True, Value => U ("Read_Only")),
         Timeout_Seconds => 90, Retries => 2,
         others => <>);
      Second.Origins.Append
        (Resolved.Origin'
           (Kind => Resolved.System_Origin, Name => U ("Strict"),
            File => U ("/defs/Strict.synapse")));
      Result.Steps.Append (First);
      Result.Steps.Append (Second);
      Result.Edges.Append
        (Resolved.Edge'
           (From => U ("B"), To => U ("A"), Has_Guard => True,
            Guard => Parsed ("{""=="":[1,1]}"), Max_Iterations => 5));
      Result.Edges.Append
        (Resolved.Edge'(From => U ("A"), To => U ("B"), others => <>));
      return Result;
   end Sample;

   procedure A_Step_Shows_The_Settings_It_Will_Run_With
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Settings : Configs.Config;
      Document : constant JSON.Value := Describe (Sample, Settings);
      Steps    : constant JSON.Value := JSON.Member_Value (Document, "steps");
      A        : constant JSON.Value := JSON.Element (Steps, 1);
      B        : constant JSON.Value := JSON.Element (Steps, 2);
   begin
      Assert
        (JSON.As_String (JSON.Member_Value (Document, "format")) =
         "synapse-pipeline-description/v1"
         and then JSON.As_String (JSON.Member_Value (Document, "name")) = "P",
         "its format and name");
      Assert (JSON.Length (Steps) = 2, "both steps, in order");
      Assert
        (JSON.As_String (JSON.Member_Value (A, "name")) = "A"
         and then JSON.As_String (JSON.Member_Value (A, "harness")) =
                  "Claude",
         "the first step");
      Assert
        (JSON.As_String (JSON.Member_Value (A, "permissions")) =
         "Workspace_Write",
         "a step with no level shows the default");
      Assert
        (JSON.As_Integer (JSON.Member_Value (A, "timeout_seconds")) =
         Long_Long_Integer (Settings.Default_Timeout_Seconds),
         "a step with no limit shows the configured one");
      Assert
        (JSON.Kind_Of (JSON.Member_Value (A, "model")) = JSON.JSON_Null
         and then JSON.Kind_Of (JSON.Member_Value (A, "assignment")) =
                  JSON.JSON_Null,
         "what is not given is null");
      Assert
        (JSON.As_String
           (JSON.Member_Value (JSON.Member_Value (A, "role"), "kind")) =
         "prompt"
         and then JSON.As_String
                    (JSON.Member_Value
                       (JSON.Member_Value (A, "role"), "text")) =
                  "Be careful.",
         "a prompt carries its text");
      Assert
        (JSON.As_String (JSON.Member_Value (B, "permissions")) = "Read_Only"
         and then JSON.As_Integer (JSON.Member_Value (B, "timeout_seconds")) =
                  90
         and then JSON.As_Integer (JSON.Member_Value (B, "retries")) = 2
         and then JSON.As_String (JSON.Member_Value (B, "model")) = "m-1",
         "the second step's own settings");
      declare
         Origin : constant JSON.Value :=
           JSON.Element (JSON.Member_Value (B, "origins"), 1);
      begin
         Assert
           (JSON.As_String (JSON.Member_Value (Origin, "kind")) = "system"
            and then JSON.As_String (JSON.Member_Value (Origin, "name")) =
                     "Strict"
            and then JSON.As_String (JSON.Member_Value (Origin, "file")) =
                     "/defs/Strict.synapse",
            "where the step came from");
      end;
   end A_Step_Shows_The_Settings_It_Will_Run_With;

   procedure A_Named_Prompt_Is_Described_By_Its_Text_And_Listed_As_Origin
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Item     : Resolved.Pipeline;
      S        : Resolved.Step :=
        (Name => U ("A"), Harness => Harnesses.Claude,
         Assignment => (Present => True, Text => U ("Test the feature.")),
         others => <>);
      Settings : Configs.Config;
   begin
      Item.Name := U ("P");
      S.Origins.Append
        (Resolved.Origin'
           (Kind => Resolved.Prompt_Origin, Name => U ("Test_Feature"),
            File => U ("/defs/Test_Feature.synapse")));
      Item.Steps.Append (S);
      declare
         Step       : constant JSON.Value :=
           JSON.Element
             (JSON.Member_Value (Describe (Item, Settings), "steps"), 1);
         Assignment : constant JSON.Value :=
           JSON.Member_Value (Step, "assignment");
         Origin     : constant JSON.Value :=
           JSON.Element (JSON.Member_Value (Step, "origins"), 1);
      begin
         Assert
           (JSON.As_String (JSON.Member_Value (Assignment, "kind")) = "prompt"
            and then JSON.As_String (JSON.Member_Value (Assignment, "text")) =
                     "Test the feature."
            and then not JSON.Has_Member (Assignment, "name"),
            "the assignment is the prompt's text");
         Assert
           (JSON.As_String (JSON.Member_Value (Origin, "kind")) = "prompt"
            and then JSON.As_String (JSON.Member_Value (Origin, "name")) =
                     "Test_Feature"
            and then JSON.As_String (JSON.Member_Value (Origin, "file")) =
                     "/defs/Test_Feature.synapse",
            "the prompt is an origin with its file");
      end;
   end A_Named_Prompt_Is_Described_By_Its_Text_And_Listed_As_Origin;

   procedure Edges_Are_Numbered_As_State_Fired_Is
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Settings : Configs.Config;
      Edges    : constant JSON.Value :=
        JSON.Member_Value (Describe (Sample, Settings), "edges");
      First    : constant JSON.Value := JSON.Element (Edges, 1);
      Second   : constant JSON.Value := JSON.Element (Edges, 2);
   begin
      Assert (JSON.Length (Edges) = 2, "both edges");
      Assert
        (JSON.As_Integer (JSON.Member_Value (First, "index")) = 0
         and then JSON.As_String (JSON.Member_Value (First, "from")) = "B"
         and then JSON.As_String (JSON.Member_Value (First, "to")) = "A"
         and then JSON.Kind_Of (JSON.Member_Value (First, "guard")) =
                  JSON.JSON_Object
         and then JSON.As_Integer
                    (JSON.Member_Value (First, "max_iterations")) = 5,
         "the first edge, guarded and bounded");
      Assert
        (JSON.As_Integer (JSON.Member_Value (Second, "index")) = 1
         and then JSON.Kind_Of (JSON.Member_Value (Second, "guard")) =
                  JSON.JSON_Null
         and then JSON.Kind_Of
                    (JSON.Member_Value (Second, "max_iterations")) =
                  JSON.JSON_Null,
         "the second edge, unconditional and unbounded");
   end Edges_Are_Numbered_As_State_Fired_Is;

   procedure The_Limits_Apply_And_The_Environment_Is_Left_Out
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Settings : Configs.Config;
   begin
      Settings.Default_Timeout_Seconds := 120;
      Settings.Step_Ceiling := 7;
      Settings.Runner := Configs.Scripted_Runner;
      Settings.Environment.Insert
        (Configs.Vault_Dir_Key, "/private/vault-location");
      declare
         Document : constant JSON.Value := Describe (Sample, Settings);
         Limits   : constant JSON.Value :=
           JSON.Member_Value (Document, "limits");
      begin
         Assert
           (JSON.As_Integer
              (JSON.Member_Value (Limits, "default_timeout_seconds")) = 120
            and then JSON.As_Integer
                       (JSON.Member_Value (Limits, "step_ceiling")) = 7
            and then JSON.As_String (JSON.Member_Value (Limits, "runner")) =
                     "scripted",
            "the limits that apply");
         Assert
           (Ada.Strings.Fixed.Index
              (JSON.To_String (Document), "private") = 0,
            "no environment value is in the document");
      end;
   end The_Limits_Apply_And_The_Environment_Is_Left_Out;

   --  The input member of Sample described with Declared as its `Input`.
   function Input_Of (Declared : String) return JSON.Value is
      Item     : Resolved.Pipeline := Sample;
      Settings : Configs.Config;
   begin
      if Declared'Length > 0 then
         Item.Input := Parsed (Declared);
      end if;
      return JSON.Member_Value (Describe (Item, Settings), "input");
   end Input_Of;

   procedure Input_Is_Null_Without_A_Declaration
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Settings : Configs.Config;
      Document : constant JSON.Value := Describe (Sample, Settings);
   begin
      Assert
        (JSON.Has_Member (Document, "input")
         and then JSON.Kind_Of (JSON.Member_Value (Document, "input")) =
                  JSON.JSON_Null,
         "input is there, and null");
      Assert
        (JSON.Member_Key (Document, 3) = "input",
         "input comes after name");
   end Input_Is_Null_Without_A_Declaration;

   procedure Input_Lists_Fields_In_Order_With_Their_Rules
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Input : constant JSON.Value :=
        Input_Of
          ("{""fields"": {"
           & """task_id"": {""type"": ""string"", ""required"": true,"
           & " ""pattern"": ""^[a-z]+-[0-9]+$"","
           & " ""description"": ""The task.""},"
           & """mode"": {""type"": ""string"", ""enum"": [""a"", ""b""],"
           & " ""min_length"": 1, ""const"": ""a"","
           & " ""description"": ""The mode.""}},"
           & """checks"": [{""rule"": {""!!"": [{""var"": ""task_id""}]},"
           & " ""message"": ""needs a task""}]}");
   begin
      Assert
        (JSON.To_String (Input) =
         "{""fields"":["
         & "{""name"":""task_id"",""type"":""string"",""required"":true,"
         & """description"":""The task."",""pattern"":""^[a-z]+-[0-9]+$""},"
         & "{""name"":""mode"",""type"":""string"",""required"":false,"
         & """description"":""The mode."",""min_length"":1,""const"":""a"","
         & """enum"":[""a"",""b""]}],"
         & """checks"":[{""rule"":{""!!"":[{""var"":""task_id""}]},"
         & """message"":""needs a task""}],"
         & """single_text_field"":""task_id""}",
         "the fields in order, with their rules: " & JSON.To_String (Input));
   end Input_Lists_Fields_In_Order_With_Their_Rules;

   procedure A_List_Of_Items_With_Fields_Nests (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Input : constant JSON.Value :=
        Input_Of
          ("{""fields"": {"
           & """tags"": {""type"": ""list"", ""items"": ""string"","
           & " ""description"": ""Tags.""},"
           & """files"": {""type"": ""list"", ""required"": true,"
           & " ""description"": ""Files."", ""items"": {""fields"": {"
           & """path"": {""type"": ""string"", ""required"": true,"
           & " ""description"": ""A path.""}}}}}}");
   begin
      Assert
        (JSON.To_String (Input) =
         "{""fields"":["
         & "{""name"":""tags"",""type"":""list"",""required"":false,"
         & """description"":""Tags."",""items"":""string""},"
         & "{""name"":""files"",""type"":""list"",""required"":true,"
         & """description"":""Files."",""items"":{""fields"":["
         & "{""name"":""path"",""type"":""string"",""required"":true,"
         & """description"":""A path.""}]}}],"
         & """checks"":[],""single_text_field"":null}",
         "items with fields nest in the same shape: "
         & JSON.To_String (Input));
   end A_List_Of_Items_With_Fields_Nests;

   procedure An_Object_Outcome_Is_Described_By_Its_Description
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Settings : Configs.Config;
      Pipeline : Resolved.Pipeline := Sample;
   begin
      declare
         First : Resolved.Step := Pipeline.Steps (1);
      begin
         First.Outcomes :=
           Parsed
             ("{""Done"": ""It is done."","
              & " ""Blocked"": {""description"": ""Cannot."","
              & " ""data"": {""blocker"": {""type"": ""string"","
              & " ""description"": ""Why.""}}}}");
         Pipeline.Steps.Replace_Element (1, First);
      end;
      declare
         Document : constant JSON.Value := Describe (Pipeline, Settings);
         Outcomes : constant JSON.Value :=
           JSON.Member_Value
             (JSON.Element (JSON.Member_Value (Document, "steps"), 1),
              "outcomes");
      begin
         Assert
           (JSON.To_String (Outcomes) =
            "[{""word"":""Done"",""meaning"":""It is done."",""data"":null},"
            & "{""word"":""Blocked"",""meaning"":""Cannot."",""data"":["
            & "{""name"":""blocker"",""type"":""string"",""required"":false,"
            & """description"":""Why."",""from"":""step""}]}]",
            "each meaning is a line: " & JSON.To_String (Outcomes));
      end;
   end An_Object_Outcome_Is_Described_By_Its_Description;

   --  The first step of Sample described with Data as its `Data` and
   --  Declared as its `Outcomes`, each left as it is when empty.
   function First_Step_With (Data, Declared : String) return JSON.Value is
      Settings : Configs.Config;
      Pipeline : Resolved.Pipeline := Sample;
      First    : Resolved.Step := Pipeline.Steps (1);
   begin
      if Data'Length > 0 then
         First.Data := Parsed (Data);
      end if;
      if Declared'Length > 0 then
         First.Outcomes := Parsed (Declared);
      end if;
      Pipeline.Steps.Replace_Element (1, First);
      return JSON.Element
        (JSON.Member_Value (Describe (Pipeline, Settings), "steps"), 1);
   end First_Step_With;

   procedure A_Steps_Data_Is_Described (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Data : constant JSON.Value :=
        JSON.Member_Value
          (First_Step_With
             ("{""fields"": {"
              & """task_note"": {""type"": ""string"", ""required"": true,"
              & " ""description"": ""The task note.""},"
              & """item"": {""type"": ""string"","
              & " ""description"": ""The item.""}},"
              & """checks"": [{""rule"": {""!!"": [{""var"": ""item""}]},"
              & " ""message"": ""needs an item""}]}",
              ""),
           "data");
   begin
      Assert
        (JSON.To_String (Data) =
         "{""fields"":["
         & "{""name"":""task_note"",""type"":""string"",""required"":true,"
         & """description"":""The task note."",""from"":""step""},"
         & "{""name"":""item"",""type"":""string"",""required"":false,"
         & """description"":""The item."",""from"":""step""}],"
         & """checks"":[{""rule"":{""!!"":[{""var"":""item""}]},"
         & """message"":""needs an item""}]}",
         "the fields in declared order, and the checks, without "
         & "single_text_field: " & JSON.To_String (Data));
   end A_Steps_Data_Is_Described;

   procedure An_Outcomes_Data_Is_Described_With_The_Outcome
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Outcomes : constant JSON.Value :=
        JSON.Member_Value
          (First_Step_With
             ("",
              "{""Changes_Requested"": {""description"": ""Fix these."","
              & " ""data"": {""problems"": {""type"": ""list"","
              & " ""required"": true, ""description"": ""What to fix."","
              & " ""items"": {""fields"": {""issue"": {""type"": ""string"","
              & " ""required"": true, ""description"": ""The issue.""}}}}}}}"),
           "outcomes");
   begin
      Assert
        (JSON.To_String
           (JSON.Member_Value (JSON.Element (Outcomes, 1), "data")) =
         "[{""name"":""problems"",""type"":""list"",""required"":true,"
         & """description"":""What to fix."",""items"":{""fields"":["
         & "{""name"":""issue"",""type"":""string"",""required"":true,"
         & """description"":""The issue.""}]},""from"":""step""}]",
         "the outcome's fields, in the shape of input's: "
         & JSON.To_String (Outcomes));
   end An_Outcomes_Data_Is_Described_With_The_Outcome;

   procedure Without_Them_Data_Is_Null (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Step : constant JSON.Value :=
        First_Step_With ("", "{""Done"": ""It is done.""}");
   begin
      Assert
        (JSON.Has_Member (Step, "data")
         and then JSON.Kind_Of (JSON.Member_Value (Step, "data")) =
                  JSON.JSON_Null,
         "a step without Data has a null data");
      Assert
        (JSON.Kind_Of
           (JSON.Member_Value
              (JSON.Element (JSON.Member_Value (Step, "outcomes"), 1),
               "data")) = JSON.JSON_Null,
         "an outcome without data has a null data");
   end Without_Them_Data_Is_Null;

   Task_Note_Shape : constant String :=
     "{""fields"": {""task_note"": {""type"": ""string"","
     & " ""required"": true, ""description"": ""The task note.""}}}";

   procedure A_Pipelines_Data_Is_Described (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Settings : Configs.Config;
      Pipeline : Resolved.Pipeline := Sample;
   begin
      Pipeline.Data := Parsed (Task_Note_Shape);
      declare
         Data : constant JSON.Value :=
           JSON.Member_Value (Describe (Pipeline, Settings), "data");
      begin
         Assert
           (JSON.To_String (Data) =
            "{""fields"":["
            & "{""name"":""task_note"",""type"":""string"",""required"":true,"
            & """description"":""The task note.""}]}",
            "the shapes as fields, in the shape of input's: "
            & JSON.To_String (Data));
      end;
   end A_Pipelines_Data_Is_Described;

   procedure Without_It_The_Pipelines_Data_Is_Null
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Settings : Configs.Config;
      Document : constant JSON.Value := Describe (Sample, Settings);
   begin
      Assert
        (JSON.Has_Member (Document, "data")
         and then JSON.Kind_Of (JSON.Member_Value (Document, "data")) =
                  JSON.JSON_Null,
         "a pipeline without Data has a null data");
   end Without_It_The_Pipelines_Data_Is_Null;

   --  The first step of a Sample whose first step has the resolved Data
   --  Task_Note_Shape and an outcome Done with the same data, and whose
   --  Named_Fields holds Named when it is not empty.
   function First_Step_Named (Named : String) return JSON.Value is
      Settings : Configs.Config;
      Pipeline : Resolved.Pipeline := Sample;
      First    : Resolved.Step := Pipeline.Steps (1);
   begin
      Pipeline.Data := Parsed (Task_Note_Shape);
      First.Data := Parsed (Task_Note_Shape);
      First.Outcomes :=
        Parsed
          ("{""Done"": {""description"": ""It is done."", ""data"": "
           & JSON.To_String
               (JSON.Member_Value (Parsed (Task_Note_Shape), "fields"))
           & "}}");
      if Named'Length > 0 then
         First.Named_Fields.Append (U (Named));
      end if;
      Pipeline.Steps.Replace_Element (1, First);
      return JSON.Element
        (JSON.Member_Value (Describe (Pipeline, Settings), "steps"), 1);
   end First_Step_Named;

   --  The `from` of the first field of a step's data and of its first
   --  outcome's data.
   function Data_From (Step : JSON.Value) return String is
     (JSON.As_String
        (JSON.Member_Value
           (JSON.Element
              (JSON.Member_Value (JSON.Member_Value (Step, "data"), "fields"),
               1),
            "from")));

   function Outcome_From (Step : JSON.Value) return String is
     (JSON.As_String
        (JSON.Member_Value
           (JSON.Element
              (JSON.Member_Value
                 (JSON.Element (JSON.Member_Value (Step, "outcomes"), 1),
                  "data"),
               1),
            "from")));

   procedure A_Named_Field_Is_Described_As_From_The_Pipeline
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Step : constant JSON.Value := First_Step_Named ("task_note");
   begin
      Assert
        (Data_From (Step) = "pipeline",
         "the step's field: " & JSON.To_String (Step));
      Assert
        (Outcome_From (Step) = "pipeline",
         "the outcome's field: " & JSON.To_String (Step));
   end A_Named_Field_Is_Described_As_From_The_Pipeline;

   procedure An_Inline_Field_Is_Described_As_From_The_Step
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Step : constant JSON.Value := First_Step_Named ("");
   begin
      Assert
        (Data_From (Step) = "step",
         "the step's field: " & JSON.To_String (Step));
      Assert
        (Outcome_From (Step) = "step",
         "the outcome's field: " & JSON.To_String (Step));
   end An_Inline_Field_Is_Described_As_From_The_Step;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Descriptions");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Step_Shows_The_Settings_It_Will_Run_With'Access,
         "A step shows the settings it will run with");
      Register_Routine
        (T,
         A_Named_Prompt_Is_Described_By_Its_Text_And_Listed_As_Origin'Access,
         "A named prompt is described by its text, and listed as a prompt "
         & "origin");
      Register_Routine
        (T, Edges_Are_Numbered_As_State_Fired_Is'Access,
         "Edges are numbered as state.fired is");
      Register_Routine
        (T, The_Limits_Apply_And_The_Environment_Is_Left_Out'Access,
         "The limits are the configuration's and its environment is not");
      Register_Routine
        (T, Input_Is_Null_Without_A_Declaration'Access,
         "Input is null without a declaration");
      Register_Routine
        (T, Input_Lists_Fields_In_Order_With_Their_Rules'Access,
         "Input lists fields in order with their rules");
      Register_Routine
        (T, A_List_Of_Items_With_Fields_Nests'Access,
         "A list of items with fields nests");
      Register_Routine
        (T, An_Object_Outcome_Is_Described_By_Its_Description'Access,
         "An object outcome is described by its description");
      Register_Routine
        (T, A_Steps_Data_Is_Described'Access, "A step's Data is described");
      Register_Routine
        (T, An_Outcomes_Data_Is_Described_With_The_Outcome'Access,
         "An outcome's data is described with the outcome");
      Register_Routine
        (T, Without_Them_Data_Is_Null'Access, "Without them, data is null");
      Register_Routine
        (T, A_Pipelines_Data_Is_Described'Access,
         "A pipeline's Data is described");
      Register_Routine
        (T, Without_It_The_Pipelines_Data_Is_Null'Access,
         "Without it, the pipeline's data is null");
      Register_Routine
        (T, A_Named_Field_Is_Described_As_From_The_Pipeline'Access,
         "A named field is described as from the pipeline");
      Register_Routine
        (T, An_Inline_Field_Is_Described_As_From_The_Step'Access,
         "An inline field is described as from the step");
   end Register_Tests;

end Synapse.Pipeline.Descriptions.Tests;
