with Ada.Strings.Fixed;

with AUnit.Assertions;

with Synapse.Core.JSON;
with Synapse.Pipeline.Commands.Usage;
with Synapse.Pipeline.Test_Environment;

package body Synapse.Pipeline.Commands.Show.Tests is

   use AUnit.Assertions;
   use Synapse.Pipeline.Test_Environment;

   package JSON renames Synapse.Core.JSON;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   --  Definitions, all sound, and the variables that find them.
   procedure Set_Up (F : in out Fixture) is
   begin
      F.Base.Vars.Set ("SYNAPSE_PIPELINE_PATH", "/defs");
      F.Base.Vars.Set ("XDG_CONFIG_HOME", "/cfg");
      F.Files.Add_File
        ("/defs/Reviewer.synapse", "Agent Reviewer [Prompt => ""Review.""];");
      F.Files.Add_File
        ("/defs/Strict_Reviewer.synapse",
         "System Strict_Reviewer [Agent => Reviewer, Harness => Codex];");
      F.Files.Add_File
        ("/defs/Develop_Feature.synapse",
         "Pipeline Develop_Feature {"
         & " Develop [Harness => Claude, Prompt => ""Implement.""];"
         & " Review [System => Strict_Reviewer, Prompt => ""Review.""];"
         & " Review -> Develop [When => Changes_Requested, "
         & "Max_Iterations => 5]; }");
   end Set_Up;

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   procedure It_Takes_One_Pipeline_And_A_Known_Format
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Assert (Run (Env (F), Args) = 2, "none");
      Assert
        (F.Base.Console.Err_Text =
         "usage: synapse-pipeline show <pipeline> [--format json|text]" & LF,
         "says how");
      Assert (Run (Env (F), Args ("A", "B")) = 2, "two");
      Assert (Run (Env (F), Args ("A", "--format", "yaml")) = 2, "a format");
      Assert (Run (Env (F), Args ("A", "--format")) = 2, "a format missing");
      Assert (Run (Env (F), Args ("A", "--bogus")) = 2, "an option");
   end It_Takes_One_Pipeline_And_A_Known_Format;

   procedure Json_Is_The_Description_Of_The_Resolved_Pipeline
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert
        (Run (Env (F), Args ("Develop_Feature", "--format", "json")) = 0,
         "it can run: " & F.Base.Console.Err_Text);
      declare
         Parsed : constant JSON.Parse_Result :=
           JSON.Parse (F.Base.Console.Out_Text);
      begin
         Assert (Parsed.Ok, "standard output is one JSON document");
         Assert
           (JSON.As_String (JSON.Member_Value (Parsed.Item, "format")) =
            "synapse-pipeline-description/v1"
            and then JSON.As_String (JSON.Member_Value (Parsed.Item, "name"))
                     = "Develop_Feature",
            "its format and name");
         declare
            Steps : constant JSON.Value :=
              JSON.Member_Value (Parsed.Item, "steps");
            Edge  : constant JSON.Value :=
              JSON.Element (JSON.Member_Value (Parsed.Item, "edges"), 1);
         begin
            Assert
              (JSON.Length (Steps) = 2
               and then JSON.As_String
                          (JSON.Member_Value
                             (JSON.Element (Steps, 2), "harness")) = "Codex",
               "the steps, the second built from a system");
            Assert
              (JSON.As_Integer (JSON.Member_Value (Edge, "max_iterations")) =
               5
               and then JSON.As_String (JSON.Member_Value (Edge, "to")) =
                        "Develop",
               "the edge");
         end;
      end;
   end Json_Is_The_Description_Of_The_Resolved_Pipeline;

   procedure Text_Is_The_Same_Information_For_A_Person
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert (Run (Env (F), Args ("Develop_Feature")) = 0, "it can run");
      declare
         Out_Text : constant String := F.Base.Console.Out_Text;
      begin
         Assert (Has (Out_Text, "pipeline Develop_Feature" & LF), "its name");
         Assert
           (Has (Out_Text, "  step Develop  harness Claude"), "a step");
         Assert
           (Has (Out_Text, "  step Review  harness Codex"), "another");
         Assert
           (Has (Out_Text, "permissions Workspace_Write"), "its level");
         Assert
           (Has (Out_Text, "  edge 0  Review -> Develop"), "the edge");
         Assert (Has (Out_Text, "max iterations 5"), "its bound");
         Assert (Has (Out_Text, "runner process"), "the limits");
      end;
   end Text_Is_The_Same_Information_For_A_Person;

   procedure A_Pipeline_That_Cannot_Run_Prints_Nothing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert
        (Run (Env (F), Args ("Nothing_Like_It", "--format", "json")) = 1,
         "it does not resolve");
      Assert (F.Base.Console.Out_Text = "", "no partial document");
      Assert (F.Base.Console.Err_Text /= "", "the reason is on stderr");
   end A_Pipeline_That_Cannot_Run_Prints_Nothing;

   procedure Show_Is_In_The_Usage (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Has (Usage.Text, LF & "  show <pipeline>"), "listed");
   end Show_Is_In_The_Usage;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Commands.Show");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, It_Takes_One_Pipeline_And_A_Known_Format'Access,
         "It takes one pipeline and a known format");
      Register_Routine
        (T, Json_Is_The_Description_Of_The_Resolved_Pipeline'Access,
         "Json is the description of the resolved pipeline");
      Register_Routine
        (T, Text_Is_The_Same_Information_For_A_Person'Access,
         "Text is the same information for a person");
      Register_Routine
        (T, A_Pipeline_That_Cannot_Run_Prints_Nothing'Access,
         "A pipeline that cannot run prints nothing");
      Register_Routine
        (T, Show_Is_In_The_Usage'Access, "Show is in the usage");
   end Register_Tests;

end Synapse.Pipeline.Commands.Show.Tests;
