with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with AUnit.Assertions;

with Synapse.Core.JSON;

package body Synapse.Pipeline.Attributes.Tests is

   use AUnit.Assertions;
   use Ada.Strings.Unbounded;

   subtype Test_Cases_Class is AUnit.Test_Cases.Test_Case'Class;

   package JSON renames Synapse.Core.JSON;

   --  `Name => value` with the name at 1:1 and the value at 1:9.
   function Named (Name : String; Item : Syntax.Value)
      return Syntax.Attribute
   is
     (Name => (Name => To_Unbounded_String (Name), Line => 1, Column => 1),
      Item => Item);

   function A_Name (Text : String) return Syntax.Value is
     (Kind => Syntax.Name_Value, Line => 1, Column => 9,
      Name => To_Unbounded_String (Text));

   function A_String (Text : String) return Syntax.Value is
     (Kind => Syntax.String_Value, Line => 1, Column => 9,
      Text => To_Unbounded_String (Text));

   function An_Integer (N : Long_Long_Integer) return Syntax.Value is
     (Kind => Syntax.Integer_Value, Line => 1, Column => 9, Number => N);

   function A_JSON (Text : String) return Syntax.Value is
      Parsed : constant JSON.Parse_Result := JSON.Parse (Text);
   begin
      return (Kind => Syntax.JSON_Value, Line => 1, Column => 9,
              Source => To_Unbounded_String (Text), Json => Parsed.Item);
   end A_JSON;

   type Context_List is array (Positive range <>) of Context;

   --  Item must be fine as an attribute of Where.
   procedure Assert_Fine
     (Where : Context; Item : Syntax.Attribute; Label : String) is
   begin
      Assert (not Check (Where, Item).Found, Label & " is fine");
   end Assert_Fine;

   --  Item must be wrong in Where, with Message, at Column of line 1.
   procedure Assert_Wrong
     (Where : Context; Item : Syntax.Attribute; Column : Positive;
      Message : String; Label : String)
   is
      Found : constant Error_Options.Option := Check (Where, Item);
   begin
      Assert (Found.Found, Label & " is wrong");
      if Found.Found then
         Assert
           (Found.Value.Line = 1 and then Found.Value.Column = Column,
            Label & ": at " & Source_Errors.Image (Found.Value));
         Assert
           (Ada.Strings.Fixed.Index
              (To_String (Found.Value.Message), Message) > 0,
            Label & ": says '" & Message & "', says "
            & Source_Errors.Image (Found.Value));
      end if;
   end Assert_Wrong;

   procedure Every_Attribute_Is_Fine_Where_It_Belongs
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Fine (Step_Context, Named ("Agent", A_Name ("X")), "Agent");
      Assert_Fine (System_Context, Named ("Agent", A_Name ("X")), "Agent");
      Assert_Fine (Step_Context, Named ("System", A_Name ("X")), "System");
      for Where in Context loop
         if Where not in Edge_Context | Pipeline_Context then
            Assert_Fine (Where, Named ("Prompt", A_String ("do")), "Prompt");
         end if;
      end loop;
      Assert_Fine (Step_Context, Named ("Harness", A_Name ("Claude")), "H");
      Assert_Fine (Step_Context, Named ("Model", A_Name ("Opus")), "Model");
      Assert_Fine
        (Step_Context, Named ("Model", A_String ("claude-opus")), "Model");
      Assert_Fine
        (System_Context, Named ("Permissions", A_Name ("Read_Only")), "P");
      Assert_Fine (Step_Context, Named ("Timeout", A_String ("30m")), "T");
      Assert_Fine (Step_Context, Named ("Retries", An_Integer (0)), "Retries");
      Assert_Fine
        (Step_Context, Named ("Retries", An_Integer (100)), "Most retries");
      Assert_Fine
        (Step_Context, Named ("Timeout", A_String ("720h")), "30 days");
      Assert_Fine (Edge_Context, Named ("When", A_Name ("Done")), "When");
      Assert_Fine
        (Edge_Context, Named ("When", A_JSON ("{""=="": [1, 1]}")), "When");
      Assert_Fine
        (Edge_Context, Named ("Max_Iterations", An_Integer (3)), "Max");
   end Every_Attribute_Is_Fine_Where_It_Belongs;

   procedure An_Attribute_Must_Exist_And_Belong (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Wrong
        (Step_Context, Named ("Colour", A_Name ("Red")), 1,
         "unknown attribute 'Colour'", "an unknown attribute");
      Assert_Wrong
        (Step_Context, Named ("Tools", A_JSON ("[""Read""]")), 1,
         "unknown attribute 'Tools'", "a tool list is not an attribute");
      Assert_Wrong
        (Step_Context, Named ("When", A_Name ("Done")), 1,
         "'When' is not an attribute of a step", "a guard on a step");
      Assert_Wrong
        (Edge_Context, Named ("Retries", An_Integer (1)), 1,
         "'Retries' is not an attribute of an edge", "retries on an edge");
      Assert_Wrong
        (Agent_Context, Named ("Harness", A_Name ("Claude")), 1,
         "'Harness' is not an attribute of an agent", "harness on an agent");
      Assert_Wrong
        (System_Context, Named ("System", A_Name ("Other")), 1,
         "a system cannot refer to another system", "a system of a system");
   end An_Attribute_Must_Exist_And_Belong;

   procedure A_Value_Must_Be_What_The_Attribute_Takes
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Wrong
        (Step_Context, Named ("Retries", A_String ("2")), 9,
         "'Retries' takes an integer, not a string", "a string for a number");
      Assert_Wrong
        (Step_Context, Named ("Agent", A_String ("X")), 9,
         "'Agent' takes a name, not a string", "a string for a name");
      Assert_Wrong
        (Prompt_Context, Named ("Prompt", A_Name ("X")), 9,
         "'Prompt' takes a string, not a name", "a name for a string");
      Assert_Wrong
        (Step_Context, Named ("Model", An_Integer (4)), 9,
         "'Model' takes a name or a string", "an integer for a model");
      Assert_Wrong
        (Edge_Context, Named ("When", A_String ("x")), 9,
         "'When' takes a name or a JSON value", "a string guard");
   end A_Value_Must_Be_What_The_Attribute_Takes;

   procedure Some_Values_Are_Checked_Further (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert_Wrong
        (Step_Context, Named ("Prompt", A_String ("")), 9, "'Prompt' is empty",
         "an empty prompt");
      Assert_Wrong
        (Step_Context, Named ("Harness", A_Name ("Cluade")), 9,
         "'Cluade' is not a harness", "a misspelt harness");
      Assert_Wrong
        (System_Context, Named ("Harness", A_Name ("claude")), 9,
         "is not a harness; the harnesses are Claude, Codex, Opencode",
         "harness names are exact");
      Assert_Wrong
        (Step_Context, Named ("Timeout", A_String ("soon")), 9,
         "a number and a unit", "a bad timeout");
      Assert_Wrong
        (Step_Context, Named ("Timeout", A_String ("721h")), 9,
         "at most 30 days", "a timeout past 30 days");
      Assert_Wrong
        (Step_Context, Named ("Timeout", A_String ("1000000h")), 9,
         "at most 30 days", "a million hours");
      Assert_Wrong
        (Step_Context, Named ("Retries", An_Integer (101)), 9,
         "'Retries' is at most 100", "too many retries");
      Assert_Wrong
        (Step_Context, Named ("Retries", An_Integer (2_147_483_647)), 9,
         "'Retries' is at most 100", "retries up to the integer limit");
      Assert_Wrong
        (Step_Context, Named ("Retries", An_Integer (99_999_999_999)), 9,
         "'Retries' is at most 100", "retries past the integer limit");
      Assert_Wrong
        (Edge_Context, Named ("Max_Iterations", An_Integer (0)), 9,
         "at least 1", "no iterations");
      Assert_Wrong
        (Edge_Context, Named ("Max_Iterations", An_Integer (101)), 9,
         "'Max_Iterations' is at most 100", "too many iterations");
      Assert_Wrong
        (Edge_Context, Named ("Max_Iterations", An_Integer (99_999_999_999)),
         9, "'Max_Iterations' is at most 100",
         "iterations past the integer limit");
      Assert_Wrong
        (Edge_Context, Named ("When", A_JSON ("{""frob"": [1]}")), 9,
         "'frob' is not a JsonLogic operator", "an unknown guard operator");
      Assert_Wrong
        (Edge_Context, Named ("When", A_JSON ("[1, 2]")), 9,
         "a guard is a single JsonLogic rule", "a list for a guard");
   end Some_Values_Are_Checked_Further;

   procedure Is_Known_Knows_The_Twelve (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Is_Known ("Agent") and then Is_Known ("System"), "Agent System");
      Assert
        (Is_Known ("Prompt") and then Is_Known ("Description"),
         "Prompt Description");
      Assert
        (Is_Known ("Harness") and then Is_Known ("Model"), "Harness Model");
      Assert
        (Is_Known ("Permissions") and then not Is_Known ("Tools"),
         "Permissions, and no Tools");
      Assert
        (Is_Known ("Timeout") and then Is_Known ("Retries"),
         "Timeout Retries");
      Assert
        (Is_Known ("When") and then Is_Known ("Max_Iterations"),
         "When Max_Iterations");
      Assert (Is_Known ("Outcomes"), "Outcomes");
      Assert
        (not Is_Known ("Colour") and then not Is_Known ("")
         and then not Is_Known ("agent") and then not Is_Known ("Skill"),
         "and only those, spelled so");
   end Is_Known_Knows_The_Twelve;

   procedure Outcomes_Belong_To_A_Step_Or_A_System
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Declared : constant Syntax.Value :=
        A_JSON ("{""Done"": ""It is done."", ""Blocked"": ""Cannot go on.""}");
   begin
      Assert_Fine (Step_Context, Named ("Outcomes", Declared), "a step");
      Assert_Fine (System_Context, Named ("Outcomes", Declared), "a system");
      Assert_Wrong
        (Agent_Context, Named ("Outcomes", Declared), 1,
         "'Outcomes' is not an attribute of an agent", "an agent");
      Assert_Wrong
        (Edge_Context, Named ("Outcomes", Declared), 1,
         "'Outcomes' is not an attribute of an edge", "an edge");
      Assert_Wrong
        (Step_Context, Named ("Outcomes", A_String ("Done")), 9,
         "'Outcomes' takes a JSON value, not a string", "not JSON");
   end Outcomes_Belong_To_A_Step_Or_A_System;

   procedure Outcomes_Are_Words_With_A_Line_Of_Meaning
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);

      procedure Wrong (Text, Message, Label : String) is
      begin
         Assert_Wrong
           (Step_Context, Named ("Outcomes", A_JSON (Text)), 9, Message,
            Label);
      end Wrong;
   begin
      Wrong ("[""Done""]", "is an object from each outcome", "a list");
      Wrong ("{}", "declares no outcome", "an empty object");
      Wrong ("{""Do ne"": ""x""}", "'Do ne' is not an outcome", "a space");
      Wrong ("{""1st"": ""x""}", "'1st' is not an outcome", "a digit first");
      Wrong ("{""End"": ""x""}", "'End' is not an outcome", "a keyword");
      Wrong ("{""Done"": 3}", "the meaning of 'Done' is one line", "a number");
      Wrong ("{""Done"": """"}", "the meaning of 'Done' is one line", "empty");
      Wrong
        ("{""Done"": ""a\nb""}", "the meaning of 'Done' is one line",
         "two lines");
   end Outcomes_Are_Words_With_A_Line_Of_Meaning;

   procedure Prompt_Takes_A_Name_On_A_Step_A_System_And_An_Agent
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      for Where of Context_List'[Step_Context, System_Context, Agent_Context]
      loop
         Assert_Fine
           (Where, Named ("Prompt", A_Name ("Test_Feature")), "a name");
         Assert_Fine (Where, Named ("Prompt", A_String ("do")), "a string");
      end loop;
      Assert_Wrong
        (Step_Context, Named ("Prompt", A_String ("")), 9, "'Prompt' is empty",
         "an empty string on a step");
      Assert_Wrong
        (Step_Context, Named ("Prompt", An_Integer (1)), 9,
         "'Prompt' takes a name or a string, not an integer", "an integer");
   end Prompt_Takes_A_Name_On_A_Step_A_System_And_An_Agent;

   procedure Prompt_On_A_Prompt_Takes_A_String_Only
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Fine
        (Prompt_Context, Named ("Prompt", A_String ("Test it.")), "a string");
      Assert_Wrong
        (Prompt_Context, Named ("Prompt", A_Name ("Other")), 9,
         "'Prompt' takes a string, not a name", "a name");
      Assert_Wrong
        (Prompt_Context, Named ("Prompt", A_String ("")), 9,
         "'Prompt' is empty", "an empty string");
   end Prompt_On_A_Prompt_Takes_A_String_Only;

   procedure Description_Is_Accepted_On_Every_Definition
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      for Where of Context_List'
        [Pipeline_Context, System_Context, Agent_Context, Prompt_Context]
      loop
         Assert_Fine
           (Where, Named ("Description", A_String ("What it is for.")),
            "a description");
         Assert_Fine
           (Where, Named ("Description", A_String ("")), "an empty one");
      end loop;
   end Description_Is_Accepted_On_Every_Definition;

   procedure Description_Is_Not_An_Attribute_Of_A_Step_Or_An_Edge
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Wrong
        (Step_Context, Named ("Description", A_String ("x")), 1,
         "'Description' is not an attribute of a step", "a step");
      Assert_Wrong
        (Edge_Context, Named ("Description", A_String ("x")), 1,
         "'Description' is not an attribute of an edge", "an edge");
   end Description_Is_Not_An_Attribute_Of_A_Step_Or_An_Edge;

   procedure Description_Takes_A_String_Not_A_Name
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Wrong
        (Agent_Context, Named ("Description", A_Name ("Reviewer")), 9,
         "'Description' takes a string, not a name", "a name");
   end Description_Takes_A_String_Not_A_Name;

   procedure Skill_Is_An_Unknown_Attribute (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      for Where in Context loop
         Assert_Wrong
           (Where, Named ("Skill", A_String ("test-feature")), 1,
            "unknown attribute 'Skill'", "Skill");
      end loop;
   end Skill_Is_An_Unknown_Attribute;

   procedure Harness_Is_Not_An_Attribute_Of_A_Prompt_Or_A_Pipeline
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Wrong
        (Prompt_Context, Named ("Harness", A_Name ("Claude")), 1,
         "'Harness' is not an attribute of a prompt", "a prompt");
      Assert_Wrong
        (Pipeline_Context, Named ("Harness", A_Name ("Claude")), 1,
         "'Harness' is not an attribute of a pipeline", "a pipeline");
      Assert_Wrong
        (Pipeline_Context, Named ("Prompt", A_String ("x")), 1,
         "'Prompt' is not an attribute of a pipeline", "Prompt on a pipeline");
   end Harness_Is_Not_An_Attribute_Of_A_Prompt_Or_A_Pipeline;

   --  A declaration with one required string field, valid as an Input.
   Valid_Input : constant String :=
     "{""fields"": {""task_id"": {""type"": ""string"", ""required"": true, "
     & """description"": ""The task to work on.""}}}";

   procedure Input_Is_Accepted_On_A_Pipeline (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Is_Known ("Input"), "Input is known");
      Assert_Fine
        (Pipeline_Context, Named ("Input", A_JSON (Valid_Input)),
         "a declaration");
   end Input_Is_Accepted_On_A_Pipeline;

   procedure Input_Is_Not_An_Attribute_Elsewhere
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Wrong
        (Step_Context, Named ("Input", A_JSON (Valid_Input)), 1,
         "'Input' is not an attribute of a step", "a step");
      Assert_Wrong
        (System_Context, Named ("Input", A_JSON (Valid_Input)), 1,
         "'Input' is not an attribute of a system", "a system");
      Assert_Wrong
        (Agent_Context, Named ("Input", A_JSON (Valid_Input)), 1,
         "'Input' is not an attribute of an agent", "an agent");
      Assert_Wrong
        (Prompt_Context, Named ("Input", A_JSON (Valid_Input)), 1,
         "'Input' is not an attribute of a prompt", "a prompt");
      Assert_Wrong
        (Edge_Context, Named ("Input", A_JSON (Valid_Input)), 1,
         "'Input' is not an attribute of an edge", "an edge");
   end Input_Is_Not_An_Attribute_Elsewhere;

   procedure Input_Takes_A_JSON_Value_Not_A_String
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Wrong
        (Pipeline_Context, Named ("Input", A_String ("task_id")), 9,
         "'Input' takes a JSON value, not a string", "a string");
      Assert_Wrong
        (Pipeline_Context, Named ("Input", A_Name ("Task")), 9,
         "'Input' takes a JSON value, not a name", "a name");
   end Input_Takes_A_JSON_Value_Not_A_String;

   procedure A_Declaration_Without_A_Description_Is_An_Error_At_Input
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert_Wrong
        (Pipeline_Context,
         Named
           ("Input",
            A_JSON
              ("{""fields"": {""task_id"": {""type"": ""string""}}}")),
         9, "'Input': input.fields.task_id.description: required string "
         & "is missing", "no description");
   end A_Declaration_Without_A_Description_Is_An_Error_At_Input;

   procedure A_Declaration_Problem_Is_Reported_With_Its_Path
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Declared : constant Syntax.Attribute :=
        Named
          ("Input",
           A_JSON
             ("{""fields"": {""files"": {""type"": ""list"", "
              & """description"": ""The files."", ""items"": {""fields"": "
              & "{""path"": {""type"": ""string"", ""mutable"": true, "
              & """description"": ""A path.""}}}}, "
              & """task_id"": {""type"": ""any""}}}"));
   begin
      Assert_Wrong
        (Pipeline_Context, Declared, 9,
         "input.fields.files.items.fields.path.mutable: not allowed in an "
         & "input", "a nested path");
      Assert_Wrong
        (Pipeline_Context, Declared, 9,
         "; input.fields.task_id.", "every problem, joined");
      Assert_Wrong
        (Pipeline_Context, Declared, 9,
         "input.fields.task_id.type: any is not allowed in an input",
         "the second field");
   end A_Declaration_Problem_Is_Reported_With_Its_Path;

   procedure Data_Is_Accepted_On_A_Step_And_A_System
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
   begin
      Assert (Is_Known ("Data"), "Data is known");
      Assert_Fine
        (Step_Context, Named ("Data", A_JSON (Valid_Input)), "on a step");
      Assert_Fine
        (System_Context, Named ("Data", A_JSON (Valid_Input)),
         "on a system");
      Assert_Wrong
        (Step_Context, Named ("Data", A_String ("x")), 9,
         "'Data' takes a JSON value, not a string", "a string");
   end Data_Is_Accepted_On_A_Step_And_A_System;

   procedure Data_Is_Refused_On_A_Pipeline (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert_Wrong
        (Pipeline_Context, Named ("Data", A_JSON (Valid_Input)), 1,
         "'Data' is not an attribute of a pipeline", "a pipeline");
      Assert_Wrong
        (Edge_Context, Named ("Data", A_JSON (Valid_Input)), 1,
         "'Data' is not an attribute of an edge", "an edge");
      Assert_Wrong
        (Agent_Context, Named ("Data", A_JSON (Valid_Input)), 1,
         "'Data' is not an attribute of an agent", "an agent");
   end Data_Is_Refused_On_A_Pipeline;

   procedure Carry_Is_An_Unknown_Attribute (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (not Is_Known ("Carry"), "Carry is not known");
      for Where in Context loop
         Assert_Wrong
           (Where, Named ("Carry", A_JSON (Valid_Input)), 1,
            "unknown attribute 'Carry'", Context'Image (Where));
      end loop;
   end Carry_Is_An_Unknown_Attribute;

   --  Two fields, both without a description.
   Two_Bad_Fields : constant String :=
     "{""fields"": {""x"": {""type"": ""string""}, "
     & """y"": {""type"": ""integer""}}}";

   procedure Data_That_Is_Not_A_Valid_Declaration_Lists_Every_Problem
     (T : in out Test_Cases_Class)
   is
      pragma Unreferenced (T);
      Declared : constant Syntax.Attribute :=
        Named ("Data", A_JSON (Two_Bad_Fields));
   begin
      Assert_Wrong
        (Step_Context, Declared, 9,
         "'Data': Data.fields.x.description: required string is missing",
         "the first problem, under Data");
      Assert_Wrong
        (Step_Context, Declared, 9,
         "; Data.fields.y.description: required string is missing",
         "the second problem, joined");
   end Data_That_Is_Not_A_Valid_Declaration_Lists_Every_Problem;

   overriding
   function Name (T : Test_Case) return AUnit.Message_String is
      pragma Unreferenced (T);
   begin
      return AUnit.Format ("Synapse.Pipeline.Attributes");
   end Name;

   overriding
   procedure Register_Tests (T : in out Test_Case) is
      use AUnit.Test_Cases.Registration;
   begin
      Register_Routine
        (T, Every_Attribute_Is_Fine_Where_It_Belongs'Access,
         "Every attribute is fine where it belongs");
      Register_Routine
        (T, An_Attribute_Must_Exist_And_Belong'Access,
         "An attribute must exist and belong");
      Register_Routine
        (T, A_Value_Must_Be_What_The_Attribute_Takes'Access,
         "A value must be what the attribute takes");
      Register_Routine
        (T, Some_Values_Are_Checked_Further'Access,
         "Some values are checked further");
      Register_Routine
        (T, Is_Known_Knows_The_Twelve'Access, "Is_Known knows the twelve");
      Register_Routine
        (T, Outcomes_Belong_To_A_Step_Or_A_System'Access,
         "Outcomes belong to a step or a system");
      Register_Routine
        (T, Outcomes_Are_Words_With_A_Line_Of_Meaning'Access,
         "Outcomes are words with a line of meaning");
      Register_Routine
        (T, Prompt_Takes_A_Name_On_A_Step_A_System_And_An_Agent'Access,
         "Prompt takes a name on a step, a system and an agent");
      Register_Routine
        (T, Prompt_On_A_Prompt_Takes_A_String_Only'Access,
         "Prompt on a prompt takes a string only");
      Register_Routine
        (T, Description_Is_Accepted_On_Every_Definition'Access,
         "Description is accepted on a pipeline, a system, an agent and a "
         & "prompt");
      Register_Routine
        (T, Description_Is_Not_An_Attribute_Of_A_Step_Or_An_Edge'Access,
         "Description is not an attribute of a step or an edge");
      Register_Routine
        (T, Description_Takes_A_String_Not_A_Name'Access,
         "Description takes a string, not a name");
      Register_Routine
        (T, Skill_Is_An_Unknown_Attribute'Access,
         "Skill is an unknown attribute");
      Register_Routine
        (T, Harness_Is_Not_An_Attribute_Of_A_Prompt_Or_A_Pipeline'Access,
         "Harness is not an attribute of a prompt or a pipeline");
      Register_Routine
        (T, Input_Is_Accepted_On_A_Pipeline'Access,
         "Input is accepted on a pipeline");
      Register_Routine
        (T, Input_Is_Not_An_Attribute_Elsewhere'Access,
         "Input is not an attribute of a step, a system, an agent, a prompt "
         & "or an edge");
      Register_Routine
        (T, Input_Takes_A_JSON_Value_Not_A_String'Access,
         "Input takes a JSON value, not a string");
      Register_Routine
        (T, A_Declaration_Without_A_Description_Is_An_Error_At_Input'Access,
         "A declaration without a description is an error at Input");
      Register_Routine
        (T, A_Declaration_Problem_Is_Reported_With_Its_Path'Access,
         "A declaration problem is reported with its path");
      Register_Routine
        (T, Data_Is_Accepted_On_A_Step_And_A_System'Access,
         "Data is accepted on a step and a system");
      Register_Routine
        (T, Data_Is_Refused_On_A_Pipeline'Access,
         "Data is refused on a pipeline");
      Register_Routine
        (T, Carry_Is_An_Unknown_Attribute'Access,
         "Carry is an unknown attribute");
      Register_Routine
        (T, Data_That_Is_Not_A_Valid_Declaration_Lists_Every_Problem'Access,
         "Data that is not a valid declaration lists every problem");
   end Register_Tests;

end Synapse.Pipeline.Attributes.Tests;
