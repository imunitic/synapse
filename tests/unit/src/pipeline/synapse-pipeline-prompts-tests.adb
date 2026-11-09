with Ada.Strings.Fixed;

with AUnit.Assertions;

with Synapse.Core.JSON;

package body Synapse.Pipeline.Prompts.Tests is

   use AUnit.Assertions;

   package JSON renames Synapse.Core.JSON;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   LF : constant Character := Character'Val (10);

   function Has (Text, Part : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Part) > 0);

   procedure A_Prompt_Is_Role_Assignment_Input_And_The_Contract
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Text : constant String :=
        Build
          (Role            => "You review.",
           Assignment      => "Review it.",
           Step            => "Review",
           Initial_Input   => JSON.Parse ("{""n"":1}").Item,
           Previous_Output => JSON.Parse ("{""outcome"":""Done""}").Item);
   begin
      Assert
        (Has (Text, "You review." & LF & LF & "Review it." & LF & LF
                    & "You are running as the step Review"),
         "role, assignment, then who it is");
      Assert (Has (Text, "started with this input:" & LF & "{""n"":1}"),
              "the input");
      Assert
        (Has (Text, "reported this result:" & LF & "{""outcome"":""Done""}"),
         "what came before");
      Assert
        (Has (Text, """outcome"": ""<one word>""")
         and then Has (Text, "`outcome` is one word naming what actually "
                             & "happened, never empty."),
         "with no outcomes declared the outcome is a free word");
   end A_Prompt_Is_Role_Assignment_Input_And_The_Contract;

   procedure Declared_Outcomes_Replace_The_Free_Word
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Text : constant String :=
        Build
          (Role            => "",
           Assignment      => "Review it.",
           Step            => "Review",
           Initial_Input   => JSON.Null_Value,
           Previous_Output => JSON.Null_Value,
           Outcomes        =>
             JSON.Parse
               ("{""Approved"": ""It is fine."", ""Rejected"": ""It is not.""}")
               .Item);
   begin
      Assert
        (Has (Text, """outcome"": ""<one of the outcomes below>"""),
         "the shape says to choose");
      Assert
        (Has (Text, "- Approved: It is fine." & LF
                    & "- Rejected: It is not." & LF),
         "each word with what it means, in the order declared");
      Assert
        (not Has (Text, "<one word>")
         and then Has (Text, "`summary` says what you did, for a person."),
         "the free word is gone and the rest of the contract stays");
   end Declared_Outcomes_Replace_The_Free_Word;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Prompts");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, A_Prompt_Is_Role_Assignment_Input_And_The_Contract'Access,
         "A prompt is role, assignment, input and the contract");
      Register_Routine
        (T, Declared_Outcomes_Replace_The_Free_Word'Access,
         "Declared outcomes replace the free word");
   end Register_Tests;

end Synapse.Pipeline.Prompts.Tests;
