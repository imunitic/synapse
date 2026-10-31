with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.JSON;
with Synapse.Core.Optional_Text;
with Synapse.Pipeline.Definitions;
with Synapse.Pipeline.Fake_Files;
with Synapse.Pipeline.Search_Paths;

package body Synapse.Pipeline.Resolution.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;
   use type Resolved.Instruction_Kind;
   use type Resolved.Origin_Kind;
   use type Harnesses.Harness_Kind;
   use type Synapse.Core.JSON.Value;

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
        ("/defs/Tester.synapse", "Agent Tester [Skill => ""test-skill""];");
      F.Add_File
        ("/defs/Base.synapse",
         "System Base [Agent => Reviewer, Harness => Codex, "
         & "Model => ""big-model"", Permissions => Read_Only, "
         & "Tools => [""Read"", ""Grep""], Timeout => ""10m"", Retries => 2, "
         & "Prompt => ""System task.""];");
      F.Add_File
        ("/defs/Plain.synapse",
         "Pipeline Plain { A [Harness => Claude, Prompt => ""do a"", "
         & "Model => Opus, Tools => [""Write""], Timeout => ""90s"", "
         & "Retries => 1]; }");
      F.Add_File
        ("/defs/Inherits.synapse",
         "Pipeline Inherits { A [System => Base];"
         & " B [System => Base, Harness => Claude, Retries => 0, "
         & "Timeout => ""1h"", Agent => Tester, Skill => ""own-skill""]; }");
      F.Add_File
        ("/defs/Edges.synapse",
         "Pipeline Edges { A [Harness => Claude, Prompt => ""x""];"
         & " B [Harness => Claude, Prompt => ""x""];"
         & " A -> B; B -> A [When => Changes_Requested, Max_Iterations => 3];"
         & " A -> A [When => {""=="": [{""var"": ""data.n""}, 1]}, "
         & "Max_Iterations => 2]; }");
      F.Add_File
        ("/defs/Bare.synapse", "Pipeline Bare { A [Prompt => ""x""]; }");
      F.Add_File
        ("/defs/Ghosts.synapse",
         "Pipeline Ghosts { A [Harness => Claude, Prompt => ""x"", "
         & "Agent => Nobody]; }");
      F.Add_File
        ("/defs/Misspelt.synapse",
         "Pipeline Misspelt { A [Harness => Cluade, Prompt => ""x""]; }");
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
     (Item : Resolved.Instruction; Kind : Resolved.Instruction_Kind;
      Text : String) return Boolean is
     (Item.Present and then Item.Kind = Kind
      and then To_String (Item.Text) = Text);

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
        (Is_Instruction (S.Assignment, Resolved.Prompt_Text, "do a"),
         "its own prompt");
      Assert (Text_Of (S.Model) = "Opus", "a model, from a name");
      Assert (Text_Of (S.Permissions) = "<none>", "no permissions");
      Assert
        (S.Tools.Found and then JSON.Length (S.Tools.Value) = 1, "its tools");
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
           (S.Role, Resolved.Prompt_Text, "You are a reviewer."),
         "the role, from the system's agent");
      Assert
        (Is_Instruction (S.Assignment, Resolved.Prompt_Text, "System task."),
         "the assignment, from the system");
      Assert
        (Text_Of (S.Model) = "big-model"
         and then Text_Of (S.Permissions) = "Read_Only",
         "model and permissions");
      Assert
        (S.Tools.Found and then JSON.Length (S.Tools.Value) = 2,
         "tools");
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
        (Is_Instruction (S.Role, Resolved.Skill_Name, "test-skill"),
         "its own agent, not the system's");
      Assert
        (Is_Instruction (S.Assignment, Resolved.Skill_Name, "own-skill"),
         "its own skill replaces the system's prompt whole");
      Assert
        (Text_Of (S.Model) = "big-model" and then S.Tools.Found,
         "and what it does not set still comes from the system");
      Assert
        (Natural (S.Origins.Length) = 2
         and then To_String (S.Origins (2).Name) = "Tester",
         "its own agent is the origin of its role");
   end A_Step_Overrides_Its_System;

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
      end;
   end What_Cannot_Be_Resolved_Is_A_Failure_Not_A_Raise;

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
   end Register_Tests;

end Synapse.Pipeline.Resolution.Tests;
