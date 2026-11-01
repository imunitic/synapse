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
         Role => (Present => True, Kind => Resolved.Prompt_Text,
                  Text => U ("Be careful.")),
         others => <>);
      Second :=
        (Name => U ("B"), Harness => Harnesses.Codex,
         Assignment => (Present => True, Kind => Resolved.Skill_Name,
                        Text => U ("test-feature")),
         Model => (Found => True, Value => U ("m-1")),
         Permissions => (Found => True, Value => U ("Read_Only")),
         Tools => (Found => True, Value => Parsed ("[""Read""]")),
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
         and then JSON.Kind_Of (JSON.Member_Value (A, "tools")) =
                  JSON.JSON_Null
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
         and then JSON.As_String (JSON.Member_Value (B, "model")) = "m-1"
         and then JSON.Length (JSON.Member_Value (B, "tools")) = 1,
         "the second step's own settings");
      Assert
        (JSON.As_String
           (JSON.Member_Value (JSON.Member_Value (B, "assignment"), "kind")) =
         "skill"
         and then JSON.As_String
                    (JSON.Member_Value
                       (JSON.Member_Value (B, "assignment"), "name")) =
                  "test-feature"
         and then not JSON.Has_Member
                        (JSON.Member_Value (B, "assignment"), "text"),
         "a skill is its name only");
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
        (T, Edges_Are_Numbered_As_State_Fired_Is'Access,
         "Edges are numbered as state.fired is");
      Register_Routine
        (T, The_Limits_Apply_And_The_Environment_Is_Left_Out'Access,
         "The limits are the configuration's and its environment is not");
   end Register_Tests;

end Synapse.Pipeline.Descriptions.Tests;
