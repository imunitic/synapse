with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Pipeline.Fake_Files;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Source_Errors;

package body Synapse.Pipeline.Validation.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   subtype Problem_List is Definitions.Problem_Vectors.Vector;

   --  A set of definitions every test starts from, all of them sound.
   procedure Add_Sound_Files (F : in out Fake_Files.Fake_Files) is
   begin
      F.Add_File
        ("/defs/Reviewer.synapse",
         "Agent Reviewer [Prompt => ""Review for correctness.""];");
      F.Add_File
        ("/defs/Developer.synapse",
         "Agent Developer [Skill => ""develop-feature""];");
      F.Add_File
        ("/defs/Strict_Reviewer.synapse",
         "System Strict_Reviewer [Agent => Reviewer, Harness => Claude, "
         & "Permissions => Read_Only];");
      F.Add_File
        ("/defs/Develop_Feature.synapse",
         "Pipeline Develop_Feature {"
         & " Develop [Agent => Developer, Harness => Claude];"
         & " Test [Prompt => ""Run the tests."", Harness => Claude, "
         & "Retries => 1];"
         & " Review [System => Strict_Reviewer, Harness => Codex];"
         & " Review -> Develop [When => Changes_Requested, "
         & "Max_Iterations => 5]; }");
      F.Add_File ("/skills/develop-feature/SKILL.md", "a skill");
   end Add_Sound_Files;

   function Defs_Roots return Search_Paths.Root_Vectors.Vector is
      Result : Search_Paths.Root_Vectors.Vector;
   begin
      Result.Append
        (Search_Paths.Root'(Path => To_Unbounded_String ("/defs"),
                            Required => True));
      return Result;
   end Defs_Roots;

   function Skill_Roots return Search_Paths.Root_Vectors.Vector is
      Result : Search_Paths.Root_Vectors.Vector;
   begin
      Result.Append
        (Search_Paths.Root'(Path => To_Unbounded_String ("/skills"),
                            Required => False));
      return Result;
   end Skill_Roots;

   function Problems_Of
     (F     : Fake_Files.Fake_Files; Name : String;
      Roots : Search_Paths.Root_Vectors.Vector := Skill_Roots;
      Default_Harness : Harnesses.Kind_Options.Option :=
        Harnesses.Kind_Options.Of_Value (Harnesses.Claude))
      return Problem_List
   is
      Report : constant Definitions.Load_Report :=
        Definitions.Load (F, Defs_Roots);
   begin
      return Validate (Report.Definitions, F, Roots, Name, Default_Harness);
   end Problems_Of;

   function Count_With (P : Problem_List; Message : String) return Natural is
      Count : Natural := 0;
   begin
      for E of P loop
         if Ada.Strings.Fixed.Index (To_String (E.Message), Message) > 0 then
            Count := Count + 1;
         end if;
      end loop;
      return Count;
   end Count_With;

   function Describe (P : Problem_List) return String is
      Text : Unbounded_String;
   begin
      for E of P loop
         Append (Text, " | " & Source_Errors.Image (E));
      end loop;
      return To_String (Text);
   end Describe;

   --  Exactly one problem says Message, in File.
   procedure Assert_Has
     (P : Problem_List; File, Message, Label : String) is
   begin
      Assert
        (Count_With (P, Message) = 1,
         Label & ": one problem says '" & Message & "' in" & Describe (P));
      for E of P loop
         if Ada.Strings.Fixed.Index (To_String (E.Message), Message) > 0 then
            Assert
              (To_String (E.File) = File,
               Label & ": in " & File & ", is "
               & Source_Errors.Image (E));
         end if;
      end loop;
   end Assert_Has;

   procedure Assert_Count (P : Problem_List; N : Natural; Label : String) is
   begin
      Assert
        (Natural (P.Length) = N,
         Label & ": expected" & Natural'Image (N) & " problems, have"
         & Describe (P));
   end Assert_Count;

   procedure A_Sound_Pipeline_Has_No_Problems (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      Add_Sound_Files (F);
      Assert_Count
        (Problems_Of (F, "Develop_Feature"), 0, "the design example");
   end A_Sound_Pipeline_Has_No_Problems;

   procedure The_Pipeline_Must_Exist_And_Be_A_Pipeline
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      Add_Sound_Files (F);
      F.Add_File ("/defs/Bad.synapse", "Pipeline Bad {");
      Assert_Has
        (Problems_Of (F, "Nope"), "", "there is no pipeline named 'Nope'",
         "unknown");
      Assert_Has
        (Problems_Of (F, "Reviewer"), "/defs/Reviewer.synapse",
         "'Reviewer' is an agent, not a pipeline", "an agent");
      Assert_Has
        (Problems_Of (F, "Bad"), "/defs/Bad.synapse", "expected '}'",
         "one that failed to load");
   end The_Pipeline_Must_Exist_And_Be_A_Pipeline;

   procedure Attributes_Are_Checked_In_Every_Definition
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      Add_Sound_Files (F);
      F.Add_File
        ("/defs/Odd_System.synapse", "System Odd_System [Colour => Red];");
      F.Add_File
        ("/defs/Odd.synapse",
         "Pipeline Odd { A [System => Odd_System, Prompt => ""x"", "
         & "Retries => ""2"", Retries => 3]; }");
      declare
         P : constant Problem_List := Problems_Of (F, "Odd");
      begin
         Assert_Count (P, 3, "three independent problems, all reported");
         Assert_Has
           (P, "/defs/Odd_System.synapse", "unknown attribute 'Colour'",
            "in the system");
         Assert_Has
           (P, "/defs/Odd.synapse", "'Retries' takes an integer",
            "in the pipeline");
         Assert_Has
           (P, "/defs/Odd.synapse", "'Retries' is given more than once",
            "a repeat");
      end;
   end Attributes_Are_Checked_In_Every_Definition;

   procedure Prompt_And_Skill_Are_Not_Both_Given (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      Add_Sound_Files (F);
      F.Add_File
        ("/defs/Both.synapse",
         "Pipeline Both { A [Prompt => ""x"", "
         & "Skill => ""develop-feature""]; }");
      Assert_Has
        (Problems_Of (F, "Both"), "/defs/Both.synapse",
         "'Prompt' and 'Skill' are both given", "both");
      Assert_Count (Problems_Of (F, "Both"), 1, "and nothing else");
   end Prompt_And_Skill_Are_Not_Both_Given;

   procedure References_Name_What_They_Should (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      Add_Sound_Files (F);
      F.Add_File
        ("/defs/Refs.synapse",
         "Pipeline Refs { A [System => Nothing, Prompt => ""x""];"
         & " B [System => Reviewer, Prompt => ""x""];"
         & " C [Agent => Strict_Reviewer]; }");
      declare
         P : constant Problem_List := Problems_Of (F, "Refs");
      begin
         Assert_Count (P, 3, "three bad references");
         Assert_Has
           (P, "/defs/Refs.synapse", "there is no system named 'Nothing'",
            "unknown");
         Assert_Has
           (P, "/defs/Refs.synapse", "'Reviewer' is an agent, not a system",
            "an agent for a system");
         Assert_Has
           (P, "/defs/Refs.synapse",
            "'Strict_Reviewer' is a system, not an agent",
            "a system for an agent");
      end;
   end References_Name_What_They_Should;

   procedure A_Reference_To_A_Failed_Definition_Says_Why
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      Add_Sound_Files (F);
      F.Add_File
        ("/defs/Broken_Agent.synapse", "Agent Broken_Agent [Prompt => ];");
      F.Add_File
        ("/defs/Uses_Broken.synapse",
         "Pipeline Uses_Broken { A [Agent => Broken_Agent]; }");
      declare
         P : constant Problem_List := Problems_Of (F, "Uses_Broken");
      begin
         Assert_Count (P, 1, "the failure, and no follow-on problems");
         Assert_Has
           (P, "/defs/Uses_Broken.synapse",
            "agent 'Broken_Agent' failed to load: "
            & "/defs/Broken_Agent.synapse:1:31: expected a value",
            "with its reason");
      end;
      Assert_Count
        (Problems_Of (F, "Develop_Feature"), 0,
         "a pipeline that does not need it is unaffected");
   end A_Reference_To_A_Failed_Definition_Says_Why;

   procedure A_System_Cannot_Refer_To_A_System (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      Add_Sound_Files (F);
      F.Add_File
        ("/defs/Nested.synapse", "System Nested [System => Strict_Reviewer];");
      F.Add_File
        ("/defs/Uses_Nested.synapse",
         "Pipeline Uses_Nested { A [System => Nested, Prompt => ""x""]; }");
      Assert_Has
        (Problems_Of (F, "Uses_Nested"), "/defs/Nested.synapse",
         "a system cannot refer to another system", "nested systems");
   end A_System_Cannot_Refer_To_A_System;

   procedure A_Step_Needs_Instructions_From_Somewhere
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      Add_Sound_Files (F);
      F.Add_File
        ("/defs/Empty_System.synapse",
         "System Empty_System [Harness => Claude];");
      F.Add_File
        ("/defs/Bare.synapse",
         "Pipeline Bare { A [Harness => Claude]; B [Agent => Reviewer];"
         & " C [System => Strict_Reviewer]; D [System => Empty_System]; }");
      declare
         P : constant Problem_List := Problems_Of (F, "Bare");
      begin
         Assert_Count (P, 2, "A and D have none");
         Assert_Has
           (P, "/defs/Bare.synapse", "step 'A' has no instructions",
            "nothing at all");
         Assert_Has
           (P, "/defs/Bare.synapse", "step 'D' has no instructions",
            "a system without any");
      end;
   end A_Step_Needs_Instructions_From_Somewhere;

   procedure Every_Step_Needs_A_Harness (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      Add_Sound_Files (F);
      F.Add_File
        ("/defs/No_Harness.synapse", "System No_Harness [Prompt => ""x""];");
      F.Add_File
        ("/defs/Harnessed.synapse",
         "Pipeline Harnessed { A [Prompt => ""x""];"
         & " B [Prompt => ""x"", Harness => Claude];"
         & " C [System => Strict_Reviewer];"
         & " D [System => No_Harness, Prompt => ""x""]; }");
      declare
         P : constant Problem_List :=
           Problems_Of
             (F, "Harnessed", Skill_Roots,
              Default_Harness => Harnesses.Kind_Options.None);
      begin
         Assert_Count (P, 2, "A and D have none");
         Assert_Has
           (P, "/defs/Harnessed.synapse", "step 'A' has no harness",
            "nothing at all");
         Assert_Has
           (P, "/defs/Harnessed.synapse", "step 'D' has no harness",
            "a system without one");
      end;
      Assert_Count
        (Problems_Of
           (F, "Harnessed", Skill_Roots,
            Default_Harness => Harnesses.Kind_Options.Of_Value
                                 (Harnesses.Codex)),
         0, "a default harness settles them");
      F.Add_File
        ("/defs/Misspelt.synapse",
         "Pipeline Misspelt { A [Prompt => ""x"", Harness => Cluade]; }");
      Assert_Has
        (Problems_Of (F, "Misspelt"), "/defs/Misspelt.synapse",
         "'Cluade' is not a harness; the harnesses are Claude, Codex, "
         & "Opencode",
         "a misspelt harness");
   end Every_Step_Needs_A_Harness;

   procedure A_Guard_Must_Be_A_Rule_That_Can_Run (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      Add_Sound_Files (F);
      F.Add_File
        ("/defs/Guarded.synapse",
         "Pipeline Guarded { A [Prompt => ""x""]; B [Prompt => ""x""];"
         & " A -> B [When => {""frob"": [1]}]; }");
      Assert_Has
        (Problems_Of (F, "Guarded"), "/defs/Guarded.synapse",
         "'When': 'frob' is not a JsonLogic operator", "an unknown operator");
   end A_Guard_Must_Be_A_Rule_That_Can_Run;

   procedure A_Shared_System_Is_Checked_Once (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      Add_Sound_Files (F);
      F.Add_File
        ("/defs/Odd_System.synapse", "System Odd_System [Colour => Red];");
      F.Add_File
        ("/defs/Twice.synapse",
         "Pipeline Twice { A [System => Odd_System, Prompt => ""x""];"
         & " B [System => Odd_System, Prompt => ""x""]; }");
      Assert_Count
        (Problems_Of (F, "Twice"), 1,
         "reported once however often it is used");
   end A_Shared_System_Is_Checked_Once;

   procedure Edges_Join_Steps_And_Cycles_Are_Bounded
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      Add_Sound_Files (F);
      F.Add_File
        ("/defs/Loops.synapse",
         "Pipeline Loops { A [Prompt => ""x""]; B [Prompt => ""x""];"
         & " A -> B; B -> A; B -> B [Max_Iterations => 2];"
         & " A -> Ghost; Phantom -> B; }");
      declare
         P : constant Problem_List := Problems_Of (F, "Loops");
      begin
         Assert_Count (P, 3, "an unbounded back-edge and two strangers");
         Assert_Has
           (P, "/defs/Loops.synapse",
            "the edge back to 'A' needs Max_Iterations", "an unbounded cycle");
         Assert_Has
           (P, "/defs/Loops.synapse", "there is no step named 'Ghost'",
            "an unknown target");
         Assert_Has
           (P, "/defs/Loops.synapse", "there is no step named 'Phantom'",
            "an unknown source");
      end;
   end Edges_Join_Steps_And_Cycles_Are_Bounded;

   procedure Steps_Are_Declared_Once_And_A_Pipeline_Has_One
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      Add_Sound_Files (F);
      F.Add_File
        ("/defs/Twin.synapse",
         "Pipeline Twin { A [Prompt => ""x""]; A [Prompt => ""y""]; }");
      F.Add_File ("/defs/Hollow.synapse", "Pipeline Hollow {}");
      Assert_Has
        (Problems_Of (F, "Twin"), "/defs/Twin.synapse",
         "step 'A' is already declared", "a repeated step");
      Assert_Has
        (Problems_Of (F, "Hollow"), "/defs/Hollow.synapse",
         "needs at least one step", "no steps");
   end Steps_Are_Declared_Once_And_A_Pipeline_Has_One;

   procedure Skills_Must_Exist (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      F : Fake_Files.Fake_Files;
   begin
      Add_Sound_Files (F);
      F.Add_File
        ("/defs/Skilled.synapse",
         "Pipeline Skilled { A [Skill => ""missing-skill""];"
         & " B [Skill => ""develop-feature""]; }");
      Assert_Has
        (Problems_Of (F, "Skilled"), "/defs/Skilled.synapse",
         "no skill named 'missing-skill' in /skills", "a missing skill");
      declare
         P : constant Problem_List :=
           Problems_Of (F, "Skilled", Search_Paths.Root_Vectors.Empty_Vector);
      begin
         Assert
           (Count_With (P, "any skill directory (none is set up)") = 2,
            "with no skill directory at all, neither skill is found:"
            & Describe (P));
      end;
   end Skills_Must_Exist;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Validation");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Sound_Pipeline_Has_No_Problems'Access,
         "A sound pipeline has no problems");
      Register_Routine
        (T, The_Pipeline_Must_Exist_And_Be_A_Pipeline'Access,
         "The pipeline must exist and be a pipeline");
      Register_Routine
        (T, Attributes_Are_Checked_In_Every_Definition'Access,
         "Attributes are checked in every definition");
      Register_Routine
        (T, Prompt_And_Skill_Are_Not_Both_Given'Access,
         "Prompt and Skill are not both given");
      Register_Routine
        (T, References_Name_What_They_Should'Access,
         "References name what they should");
      Register_Routine
        (T, A_Reference_To_A_Failed_Definition_Says_Why'Access,
         "A reference to a failed definition says why");
      Register_Routine
        (T, A_System_Cannot_Refer_To_A_System'Access,
         "A system cannot refer to a system");
      Register_Routine
        (T, A_Step_Needs_Instructions_From_Somewhere'Access,
         "A step needs instructions from somewhere");
      Register_Routine
        (T, Every_Step_Needs_A_Harness'Access,
         "Every step needs a harness");
      Register_Routine
        (T, A_Guard_Must_Be_A_Rule_That_Can_Run'Access,
         "A guard must be a rule that can run");
      Register_Routine
        (T, A_Shared_System_Is_Checked_Once'Access,
         "A shared system is checked once");
      Register_Routine
        (T, Edges_Join_Steps_And_Cycles_Are_Bounded'Access,
         "Edges join steps and cycles are bounded");
      Register_Routine
        (T, Steps_Are_Declared_Once_And_A_Pipeline_Has_One'Access,
         "Steps are declared once and a pipeline has one");
      Register_Routine
        (T, Skills_Must_Exist'Access, "Skills must exist");
   end Register_Tests;

end Synapse.Pipeline.Validation.Tests;
