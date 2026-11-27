with Ada.Strings.Fixed;

with AUnit.Assertions;

with Synapse.Pipeline.Commands.Usage;
with Synapse.Pipeline.Test_Environment;

package body Synapse.Pipeline.Commands.Check.Tests is

   use AUnit.Assertions;
   use Synapse.Pipeline.Test_Environment;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   --  Definitions, a prompt among them, all sound, and the variables that
   --  find them.
   procedure Set_Up (F : in out Fixture) is
   begin
      F.Base.Vars.Set ("SYNAPSE_PIPELINE_PATH", "/defs");
      F.Base.Vars.Set ("XDG_CONFIG_HOME", "/cfg");
      F.Files.Add_File
        ("/defs/Reviewer.synapse", "Agent Reviewer [Prompt => ""Review.""];");
      F.Files.Add_File
        ("/defs/Strict_Reviewer.synapse",
         "System Strict_Reviewer [Agent => Reviewer, Harness => Codex, "
         & "Outcomes => {""Approved"": ""Fine."", "
         & """Changes_Requested"": ""Not fine.""}];");
      F.Files.Add_File
        ("/defs/Develop_Feature.synapse",
         "Pipeline Develop_Feature {"
         & " Develop [Harness => Claude, Prompt => ""Implement.""];"
         & " Test [Harness => Claude, Prompt => Test_Feature];"
         & " Review [System => Strict_Reviewer, Prompt => ""Review.""];"
         & " Review -> Develop [When => Changes_Requested, "
         & "Max_Iterations => 5]; }");
      F.Files.Add_File
        ("/defs/Test_Feature.synapse",
         "Prompt Test_Feature [Prompt => ""Test the feature.""];");
   end Set_Up;

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   procedure It_Takes_Exactly_One_Pipeline_Name (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Assert (Run (Env (F), Args) = 2, "none");
      Assert
        (F.Base.Console.Err_Text =
         "usage: synapse-pipeline check <pipeline> [--interactive] "
         & "[--input <file>|-]" & LF,
         "says how");
      Assert (Run (Env (F), Args ("A", "B")) = 2, "two");
      Assert
        (Run (Env (F), Args ("--interactive")) = 2
         and then Run (Env (F), Args ("--interactive", "--interactive")) = 2,
         "the flag is not a pipeline");
   end It_Takes_Exactly_One_Pipeline_Name;

   procedure A_Sound_Pipeline_Is_Shown_With_Where_Things_Came_From
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Assert (Run (Env (F), Args ("Develop_Feature")) = 0, "it can run");
      Assert
        (F.Base.Console.Out_Text =
         "pipeline Develop_Feature  /defs/Develop_Feature.synapse" & LF
         & "  step Develop  harness Claude" & LF
         & "  step Test  harness Claude" & LF
         & "    prompt Test_Feature  /defs/Test_Feature.synapse" & LF
         & "  step Review  harness Codex" & LF
         & "    system Strict_Reviewer  /defs/Strict_Reviewer.synapse" & LF
         & "    agent Reviewer  /defs/Reviewer.synapse" & LF,
         "what it would run with: " & F.Base.Console.Out_Text);
      Assert (F.Base.Console.Err_Text = "", "nothing to complain of");
   end A_Sound_Pipeline_Is_Shown_With_Where_Things_Came_From;

   procedure Check_Lists_A_Prompt_The_Pipeline_Uses_With_Its_File
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      F.Files.Add_File
        ("/defs/Reviewer_Role.synapse",
         "Prompt Reviewer_Role [Prompt => ""You review code.""];");
      F.Files.Add_File
        ("/defs/Named_Reviewer.synapse",
         "Agent Named_Reviewer [Prompt => Reviewer_Role];");
      F.Files.Add_File
        ("/defs/Prompted.synapse",
         "Pipeline Prompted { A [Harness => Claude, "
         & "Agent => Named_Reviewer, Prompt => Test_Feature]; }");
      Assert
        (Run (Env (F), Args ("Prompted")) = 0
         and then F.Base.Console.Err_Text = "",
         "it can run: " & F.Base.Console.Err_Text);
      Assert
        (Has
           (F.Base.Console.Out_Text,
            "    prompt Test_Feature  /defs/Test_Feature.synapse" & LF)
         and then Has
                    (F.Base.Console.Out_Text,
                     "    agent Named_Reviewer  /defs/Named_Reviewer.synapse"
                     & LF)
         and then Has
                    (F.Base.Console.Out_Text,
                     "    prompt Reviewer_Role  /defs/Reviewer_Role.synapse"
                     & LF),
         "the step's prompt and the agent's, each with its file: "
         & F.Base.Console.Out_Text);
   end Check_Lists_A_Prompt_The_Pipeline_Uses_With_Its_File;

   procedure Interactive_Check_Passes_When_Every_Harness_Can
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
      G : aliased Fixture;
   begin
      Set_Up (F);
      Set_Up (G);
      Assert (Run (Env (F), Args ("Develop_Feature")) = 0, "plain");
      Assert
        (Run (Env (G), Args ("--interactive", "Develop_Feature")) = 0
         and then G.Base.Console.Err_Text = ""
         and then G.Base.Console.Out_Text = F.Base.Console.Out_Text,
         "the same description, and nothing wrong, with the flag first");
      Assert
        (Run (Env (G), Args ("Develop_Feature", "--interactive")) = 0,
         "and last");
      Assert
        (Run (Env (G), Args ("Nope", "--interactive")) = 1,
         "a pipeline that cannot run is still refused");
   end Interactive_Check_Passes_When_Every_Harness_Can;

   procedure A_Broken_Definition_Is_A_Warning_Unless_It_Is_Needed
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      F.Files.Add_File ("/defs/Broken.synapse", "Agent Broken [Prompt => ];");
      Assert
        (Run (Env (F), Args ("Develop_Feature")) = 0,
         "a pipeline that does not use it still runs");
      Assert
        (Has
           (F.Base.Console.Err_Text,
            "warning: /defs/Broken.synapse:1:25: expected a value"),
         "and the warning is given: " & F.Base.Console.Err_Text);
      declare
         F2 : aliased Fixture;
      begin
         Set_Up (F2);
         F2.Files.Add_File
           ("/defs/Broken.synapse", "Agent Broken [Prompt => ];");
         F2.Files.Add_File
           ("/defs/Uses_Broken.synapse",
            "Pipeline Uses_Broken "
            & "{ A [Harness => Claude, Agent => Broken]; }");
         Assert (Run (Env (F2), Args ("Uses_Broken")) = 1, "one that does");
         Assert
           (Has
              (F2.Base.Console.Err_Text,
               "error: /defs/Uses_Broken.synapse:1:55: agent 'Broken' failed "
               & "to load: /defs/Broken.synapse:1:25: expected a value")
            and then F2.Base.Console.Out_Text = "",
            "with the reason, and nothing on standard output: "
            & F2.Base.Console.Err_Text);
      end;
   end A_Broken_Definition_Is_A_Warning_Unless_It_Is_Needed;

   procedure Every_Problem_Is_Reported (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      F.Files.Add_File
        ("/defs/Many.synapse",
         "Pipeline Many { A [Harness => Claude, Prompt => ""x"", "
         & "Colour => Red]; B [Harness => Claude]; }");
      Assert (Run (Env (F), Args ("Many")) = 1, "it cannot run");
      Assert
        (Has (F.Base.Console.Err_Text, "unknown attribute 'Colour'")
         and then Has
                    (F.Base.Console.Err_Text, "step 'B' has no instructions"),
         "both problems: " & F.Base.Console.Err_Text);
      Assert (Run (Env (F), Args ("Nope")) = 1, "and an unknown pipeline");
   end Every_Problem_Is_Reported;

   procedure The_Default_Harness_Comes_From_The_Environment
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      F.Files.Add_File
        ("/defs/Bare.synapse", "Pipeline Bare { A [Prompt => ""x""]; }");
      Assert (Run (Env (F), Args ("Bare")) = 1, "without one it is refused");
      Assert
        (Has (F.Base.Console.Err_Text, "step 'A' has no harness"),
         "saying so");
      F.Base.Vars.Set ("SYNAPSE_PIPELINE_HARNESS", "Opencode");
      Assert (Run (Env (F), Args ("Bare")) = 0, "with one it runs");
      Assert
        (Has (F.Base.Console.Out_Text, "step A  harness Opencode"),
         "on that harness");
      F.Base.Vars.Set ("SYNAPSE_PIPELINE_HARNESS", "Opencod");
      Assert (Run (Env (F), Args ("Bare")) = 1, "a misspelt default");
      Assert
        (Has
           (F.Base.Console.Err_Text,
            "SYNAPSE_PIPELINE_HARNESS is 'Opencod', which is not a harness"),
         "is named: " & F.Base.Console.Err_Text);
   end The_Default_Harness_Comes_From_The_Environment;

   procedure Check_Is_In_The_Usage (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Has (Usage.Text, LF & "  check <pipeline>"), "listed");
   end Check_Is_In_The_Usage;

   procedure A_Step_That_Tests_Outcomes_It_Never_Declared_Is_A_Warning
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      F.Files.Add_File
        ("/defs/Free.synapse",
         "Pipeline Free { Review [Harness => Claude, Prompt => ""Review.""];"
         & " Fix [Harness => Claude, Prompt => ""Fix.""];"
         & " Review -> Fix [When => Changes_Requested]; }");
      Assert
        (Run (Env (F), Args ("Free")) = 0
         and then Has
                    (F.Base.Console.Err_Text,
                     "warning: /defs/Free.synapse:1:")
         and then Has
                    (F.Base.Console.Err_Text,
                     "step 'Review' has edges that test its outcome but "
                     & "declares no Outcomes"),
         "it still passes, and says so: " & F.Base.Console.Err_Text);
      declare
         G : aliased Fixture;
      begin
         Set_Up (G);
         G.Files.Add_File
           ("/defs/Declared.synapse",
            "Pipeline Declared { A [Harness => Claude, Prompt => ""x"", "
            & "Outcomes => {""Done"": ""Done.""}]; B [Harness => Claude, "
            & "Prompt => ""y""]; A -> B [When => Done]; }");
         Assert
           (Run (Env (G), Args ("Declared")) = 0
            and then G.Base.Console.Err_Text = "",
            "nothing to say when the outcomes are declared");
      end;
      declare
         G : aliased Fixture;
      begin
         Set_Up (G);
         G.Files.Add_File
           ("/defs/Misspelt.synapse",
            "Pipeline Misspelt { A [Harness => Claude, Prompt => ""x"", "
            & "Outcomes => {""Done"": ""Done.""}]; B [Harness => Claude, "
            & "Prompt => ""y""]; A -> B [When => Dnoe]; }");
         Assert
           (Run (Env (G), Args ("Misspelt")) = 1
            and then Has (G.Base.Console.Err_Text,
                          "does not declare the outcome 'Dnoe'")
            and then G.Base.Console.Out_Text = "",
            "a word the step does not declare is an error");
      end;
   end A_Step_That_Tests_Outcomes_It_Never_Declared_Is_A_Warning;

   --  A pipeline that declares one required task id and optional
   --  instructions.
   procedure Add_Declared (F : in out Fixture) is
   begin
      F.Files.Add_File
        ("/defs/Declared.synapse",
         "Pipeline Declared [Input => {""fields"": {"
         & """task_id"": {""type"": ""string"", ""required"": true, "
         & """pattern"": ""^[a-z]+-[0-9]+$"", "
         & """description"": ""The task.""}, "
         & """instructions"": {""type"": ""string"", "
         & """description"": ""Extra requirements.""}}}] "
         & "{ Develop [Harness => Claude, Prompt => ""Implement.""]; }");
   end Add_Declared;

   procedure Check_Input_Accepts_A_Valid_Input (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
      G : aliased Fixture;
   begin
      Set_Up (F);
      Add_Declared (F);
      Set_Up (G);
      Add_Declared (G);
      F.Files.Add_File ("/in.json", "{""task_id"": ""synapse-70""}");
      Assert
        (Run (Env (F), Args ("Declared", "--input", "/in.json")) = 0
         and then F.Base.Console.Err_Text = "",
         "accepted: " & F.Base.Console.Err_Text);
      Assert
        (Run (Env (G), Args ("Declared")) = 0
         and then F.Base.Console.Out_Text = G.Base.Console.Out_Text,
         "printed as without an input: " & F.Base.Console.Out_Text);
   end Check_Input_Accepts_A_Valid_Input;

   procedure Check_Input_Reports_Every_Problem_With_Code_2
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Add_Declared (F);
      F.Files.Add_File ("/in.json", "{""task"": ""x"", ""instructions"": 3}");
      Assert
        (Run (Env (F), Args ("Declared", "--input", "/in.json")) = 2,
         "refused with code 2: " & F.Base.Console.Err_Text);
      Assert
        (F.Base.Console.Out_Text = "",
         "nothing on standard output: " & F.Base.Console.Out_Text);
      Assert
        (Has (F.Base.Console.Err_Text, "error: input.task: unknown field" & LF)
         and then Has
                    (F.Base.Console.Err_Text,
                     "error: input.task_id: required field is missing" & LF)
         and then Has
                    (F.Base.Console.Err_Text,
                     "error: input.instructions: expected string" & LF),
         "every problem: " & F.Base.Console.Err_Text);
   end Check_Input_Reports_Every_Problem_With_Code_2;

   procedure Check_Input_Dash_Reads_Standard_Input
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
      G : aliased Fixture;
   begin
      Set_Up (F);
      Add_Declared (F);
      F.Base.Console.Set_Stdin ("{""task_id"": ""synapse-70""}");
      Assert
        (Run (Env (F), Args ("Declared", "--input", "-")) = 0,
         "accepted from standard input: " & F.Base.Console.Err_Text);
      Set_Up (G);
      Add_Declared (G);
      G.Base.Console.Set_Stdin ("{""task_id"": ""Not A Task""}");
      Assert
        (Run (Env (G), Args ("--input", "-", "Declared")) = 2
         and then Has
                    (G.Base.Console.Err_Text,
                     "error: input.task_id: does not match required pattern"),
         "refused from standard input: " & G.Base.Console.Err_Text);
   end Check_Input_Dash_Reads_Standard_Input;

   procedure Check_Input_Twice_Is_A_Usage_Error (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
   begin
      Set_Up (F);
      Add_Declared (F);
      F.Files.Add_File ("/in.json", "{""task_id"": ""synapse-70""}");
      Assert
        (Run
           (Env (F),
            Args ("Declared", "--input", "/in.json", "--input", "/in.json"))
         = 2
         and then Has
                    (F.Base.Console.Err_Text, "usage: synapse-pipeline check")
         and then F.Base.Console.Out_Text = "",
         "twice: " & F.Base.Console.Err_Text);
      Assert
        (Run (Env (F), Args ("Declared", "--input")) = 2
         and then F.Base.Console.Out_Text = "",
         "a missing path");
   end Check_Input_Twice_Is_A_Usage_Error;

   procedure Check_Input_On_A_Pipeline_Without_Input_Accepts_Anything
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : aliased Fixture;
      G : aliased Fixture;
   begin
      Set_Up (F);
      Set_Up (G);
      F.Files.Add_File ("/in.json", "{""anything"": [1, ""two""]}");
      Assert
        (Run (Env (F), Args ("Develop_Feature", "--input", "/in.json")) = 0
         and then F.Base.Console.Err_Text = "",
         "an object: " & F.Base.Console.Err_Text);
      G.Base.Console.Set_Stdin ("""just a sentence""");
      Assert
        (Run (Env (G), Args ("Develop_Feature", "--input", "-")) = 0
         and then G.Base.Console.Err_Text = "",
         "a string: " & G.Base.Console.Err_Text);
   end Check_Input_On_A_Pipeline_Without_Input_Accepts_Anything;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Commands.Check");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Step_That_Tests_Outcomes_It_Never_Declared_Is_A_Warning'Access,
         "A step that tests outcomes it never declared is a warning");
      Register_Routine
        (T, It_Takes_Exactly_One_Pipeline_Name'Access,
         "It takes exactly one pipeline name");
      Register_Routine
        (T, A_Sound_Pipeline_Is_Shown_With_Where_Things_Came_From'Access,
         "A sound pipeline is shown with where things came from");
      Register_Routine
        (T, Check_Lists_A_Prompt_The_Pipeline_Uses_With_Its_File'Access,
         "Check lists a prompt the pipeline uses with its file");
      Register_Routine
        (T,
         Interactive_Check_Passes_When_Every_Harness_Can'Access,
         "Interactive check passes when every harness can");
      Register_Routine
        (T, A_Broken_Definition_Is_A_Warning_Unless_It_Is_Needed'Access,
         "A broken definition is a warning unless it is needed");
      Register_Routine
        (T, Every_Problem_Is_Reported'Access, "Every problem is reported");
      Register_Routine
        (T, The_Default_Harness_Comes_From_The_Environment'Access,
         "The default harness comes from the environment");
      Register_Routine
        (T, Check_Is_In_The_Usage'Access, "Check is in the usage");
      Register_Routine
        (T, Check_Input_Accepts_A_Valid_Input'Access,
         "check --input accepts a valid input");
      Register_Routine
        (T, Check_Input_Reports_Every_Problem_With_Code_2'Access,
         "check --input reports every problem with code 2");
      Register_Routine
        (T, Check_Input_Dash_Reads_Standard_Input'Access,
         "check --input - reads standard input");
      Register_Routine
        (T, Check_Input_Twice_Is_A_Usage_Error'Access,
         "check --input twice is a usage error");
      Register_Routine
        (T, Check_Input_On_A_Pipeline_Without_Input_Accepts_Anything'Access,
         "check --input on a pipeline without Input accepts anything");
   end Register_Tests;

end Synapse.Pipeline.Commands.Check.Tests;
