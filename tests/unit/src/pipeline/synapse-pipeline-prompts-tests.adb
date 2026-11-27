with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.JSON;
with Synapse.Core.Text_Lists;

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

   --  The design's example: a required task_id and an optional
   --  instructions, each with its description.
   Two_Fields : constant String :=
     "{""fields"": {"
     & """task_id"": {""type"": ""string"", ""required"": true, "
     & """description"": ""The id of the Synapse Vault task note to "
     & "implement, such as synapse-067.""}, "
     & """instructions"": {""type"": ""string"", "
     & """description"": ""Extra requirements for this run only, in plain "
     & "words.""}}}";

   --  The input part of a prompt for Given under the declaration Declared.
   function Input_Text (Declared, Given : String) return String is
      Made : constant Part_Vectors.Vector :=
        Parts
          (Role            => "",
           Assignment      => "",
           Step            => "Implement",
           Initial_Input   => JSON.Parse (Given).Item,
           Previous_Output => JSON.Null_Value,
           Declared_Input  => JSON.Parse (Declared).Item);
   begin
      for Item of Made loop
         if Item.Kind = Input_Part then
            return To_String (Item.Text);
         end if;
      end loop;
      return "";
   end Input_Text;

   procedure A_Declared_Input_Is_Written_As_A_List_With_Descriptions
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Text : constant String :=
        Build
          (Role            => "",
           Assignment      => "",
           Step            => "Implement",
           Initial_Input   => JSON.Parse
             ("{""task_id"": ""synapse-067""}").Item,
           Previous_Output => JSON.Null_Value,
           Declared_Input  => JSON.Parse (Two_Fields).Item);
   begin
      Assert
        (Has (Text,
              LF & LF & "The pipeline was started with this input:" & LF
              & "- task_id: synapse-067" & LF
              & "  The id of the Synapse Vault task note to implement, "
              & "such as synapse-067." & LF
              & "- instructions: (not given)" & LF
              & "  Extra requirements for this run only, in plain words."
              & LF & LF),
         "the design's example, exactly");
      Assert
        (not Has (Text, "{""task_id"""),
         "the raw JSON is not written as well");
   end A_Declared_Input_Is_Written_As_A_List_With_Descriptions;

   procedure A_Field_Not_Given_Says_Not_Given
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Input_Text (Two_Fields, "{}") =
         "The pipeline was started with this input:" & LF
         & "- task_id: (not given)" & LF
         & "  The id of the Synapse Vault task note to implement, "
         & "such as synapse-067." & LF
         & "- instructions: (not given)" & LF
         & "  Extra requirements for this run only, in plain words.",
         "every declared field is listed, given or not");
      Assert
        (Has (Input_Text (Two_Fields, "null"), "- task_id: (not given)"),
         "no input at all lists the fields as not given");
   end A_Field_Not_Given_Says_Not_Given;

   procedure A_List_Is_One_Item_Per_Line (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
      Declared : constant String :=
        "{""fields"": {"
        & """tags"": {""type"": ""list"", ""items"": ""string"", "
        & """description"": ""Tags.""}, "
        & """files"": {""type"": ""list"", ""items"": {""fields"": "
        & "{""path"": {""type"": ""string"", ""description"": ""A path.""}}}, "
        & """description"": ""Files.""}}}";
   begin
      Assert
        (Input_Text
           (Declared,
            "{""tags"": [""a"", ""b c""], "
            & """files"": [{""path"": ""x.adb""}]}") =
         "The pipeline was started with this input:" & LF
         & "- tags:" & LF
         & "  - a" & LF
         & "  - b c" & LF
         & "  Tags." & LF
         & "- files:" & LF
         & "  - {""path"":""x.adb""}" & LF
         & "  Files.",
         "strings as they are, an item with fields as compact JSON");
   end A_List_Is_One_Item_Per_Line;

   procedure An_Integer_And_A_Boolean_Are_Written_As_JSON
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Declared : constant String :=
        "{""fields"": {"
        & """count"": {""type"": ""integer"", ""description"": ""How many.""},"
        & """dry"": {""type"": ""boolean"", ""description"": ""Dry run.""}}}";
   begin
      Assert
        (Input_Text (Declared, "{""count"": 3, ""dry"": false}") =
         "The pipeline was started with this input:" & LF
         & "- count: 3" & LF & "  How many." & LF
         & "- dry: false" & LF & "  Dry run.",
         "as JSON");
   end An_Integer_And_A_Boolean_Are_Written_As_JSON;

   procedure Without_A_Declaration_The_Input_Is_Raw_JSON
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert
        (Input_Text ("null", "{""task_id"": ""synapse-067""}") =
         "The pipeline was started with this input:" & LF
         & "{""task_id"":""synapse-067""}",
         "as before");
      Assert
        (Input_Text ("null", "null") = "",
         "no input and no declaration: no input part");
   end Without_A_Declaration_The_Input_Is_Raw_JSON;

   --  A step's Data: a required task note and an optional list of
   --  problems with fields; and outcomes, one of which has data.
   Step_Data : constant String :=
     "{""fields"": {"
     & """task_note"": {""type"": ""string"", ""required"": true, "
     & """description"": ""The task note's path.""}, "
     & """problems"": {""type"": ""list"", ""items"": {""fields"": {"
     & """file"": {""type"": ""string"", ""required"": true, "
     & """description"": ""The file.""}}}, "
     & """description"": ""What is wrong.""}}}";

   Outcomes_With_Data : constant String :=
     "{""Done"": ""It is done."", "
     & """Blocked"": {""description"": ""It could not be done."", "
     & """data"": {""blocker"": {""type"": ""string"", ""required"": true, "
     & """description"": ""Why.""}}}}";

   procedure The_Contract_Lists_The_Step_s_Data_Fields
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Text : constant String :=
        Build
          (Role            => "",
           Assignment      => "Do it.",
           Step            => "Implement",
           Initial_Input   => JSON.Null_Value,
           Previous_Output => JSON.Null_Value,
           Outcomes        =>
             JSON.Parse ("{""Done"": ""It is done.""}").Item,
           Data            => JSON.Parse (Step_Data).Item);
   begin
      Assert
        (Has (Text, "- Done: It is done." & LF & LF
                    & "Put these fields in data:" & LF
                    & "- task_note (string, required): The task note's path."
                    & LF
                    & "- problems (list of items with fields, optional): "
                    & "What is wrong." & LF
                    & "  - file (string, required): The file." & LF & LF
                    & "The pipeline decides"),
         "each field with its type, whether it is required and its "
         & "description, after the outcome words; got: " & Text);
      declare
         Free : constant String :=
           Build
             (Role            => "",
              Assignment      => "Do it.",
              Step            => "Implement",
              Initial_Input   => JSON.Null_Value,
              Previous_Output => JSON.Null_Value,
              Data            => JSON.Parse (Step_Data).Item);
      begin
         Assert
           (Has (Free, "and may be empty. The object has no other members."
                       & LF & LF & "Put these fields in data:" & LF
                       & "- task_note (string, required)"),
            "with no outcomes declared, the fields follow the contract");
      end;
   end The_Contract_Lists_The_Step_s_Data_Fields;

   procedure The_Contract_Lists_An_Outcome_s_Data_Under_Its_Word
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Text : constant String :=
        Build
          (Role            => "",
           Assignment      => "Do it.",
           Step            => "Implement",
           Initial_Input   => JSON.Null_Value,
           Previous_Output => JSON.Null_Value,
           Outcomes        => JSON.Parse (Outcomes_With_Data).Item);
   begin
      Assert
        (Has (Text, "- Done: It is done." & LF
                    & "- Blocked: It could not be done." & LF & LF
                    & "With Blocked, also put:" & LF
                    & "- blocker (string, required): Why." & LF & LF
                    & "The pipeline decides"),
         "the outcome's fields under its word; got: " & Text);
      Assert
        (not Has (Text, "Put these fields in data:"),
         "no step fields without the step's Data");
   end The_Contract_Lists_An_Outcome_s_Data_Under_Its_Word;

   procedure A_Retry_s_Contract_Names_The_Refused_Problems
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Refused : Synapse.Core.Text_Lists.Vector;
   begin
      Refused.Append
        (To_Unbounded_String ("data.task_note: required field is missing"));
      Refused.Append (To_Unbounded_String ("data.extra: is not declared"));
      declare
         Made : constant Part_Vectors.Vector :=
           Parts
             (Role            => "",
              Assignment      => "Do it.",
              Step            => "Implement",
              Initial_Input   => JSON.Null_Value,
              Previous_Output => JSON.Null_Value,
              Data            => JSON.Parse (Step_Data).Item,
              Refused         => Refused);
         Contract : constant String := To_String (Made.Last_Element.Text);
         Start    : constant String :=
           "Your last answer was refused:" & LF
           & "- data.task_note: required field is missing" & LF
           & "- data.extra: is not declared" & LF & LF
           & "When you are done, reply";
      begin
         Assert
           (Made.Last_Element.Kind = Contract_Part
            and then Contract'Length >= Start'Length
            and then Contract
                       (Contract'First .. Contract'First + Start'Length - 1)
                     = Start,
            "the contract starts with the problems; got: " & Contract);
      end;
   end A_Retry_s_Contract_Names_The_Refused_Problems;

   procedure Without_Data_Or_Refused_The_Prompt_Is_Unchanged
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Outcomes : constant JSON.Value :=
        JSON.Parse ("{""Done"": ""It is done."", ""Failed"": ""No.""}").Item;
      Text     : constant String :=
        Build
          (Role            => "",
           Assignment      => "Do it.",
           Step            => "Implement",
           Initial_Input   => JSON.Null_Value,
           Previous_Output => JSON.Null_Value,
           Outcomes        => Outcomes,
           Data            => JSON.Null_Value,
           Refused         => Synapse.Core.Text_Lists.Vectors.Empty_Vector);
      Free     : constant String :=
        Build
          (Role            => "",
           Assignment      => "Do it.",
           Step            => "Implement",
           Initial_Input   => JSON.Null_Value,
           Previous_Output => JSON.Null_Value);
   begin
      Assert
        (Has (Text, "- Done: It is done." & LF & "- Failed: No." & LF & LF
                    & "The pipeline decides which step runs next from it, "
                    & "so report what is true, not what would be "
                    & "convenient. `summary` says what you did, for a "
                    & "person. `data` is an object holding anything the next "
                    & "step needs, and may be empty. The object has no other "
                    & "members." & LF & LF)
         and then not Has (Text, "Put these fields")
         and then not Has (Text, "also put:")
         and then not Has (Text, "refused"),
         "the declared-outcome contract is as before; got: " & Text);
      Assert
        (Free'Length > 2
         and then Free (Free'Last - 2 .. Free'Last) = "." & LF & LF
         and then Has (Free, "The object has no other members." & LF & LF)
         and then not Has (Free, "Put these fields"),
         "the free-word contract is as before; got: " & Free);
   end Without_Data_Or_Refused_The_Prompt_Is_Unchanged;

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
      Register_Routine
        (T, A_Declared_Input_Is_Written_As_A_List_With_Descriptions'Access,
         "A declared input is written as a list with descriptions");
      Register_Routine
        (T, A_Field_Not_Given_Says_Not_Given'Access,
         "A field not given says (not given)");
      Register_Routine
        (T, A_List_Is_One_Item_Per_Line'Access, "A list is one item per line");
      Register_Routine
        (T, An_Integer_And_A_Boolean_Are_Written_As_JSON'Access,
         "An integer and a boolean are written as JSON");
      Register_Routine
        (T, Without_A_Declaration_The_Input_Is_Raw_JSON'Access,
         "Without a declaration the input is raw JSON as before");
      Register_Routine
        (T, The_Contract_Lists_The_Step_s_Data_Fields'Access,
         "The contract lists the step's data fields");
      Register_Routine
        (T, The_Contract_Lists_An_Outcome_s_Data_Under_Its_Word'Access,
         "The contract lists an outcome's data under its word");
      Register_Routine
        (T, A_Retry_s_Contract_Names_The_Refused_Problems'Access,
         "A retry's contract names the refused problems");
      Register_Routine
        (T, Without_Data_Or_Refused_The_Prompt_Is_Unchanged'Access,
         "Without Data or Refused the prompt is unchanged");
   end Register_Tests;

end Synapse.Pipeline.Prompts.Tests;
