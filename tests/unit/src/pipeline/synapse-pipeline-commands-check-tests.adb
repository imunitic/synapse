with Ada.Strings.Fixed;

with AUnit.Assertions;

with Synapse.Pipeline.Commands.Usage;
with Synapse.Pipeline.Test_Environment;

package body Synapse.Pipeline.Commands.Check.Tests is

   use AUnit.Assertions;
   use Synapse.Pipeline.Test_Environment;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   --  Definitions and a skill, all sound, and the variables that find them.
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
         & " Test [Harness => Claude, Skill => ""test-feature""];"
         & " Review [System => Strict_Reviewer, Prompt => ""Review.""];"
         & " Review -> Develop [When => Changes_Requested, "
         & "Max_Iterations => 5]; }");
      F.Files.Add_File
        ("/cfg/synapse-pipeline/skills/test-feature/SKILL.md", "");
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
         "usage: synapse-pipeline check <pipeline>" & LF,
         "says how");
      Assert (Run (Env (F), Args ("A", "B")) = 2, "two");
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
         & "    skill test-feature  /cfg/synapse-pipeline/skills/test-feature"
         & LF
         & "  step Review  harness Codex" & LF
         & "    system Strict_Reviewer  /defs/Strict_Reviewer.synapse" & LF
         & "    agent Reviewer  /defs/Reviewer.synapse" & LF,
         "what it would run with: " & F.Base.Console.Out_Text);
      Assert (F.Base.Console.Err_Text = "", "nothing to complain of");
   end A_Sound_Pipeline_Is_Shown_With_Where_Things_Came_From;

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
        (T, It_Takes_Exactly_One_Pipeline_Name'Access,
         "It takes exactly one pipeline name");
      Register_Routine
        (T, A_Sound_Pipeline_Is_Shown_With_Where_Things_Came_From'Access,
         "A sound pipeline is shown with where things came from");
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
   end Register_Tests;

end Synapse.Pipeline.Commands.Check.Tests;
