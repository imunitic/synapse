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
         if Where /= Edge_Context then
            Assert_Fine (Where, Named ("Prompt", A_String ("do")), "Prompt");
            Assert_Fine (Where, Named ("Skill", A_String ("a-b")), "Skill");
         end if;
      end loop;
      Assert_Fine (Step_Context, Named ("Harness", A_Name ("Claude")), "H");
      Assert_Fine (Step_Context, Named ("Model", A_Name ("Opus")), "Model");
      Assert_Fine
        (Step_Context, Named ("Model", A_String ("claude-opus")), "Model");
      Assert_Fine
        (System_Context, Named ("Permissions", A_Name ("Read_Only")), "P");
      Assert_Fine
        (Step_Context, Named ("Tools", A_JSON ("[""Read"", ""Grep""]")),
         "Tools");
      Assert_Fine (Step_Context, Named ("Timeout", A_String ("30m")), "T");
      Assert_Fine (Step_Context, Named ("Retries", An_Integer (0)), "Retries");
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
        (Step_Context, Named ("Prompt", A_Name ("X")), 9,
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
        (Step_Context, Named ("Skill", A_String ("Review_Code")), 9,
         "is not a skill name", "a bad skill name");
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
        (Edge_Context, Named ("Max_Iterations", An_Integer (0)), 9,
         "at least 1", "no iterations");
      Assert_Wrong
        (Edge_Context, Named ("When", A_JSON ("{""frob"": [1]}")), 9,
         "'frob' is not a JsonLogic operator", "an unknown guard operator");
      Assert_Wrong
        (Edge_Context, Named ("When", A_JSON ("[1, 2]")), 9,
         "a guard is a single JsonLogic rule", "a list for a guard");
      Assert_Wrong
        (Step_Context, Named ("Tools", A_JSON ("[""Read"", 3]")), 9,
         "a JSON list of strings", "a list with a number");
      Assert_Wrong
        (Step_Context, Named ("Tools", A_JSON ("{""a"": 1}")), 9,
         "a JSON list of strings", "an object for a list");
   end Some_Values_Are_Checked_Further;

   procedure Is_Known_Knows_The_Twelve (T : in out Test_Cases_Class) is
      pragma Unreferenced (T);
   begin
      Assert (Is_Known ("Agent") and then Is_Known ("System"), "Agent System");
      Assert (Is_Known ("Prompt") and then Is_Known ("Skill"), "Prompt Skill");
      Assert
        (Is_Known ("Harness") and then Is_Known ("Model"), "Harness Model");
      Assert
        (Is_Known ("Permissions") and then Is_Known ("Tools"),
         "Permissions Tools");
      Assert
        (Is_Known ("Timeout") and then Is_Known ("Retries"),
         "Timeout Retries");
      Assert
        (Is_Known ("When") and then Is_Known ("Max_Iterations"),
         "When Max_Iterations");
      Assert
        (not Is_Known ("Colour") and then not Is_Known ("")
         and then not Is_Known ("agent"),
         "and only those, spelled so");
   end Is_Known_Knows_The_Twelve;

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
   end Register_Tests;

end Synapse.Pipeline.Attributes.Tests;
