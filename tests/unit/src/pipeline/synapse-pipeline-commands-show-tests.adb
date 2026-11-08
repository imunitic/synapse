with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.JSON;
with Synapse.Pipeline.Commands.Usage;
with Synapse.Pipeline.Test_Environment;

package body Synapse.Pipeline.Commands.Show.Tests is

   use Ada.Strings.Unbounded;
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
         "usage: synapse-pipeline show <name> [--format json|text]" & LF,
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
      Assert (Has (Usage.Text, LF & "  show <name>"), "listed");
   end Show_Is_In_The_Usage;

   procedure An_Edge_To_End_Is_Shown_And_End_Is_Not_A_Step
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      F.Files.Add_File
        ("/defs/Gate.synapse",
         "Pipeline Gate {"
         & " Check [Harness => Claude, Prompt => ""Is it ready?""];"
         & " Build [Harness => Claude, Prompt => ""Build it.""];"
         & " Check -> End [When => Discussing]; }");
      Assert
        (Run (Env (F), Args ("Gate", "--format", "json")) = 0,
         "it can run: " & F.Base.Console.Err_Text);
      declare
         Parsed : constant JSON.Parse_Result :=
           JSON.Parse (F.Base.Console.Out_Text);
      begin
         Assert (Parsed.Ok, "one JSON document");
         Assert
           (JSON.Length (JSON.Member_Value (Parsed.Item, "steps")) = 2,
            "End is not among the steps");
         Assert
           (JSON.As_String
              (JSON.Member_Value
                 (JSON.Element (JSON.Member_Value (Parsed.Item, "edges"), 1),
                  "to")) = "End",
            "the edge leads to End");
      end;
   end An_Edge_To_End_Is_Shown_And_End_Is_Not_A_Step;

   --  The names in the `used_by` member of a document, as kind:name.
   function Users (Document : JSON.Value) return String is
      List   : constant JSON.Value := JSON.Member_Value (Document, "used_by");
      Result : Unbounded_String;
   begin
      for I in 1 .. JSON.Length (List) loop
         Append
           (Result,
            JSON.As_String (JSON.Member_Value (JSON.Element (List, I), "kind"))
            & ":"
            & JSON.As_String
                (JSON.Member_Value (JSON.Element (List, I), "name")) & " ");
      end loop;
      return To_String (Result);
   end Users;

   procedure A_System_And_An_Agent_Are_Described_With_Who_Uses_Them
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert
        (Run (Env (F), Args ("Strict_Reviewer", "--format", "json")) = 0,
         "a system: " & F.Base.Console.Err_Text);
      declare
         System : constant JSON.Parse_Result :=
           JSON.Parse (F.Base.Console.Out_Text);
      begin
         Assert (System.Ok, "one JSON document");
         Assert
           (JSON.As_String (JSON.Member_Value (System.Item, "format")) =
            "synapse-pipeline-definition/v1"
            and then JSON.As_String (JSON.Member_Value (System.Item, "kind"))
                     = "system"
            and then JSON.As_String
                       (JSON.Member_Value (System.Item, "file")) =
                     "/defs/Strict_Reviewer.synapse",
            "its format, kind and file");
         Assert
           (JSON.Length (JSON.Member_Value (System.Item, "attributes")) = 2
            and then JSON.As_String
                       (JSON.Member_Value
                          (JSON.Element
                             (JSON.Member_Value (System.Item, "attributes"),
                              1), "value")) = "Reviewer",
            "its attributes as written");
         Assert (Users (System.Item) = "pipeline:Develop_Feature ",
                 "the pipeline that uses it: " & Users (System.Item));
      end;

      declare
         G     : aliased Fixture;
         Agent : JSON.Parse_Result;
      begin
         Set_Up (G);
         Assert
           (Run (Env (G), Args ("Reviewer", "--format", "json")) = 0,
            "an agent");
         Agent := JSON.Parse (G.Base.Console.Out_Text);
         Assert
           (JSON.As_String (JSON.Member_Value (Agent.Item, "kind")) = "agent"
            and then Users (Agent.Item) = "system:Strict_Reviewer ",
            "the system that uses an agent: " & Users (Agent.Item));
      end;
   end A_System_And_An_Agent_Are_Described_With_Who_Uses_Them;

   procedure An_Unused_Definition_Is_Used_By_Nothing
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      F.Files.Add_File
        ("/defs/Idle.synapse", "Agent Idle [Prompt => ""Wait.""];");
      Assert (Run (Env (F), Args ("Idle")) = 0, "a definition in text");
      Assert
        (Has (F.Base.Console.Out_Text, "agent Idle  /defs/Idle.synapse")
         and then Has (F.Base.Console.Out_Text, "used by nothing"),
         "said in text");
   end An_Unused_Definition_Is_Used_By_Nothing;

   procedure A_Pipeline_Names_Its_Kind_And_File
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert
        (Run (Env (F), Args ("Develop_Feature", "--format", "json")) = 0,
         "it can run");
      declare
         Parsed : constant JSON.Parse_Result :=
           JSON.Parse (F.Base.Console.Out_Text);
      begin
         Assert
           (JSON.As_String (JSON.Member_Value (Parsed.Item, "kind")) =
            "pipeline"
            and then JSON.As_String (JSON.Member_Value (Parsed.Item, "file"))
                     = "/defs/Develop_Feature.synapse"
            and then Users (Parsed.Item) = "",
            "kind, file and nothing uses it");
      end;
   end A_Pipeline_Names_Its_Kind_And_File;

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
      Register_Routine
        (T, An_Edge_To_End_Is_Shown_And_End_Is_Not_A_Step'Access,
         "An edge to End is shown and End is not a step");
      Register_Routine
        (T, A_System_And_An_Agent_Are_Described_With_Who_Uses_Them'Access,
         "A system and an agent are described with who uses them");
      Register_Routine
        (T, An_Unused_Definition_Is_Used_By_Nothing'Access,
         "An unused definition is used by nothing");
      Register_Routine
        (T, A_Pipeline_Names_Its_Kind_And_File'Access,
         "A pipeline names its kind and file");
   end Register_Tests;

end Synapse.Pipeline.Commands.Show.Tests;
