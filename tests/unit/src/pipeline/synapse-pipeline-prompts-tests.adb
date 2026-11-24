with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.JSON;

package body Synapse.Pipeline.Prompts.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

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

   procedure The_Parts_Tell_What_The_Author_Wrote_From_What_Is_Added
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Made : constant Part_Vectors.Vector :=
        Parts
          (Role            => "You review.",
           Assignment      => "Review it.",
           Step            => "Review",
           Initial_Input   => JSON.Parse ("{""n"":1}").Item,
           Previous_Output => JSON.Parse ("{""outcome"":""Done""}").Item);
   begin
      Assert
        (Natural (Made.Length) = 6
         and then Made (1).Kind = Role_Part
         and then Made (2).Kind = Assignment_Part
         and then Made (3).Kind = Protocol_Part
         and then Made (4).Kind = Input_Part
         and then Made (5).Kind = Previous_Part
         and then Made (6).Kind = Contract_Part,
         "every part there is, in the order the prompt has them");
      Assert
        (To_String (Made (1).Text) = "You review."
         and then To_String (Made (2).Text) = "Review it.",
         "the first two are the author's words, as they are");
      Assert
        (Text_Of (Made) =
         Build
           (Role            => "You review.",
            Assignment      => "Review it.",
            Step            => "Review",
            Initial_Input   => JSON.Parse ("{""n"":1}").Item,
            Previous_Output => JSON.Parse ("{""outcome"":""Done""}").Item),
         "and the prompt is what the parts make");
      Assert
        (Natural
           (Parts
              (Role            => "",
               Assignment      => "Do it.",
               Step            => "A",
               Initial_Input   => JSON.Null_Value,
               Previous_Output => JSON.Null_Value).Length) = 3,
         "a part that is empty is left out: assignment, protocol, contract");
   end The_Parts_Tell_What_The_Author_Wrote_From_What_Is_Added;

   procedure An_Interactive_Prompt_Says_A_Person_Can_Answer
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Headless    : constant String :=
        Build
          (Role            => "You review.",
           Assignment      => "Review it.",
           Step            => "Review",
           Initial_Input   => JSON.Null_Value,
           Previous_Output => JSON.Null_Value);
      Interactive : constant String :=
        Build
          (Role            => "You review.",
           Assignment      => "Review it.",
           Step            => "Review",
           Initial_Input   => JSON.Null_Value,
           Previous_Output => JSON.Null_Value,
           Interactive     => True);
      Nobody      : constant String :=
        "Nobody is available to answer questions, so make reasonable "
        & "decisions and carry on.";
      Where       : constant Natural :=
        Ada.Strings.Fixed.Index (Headless, Nobody);
   begin
      Assert (Where > 0, "the headless prompt says nobody is available");
      Assert
        (not Has (Interactive, "Nobody is available")
         and then Has (Interactive, "A person can answer in this terminal."),
         "the interactive one says a person can answer");
      Assert
        (Interactive =
         Headless (Headless'First .. Where - 1)
         & "A person can answer in this terminal. When you need a decision "
         & "or a permission that you cannot reasonably make yourself, ask in "
         & "plain text and wait for the answer, and give the reply below "
         & "only when you are done, never with a question. If you are "
         & "stuck, cannot finish, or a command was denied, do not end with "
         & "an outcome that says so while the person can help: say what "
         & "stopped you and what you need, ask in plain text, wait, and "
         & "carry on from the answer. A message that tells you to stop and "
         & "explain to the user means: explain it here and wait. Report such "
         & "an outcome only when the person tells you to stop."
         & Headless (Where + Nobody'Length .. Headless'Last),
         "and everything else, the contract included, is the same");
   end An_Interactive_Prompt_Says_A_Person_Can_Answer;

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
        (T, The_Parts_Tell_What_The_Author_Wrote_From_What_Is_Added'Access,
         "The parts tell what the author wrote from what is added");
      Register_Routine
        (T, An_Interactive_Prompt_Says_A_Person_Can_Answer'Access,
         "An interactive prompt says a person can answer");
      Register_Routine
        (T, Declared_Outcomes_Replace_The_Free_Word'Access,
         "Declared outcomes replace the free word");
   end Register_Tests;

end Synapse.Pipeline.Prompts.Tests;
