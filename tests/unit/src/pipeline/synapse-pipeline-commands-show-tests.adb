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

   use type JSON.Kind;

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
         "usage: synapse-pipeline show <name> [--format json|text] "
         & "[--step <step> [--input <file>|-] [--interactive]]" & LF,
         "says how");
      Assert (Run (Env (F), Args ("A", "B")) = 2, "two");
      Assert (Run (Env (F), Args ("A", "--format", "yaml")) = 2, "a format");
      Assert (Run (Env (F), Args ("A", "--format")) = 2, "a format missing");
      Assert (Run (Env (F), Args ("A", "--bogus")) = 2, "an option");
      Assert (Run (Env (F), Args ("A", "--input", "x")) = 2, "input alone");
      Assert (Run (Env (F), Args ("A", "--step")) = 2, "a step missing");
      Assert
        (Run (Env (F), Args ("A", "--step", "B", "--step", "C")) = 2,
         "two steps");
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
         declare
            Steps : constant JSON.Value :=
              JSON.Member_Value
                (JSON.Element (JSON.Member_Value (System.Item, "used_by"), 1),
                 "steps");
         begin
            Assert
              (JSON.Length (Steps) = 1
               and then JSON.As_String (JSON.Element (Steps, 1)) = "Review",
               "and the step that names it");
         end;
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

   --  A prompt used by a step, a system and an agent, each by its name.
   procedure Add_A_Used_Prompt (F : in out Fixture) is
   begin
      F.Files.Add_File
        ("/defs/Careful.synapse",
         "Prompt Careful [Prompt => ""Be careful.""];");
      F.Files.Add_File
        ("/defs/Careful_Agent.synapse",
         "Agent Careful_Agent [Prompt => Careful];");
      F.Files.Add_File
        ("/defs/Careful_System.synapse",
         "System Careful_System [Harness => Claude, Prompt => Careful];");
      F.Files.Add_File
        ("/defs/Careful_Work.synapse",
         "Pipeline Careful_Work {"
         & " Plan [Harness => Claude, Prompt => Careful];"
         & " Build [Harness => Claude, Prompt => ""Build.""];"
         & " Check [Harness => Claude, Agent => Careful_Agent, "
         & "Prompt => Careful];"
         & " Plan -> Build; Build -> Check; }");
   end Add_A_Used_Prompt;

   procedure Show_Of_A_Prompt_Lists_What_Uses_It
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Add_A_Used_Prompt (F);
      Assert
        (Run (Env (F), Args ("Careful", "--format", "json")) = 0,
         "a prompt: " & F.Base.Console.Err_Text);
      declare
         Prompt : constant JSON.Parse_Result :=
           JSON.Parse (F.Base.Console.Out_Text);
      begin
         Assert
           (Prompt.Ok
            and then JSON.As_String (JSON.Member_Value (Prompt.Item, "format"))
                     = "synapse-pipeline-definition/v1"
            and then JSON.As_String (JSON.Member_Value (Prompt.Item, "kind"))
                     = "prompt"
            and then JSON.As_String (JSON.Member_Value (Prompt.Item, "file"))
                     = "/defs/Careful.synapse",
            "its format, kind and file");
         Assert
           (Users (Prompt.Item) =
            "agent:Careful_Agent system:Careful_System pipeline:Careful_Work ",
            "the agent, system and pipeline that use it: "
            & Users (Prompt.Item));
         declare
            Steps : constant JSON.Value :=
              JSON.Member_Value
                (JSON.Element (JSON.Member_Value (Prompt.Item, "used_by"), 3),
                 "steps");
         begin
            Assert
              (JSON.Length (Steps) = 2
               and then JSON.As_String (JSON.Element (Steps, 1)) = "Plan"
               and then JSON.As_String (JSON.Element (Steps, 2)) = "Check",
               "and the steps that name it");
         end;
      end;
      declare
         G : aliased Fixture;
      begin
         Set_Up (G);
         Add_A_Used_Prompt (G);
         Assert (Run (Env (G), Args ("Careful")) = 0, "in text");
         Assert
           (Has (G.Base.Console.Out_Text,
                 "prompt Careful  /defs/Careful.synapse" & LF)
            and then Has (G.Base.Console.Out_Text,
                          "  used by system Careful_System" & LF),
            "said in text: " & G.Base.Console.Out_Text);
      end;
   end Show_Of_A_Prompt_Lists_What_Uses_It;

   procedure Show_Step_Of_A_Step_With_A_Named_Prompt_Prints_Its_Text
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Add_A_Used_Prompt (F);
      Assert
        (Run (Env (F), Args ("Careful_Work", "--step", "Check")) = 0,
         "the step: " & F.Base.Console.Err_Text);
      Assert
        (Has (F.Base.Console.Out_Text, "Be careful."),
         "the prompt's text is in it, as role and as assignment: "
         & F.Base.Console.Out_Text);
      Assert
        (not Has (F.Base.Console.Out_Text, "SKILL.md")
         and then not Has (F.Base.Console.Out_Text, "/defs/Careful.synapse"),
         "no path is given in place of the text");
   end Show_Step_Of_A_Step_With_A_Named_Prompt_Prints_Its_Text;

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

   procedure A_Step_Is_Shown_As_The_Prompt_It_Starts_With
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      F.Files.Add_File ("/in.json", "{""issue"":7}");
      F.Files.Add_File
        ("/defs/Triage.synapse", "Prompt Triage [Prompt => ""Triage it.""];");
      F.Files.Add_File
        ("/defs/Prompted.synapse",
         "Pipeline Prompted { A [Harness => Claude, Prompt => Triage];"
         & " B [Harness => Claude, Prompt => ""Do B.""]; A -> B; }");
      Assert
        (Run (Env (F), Args ("Prompted", "--step", "A", "--input", "/in.json"))
         = 0,
         "the first step: " & F.Base.Console.Err_Text);
      declare
         Prompt : constant String := F.Base.Console.Out_Text;
      begin
         Assert (Has (Prompt, "Triage it."), "the prompt's text is in it");
         Assert (Has (Prompt, "step A of an automated pipeline"), "the step");
         Assert
           (Has (Prompt, "started with this input:" & LF & "{""issue"":7}"),
            "the input");
         Assert
           (not Has (Prompt, "reported this result"),
            "nothing came before the first step");
      end;
   end A_Step_Is_Shown_As_The_Prompt_It_Starts_With;

   procedure A_Prompt_Can_Be_Had_For_An_Interactive_Run
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
      G : aliased Fixture;
   begin
      Set_Up (F);
      Set_Up (G);
      Assert
        (Run (Env (F), Args ("Develop_Feature", "--step", "Develop")) = 0
         and then Has (F.Base.Console.Out_Text, "Nobody is available"),
         "the prompt of a headless run");
      Assert
        (Run
           (Env (G),
            Args ("Develop_Feature", "--step", "Develop", "--interactive"))
         = 0
         and then Has
                    (G.Base.Console.Out_Text,
                     "A person can answer in this terminal.")
         and then not Has (G.Base.Console.Out_Text, "Nobody is available"),
         "the prompt of an interactive one: " & G.Base.Console.Err_Text);
      Assert
        (Run (Env (F), Args ("Develop_Feature", "--interactive")) = 2
         and then Run
                    (Env (F),
                     Args ("Develop_Feature", "--step", "Develop",
                           "--interactive", "--interactive")) = 2,
         "the flag needs a step, and is given once");
   end A_Prompt_Can_Be_Had_For_An_Interactive_Run;

   procedure A_Later_Step_Has_A_Marked_Slot_For_What_Came_Before
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert
        (Run (Env (F), Args ("Develop_Feature", "--step", "Review")) = 0,
         "a later step: " & F.Base.Console.Err_Text);
      declare
         Prompt : constant String := F.Base.Console.Out_Text;
      begin
         Assert (Has (Prompt, "The step before yours reported this result:"),
                 "it says what is handed over");
         Assert (Has (Prompt, "<the result of the step before"), "the slot");
         Assert (Has (Prompt, "Review."), "its assignment");
         Assert
           (not Has (Prompt, "started with this input"),
            "no input was given");
      end;
   end A_Later_Step_Has_A_Marked_Slot_For_What_Came_Before;

   procedure A_Prompt_Can_Be_Had_As_Json_And_Bad_Asks_Are_Errors
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert
        (Run (Env (F),
              Args ("Develop_Feature", "--step", "Develop", "--format", "json"))
         = 0,
         "json");
      declare
         Parsed : constant JSON.Parse_Result :=
           JSON.Parse (F.Base.Console.Out_Text);
      begin
         Assert
           (Parsed.Ok
            and then JSON.As_String (JSON.Member_Value (Parsed.Item, "format"))
                     = "synapse-pipeline-prompt/v1"
            and then JSON.As_String (JSON.Member_Value (Parsed.Item, "step"))
                     = "Develop"
            and then Has
                       (JSON.As_String
                          (JSON.Member_Value (Parsed.Item, "prompt")),
                        "Implement."),
            "the prompt is one member of the document");
         declare
            Parts : constant JSON.Value :=
              JSON.Member_Value (Parsed.Item, "parts");
         begin
            Assert
              (JSON.Kind_Of (Parts) = JSON.JSON_Array
               and then JSON.Length (Parts) >= 3
               and then JSON.As_String
                          (JSON.Member_Value (JSON.Element (Parts, 1), "kind"))
                        = "assignment"
               and then JSON.As_Boolean
                          (JSON.Member_Value
                             (JSON.Element (Parts, 1), "authored")),
               "and so are its parts, the author's first");
            Assert
              (not JSON.As_Boolean
                     (JSON.Member_Value
                        (JSON.Element (Parts, JSON.Length (Parts)),
                         "authored"))
               and then JSON.As_String
                          (JSON.Member_Value
                             (JSON.Element (Parts, JSON.Length (Parts)),
                              "kind")) = "contract",
               "the last part is the contract, which the program adds");
         end;
      end;
      declare
         G : aliased Fixture;
      begin
         Set_Up (G);
         Assert
           (Run (Env (G), Args ("Develop_Feature", "--step", "Nope")) = 1
            and then G.Base.Console.Out_Text = ""
            and then Has (G.Base.Console.Err_Text, "has no step Nope"),
            "a step that is not there");
      end;
      declare
         G : aliased Fixture;
      begin
         Set_Up (G);
         Assert
           (Run (Env (G),
                 Args ("Develop_Feature", "--step", "Develop", "--input",
                       "/missing.json")) = 1
            and then G.Base.Console.Out_Text = "",
            "an input that cannot be read");
      end;
   end A_Prompt_Can_Be_Had_As_Json_And_Bad_Asks_Are_Errors;

   procedure Outcomes_Are_Reported_For_The_Step_That_Declares_Them
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      F.Files.Add_File
        ("/defs/Judged.synapse",
         "Pipeline Judged { A [Harness => Claude, Prompt => ""x"", Outcomes =>"
         & " {""Approved"": ""Fine."", ""Rejected"": ""Not fine.""}];"
         & " B [Harness => Claude, Prompt => ""y""]; A -> B [When => Approved];"
         & " }");
      Assert
        (Run (Env (F), Args ("Judged", "--format", "json")) = 0,
         "it can run: " & F.Base.Console.Err_Text);
      declare
         Parsed : constant JSON.Parse_Result :=
           JSON.Parse (F.Base.Console.Out_Text);
         Steps  : constant JSON.Value :=
           JSON.Member_Value (Parsed.Item, "steps");
         Given  : constant JSON.Value :=
           JSON.Member_Value (JSON.Element (Steps, 1), "outcomes");
      begin
         Assert
           (JSON.Length (Given) = 2
            and then JSON.As_String
                       (JSON.Member_Value (JSON.Element (Given, 2), "word")) =
                     "Rejected"
            and then JSON.As_String
                       (JSON.Member_Value
                          (JSON.Element (Given, 1), "meaning")) = "Fine.",
            "the words, in order, with their meanings");
         Assert
           (JSON.Kind_Of
              (JSON.Member_Value (JSON.Element (Steps, 2), "outcomes")) =
            JSON.JSON_Null,
            "null for a step that declares none");
      end;
      declare
         G : aliased Fixture;
      begin
         Set_Up (G);
         G.Files.Add_File
           ("/defs/Judged.synapse",
            "Pipeline Judged { A [Harness => Claude, Prompt => ""x"", "
            & "Outcomes => {""Approved"": ""Fine.""}]; }");
         Assert (Run (Env (G), Args ("Judged")) = 0, "text");
         Assert
           (Has (G.Base.Console.Out_Text, "    outcome Approved  Fine." & LF),
            "a line for each outcome");
      end;
   end Outcomes_Are_Reported_For_The_Step_That_Declares_Them;

   procedure A_Steps_Prompt_Lists_Its_Outcomes (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      F.Files.Add_File
        ("/defs/Judged.synapse",
         "Pipeline Judged { A [Harness => Claude, Prompt => ""x"", Outcomes =>"
         & " {""Approved"": ""Fine."", ""Rejected"": ""Not fine.""}]; }");
      Assert
        (Run (Env (F), Args ("Judged", "--step", "A")) = 0,
         "the prompt: " & F.Base.Console.Err_Text);
      Assert
        (Has (F.Base.Console.Out_Text,
              "- Approved: Fine." & LF & "- Rejected: Not fine." & LF)
         and then not Has (F.Base.Console.Out_Text, "<one word>"),
         "the words and meanings replace the free word");
   end A_Steps_Prompt_Lists_Its_Outcomes;

   --  A pipeline that declares its input: a required task id and optional
   --  instructions.
   procedure Add_A_Pipeline_With_Input (F : in out Fixture) is
   begin
      F.Files.Add_File
        ("/defs/Implement.synapse",
         "Pipeline Implement [Input => {""fields"": {"
         & """task_id"": {""type"": ""string"", ""required"": true,"
         & " ""pattern"": ""^[a-z]+-[0-9]+$"","
         & " ""description"": ""The task to implement.""},"
         & """instructions"": {""type"": ""string"","
         & " ""description"": ""Extra requirements.""}}}]"
         & " { A [Harness => Claude, Prompt => ""Do it.""]; }");
   end Add_A_Pipeline_With_Input;

   procedure Show_Prints_The_Declared_Input (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
      G : aliased Fixture;
   begin
      Set_Up (F);
      Add_A_Pipeline_With_Input (F);
      Assert
        (Run (Env (F), Args ("Implement")) = 0,
         "it can run: " & F.Base.Console.Err_Text);
      Assert
        (Has
           (F.Base.Console.Out_Text,
            "input:" & LF
            & "  task_id  string  required  The task to implement." & LF
            & "  instructions  string  optional  Extra requirements." & LF),
         "a line per field: " & F.Base.Console.Out_Text);
      Set_Up (G);
      Assert
        (Run (Env (G), Args ("Develop_Feature")) = 0
         and then not Has (G.Base.Console.Out_Text, "input:"),
         "nothing without a declaration");
   end Show_Prints_The_Declared_Input;

   procedure Show_Step_Writes_The_Input_As_A_List
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Add_A_Pipeline_With_Input (F);
      F.Files.Add_File ("/in.json", "{""task_id"": ""synapse-82""}");
      Assert
        (Run
           (Env (F),
            Args ("Implement", "--step", "A", "--input", "/in.json"))
         = 0,
         "the prompt: " & F.Base.Console.Err_Text);
      Assert
        (Has
           (F.Base.Console.Out_Text,
            "started with this input:" & LF
            & "- task_id: synapse-82" & LF
            & "  The task to implement." & LF
            & "- instructions: (not given)" & LF
            & "  Extra requirements."),
         "each field with its description: " & F.Base.Console.Out_Text);
   end Show_Step_Writes_The_Input_As_A_List;

   procedure Show_Step_Refuses_A_Bad_Input_With_Code_2
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Add_A_Pipeline_With_Input (F);
      F.Files.Add_File ("/in.json", "{""task"": ""x""}");
      Assert
        (Run
           (Env (F),
            Args ("Implement", "--step", "A", "--input", "/in.json"))
         = 2,
         "refused");
      Assert
        (F.Base.Console.Out_Text = "",
         "no prompt: " & F.Base.Console.Out_Text);
      Assert
        (Has
           (F.Base.Console.Err_Text,
            "error: input.task_id: required field is missing" & LF)
         and then Has
                    (F.Base.Console.Err_Text,
                     "error: input.task: unknown field" & LF),
         "every problem: " & F.Base.Console.Err_Text);
   end Show_Step_Refuses_A_Bad_Input_With_Code_2;

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
        (T,
         Show_Of_A_Prompt_Lists_What_Uses_It'Access,
         "Show of a prompt lists the steps, systems and agents that use it");
      Register_Routine
        (T, Show_Step_Of_A_Step_With_A_Named_Prompt_Prints_Its_Text'Access,
         "Show --step of a step with a named prompt prints the prompt's text");
      Register_Routine
        (T, An_Unused_Definition_Is_Used_By_Nothing'Access,
         "An unused definition is used by nothing");
      Register_Routine
        (T, A_Pipeline_Names_Its_Kind_And_File'Access,
         "A pipeline names its kind and file");
      Register_Routine
        (T, Outcomes_Are_Reported_For_The_Step_That_Declares_Them'Access,
         "Outcomes are reported for the step that declares them");
      Register_Routine
        (T, A_Steps_Prompt_Lists_Its_Outcomes'Access,
         "A step's prompt lists its outcomes");
      Register_Routine
        (T, A_Step_Is_Shown_As_The_Prompt_It_Starts_With'Access,
         "A step is shown as the prompt it starts with");
      Register_Routine
        (T, A_Prompt_Can_Be_Had_For_An_Interactive_Run'Access,
         "A prompt can be had for an interactive run");
      Register_Routine
        (T, A_Later_Step_Has_A_Marked_Slot_For_What_Came_Before'Access,
         "A later step has a marked slot for what came before");
      Register_Routine
        (T, A_Prompt_Can_Be_Had_As_Json_And_Bad_Asks_Are_Errors'Access,
         "A prompt can be had as JSON and bad asks are errors");
      Register_Routine
        (T, Show_Prints_The_Declared_Input'Access,
         "Show prints the declared input");
      Register_Routine
        (T, Show_Step_Writes_The_Input_As_A_List'Access,
         "Show --step writes the input as a list");
      Register_Routine
        (T, Show_Step_Refuses_A_Bad_Input_With_Code_2'Access,
         "Show --step refuses a bad input with code 2");
   end Register_Tests;

end Synapse.Pipeline.Commands.Show.Tests;
