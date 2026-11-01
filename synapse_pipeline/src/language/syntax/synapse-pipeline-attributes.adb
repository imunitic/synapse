with Ada.Strings.Unbounded;

with Synapse.Core.JSON;
with Synapse.Pipeline.Durations;
with Synapse.Pipeline.Guards;
with Synapse.Pipeline.Harnesses;
with Synapse.Pipeline.Permission_Levels;
with Synapse.Pipeline.Skills;

package body Synapse.Pipeline.Attributes is

   use Ada.Strings.Unbounded;
   use type Synapse.Core.JSON.Kind;
   use type Syntax.Value_Kind;

   package JSON renames Synapse.Core.JSON;

   type Context_Set is array (Context) of Boolean;
   type Value_Set is array (Syntax.Value_Kind) of Boolean;

   type Rule is record
      Known    : Boolean;
      Contexts : Context_Set;
      Values   : Value_Set;
   end record;

   Nowhere : constant Context_Set := [others => False];
   Name_Only   : constant Value_Set :=
     [Syntax.Name_Value => True, others => False];
   String_Only : constant Value_Set :=
     [Syntax.String_Value => True, others => False];

   function Rule_Of (Name : String) return Rule is
      Both : constant Context_Set :=
        [Step_Context | System_Context => True, others => False];
   begin
      if Name = "Agent" then
         return (True, Both, Name_Only);
      elsif Name = "System" then
         return (True, [Step_Context => True, others => False], Name_Only);
      elsif Name = "Prompt" or else Name = "Skill" then
         return
           (True,
            [Step_Context | System_Context | Agent_Context => True,
             others => False],
            String_Only);
      elsif Name = "Harness" or else Name = "Permissions" then
         return (True, Both, Name_Only);
      elsif Name = "Model" then
         return
           (True, Both,
            [Syntax.Name_Value | Syntax.String_Value => True,
             others => False]);
      elsif Name = "Tools" then
         return
           (True, Both, [Syntax.JSON_Value => True, others => False]);
      elsif Name = "Timeout" then
         return (True, Both, String_Only);
      elsif Name = "Retries" then
         return
           (True, Both, [Syntax.Integer_Value => True, others => False]);
      elsif Name = "When" then
         return
           (True, [Edge_Context => True, others => False],
            [Syntax.Name_Value | Syntax.JSON_Value => True,
             others => False]);
      elsif Name = "Max_Iterations" then
         return
           (True, [Edge_Context => True, others => False],
            [Syntax.Integer_Value => True, others => False]);
      end if;
      return (False, Nowhere, [others => False]);
   end Rule_Of;

   function Is_Known (Name : String) return Boolean is
     (Rule_Of (Name).Known);

   function Noun (Where : Context) return String is
     (case Where is
        when Step_Context   => "a step",
        when Edge_Context   => "an edge",
        when System_Context => "a system",
        when Agent_Context  => "an agent");

   function Describe (Kind : Syntax.Value_Kind) return String is
     (case Kind is
        when Syntax.Name_Value    => "a name",
        when Syntax.String_Value  => "a string",
        when Syntax.Integer_Value => "an integer",
        when Syntax.JSON_Value    => "a JSON value");

   function Accepts (Values : Value_Set) return String is
      Result : Unbounded_String;
   begin
      for K in Values'Range loop
         if Values (K) then
            if Length (Result) > 0 then
               Append (Result, " or ");
            end if;
            Append (Result, Describe (K));
         end if;
      end loop;
      return To_String (Result);
   end Accepts;

   function At_Name (Item : Syntax.Attribute; Message : String)
      return Error_Options.Option
   is
     (Error_Options.Of_Value
        (Source_Errors.Make (Message, Item.Name.Line, Item.Name.Column)));

   function At_Value (Item : Syntax.Attribute; Message : String)
      return Error_Options.Option
   is
     (Error_Options.Of_Value
        (Source_Errors.Make (Message, Item.Item.Line, Item.Item.Column)));

   function Strings_Only (V : JSON.Value) return Boolean is
     (JSON.Kind_Of (V) = JSON.JSON_Array
      and then
        (for all I in 1 .. JSON.Length (V) =>
           JSON.Kind_Of (JSON.Element (V, I)) = JSON.JSON_String));

   function Check
     (Where : Context; Item : Syntax.Attribute) return Error_Options.Option
   is
      Name : constant String := To_String (Item.Name.Name);
      Spec : constant Rule := Rule_Of (Name);
   begin
      if not Spec.Known then
         return At_Name (Item, "unknown attribute '" & Name & "'");
      elsif Name = "System" and then Where = System_Context then
         return At_Name (Item, "a system cannot refer to another system");
      elsif not Spec.Contexts (Where) then
         return At_Name
           (Item, "'" & Name & "' is not an attribute of " & Noun (Where));
      elsif not Spec.Values (Item.Item.Kind) then
         return At_Value
           (Item,
            "'" & Name & "' takes " & Accepts (Spec.Values) & ", not "
            & Describe (Item.Item.Kind));
      end if;
      if Name = "Prompt" and then Length (Item.Item.Text) = 0 then
         return At_Value (Item, "'Prompt' is empty");
      elsif Name = "Skill"
        and then not Skills.Is_Valid_Name (To_String (Item.Item.Text))
      then
         return At_Value
           (Item,
            "'" & To_String (Item.Item.Text) & "' is not a skill name: "
            & "lowercase letters, digits and single hyphens, up to 64");
      elsif Name = "Harness"
        and then not Harnesses.Find (To_String (Item.Item.Name)).Found
      then
         return At_Value
           (Item,
            "'" & To_String (Item.Item.Name) & "' is not a harness; the "
            & "harnesses are " & Harnesses.Names);
      elsif Name = "Permissions"
        and then not Permission_Levels.Find (To_String (Item.Item.Name)).Found
      then
         return At_Value
           (Item,
            "'" & To_String (Item.Item.Name) & "' is not a permission "
            & "level; the levels are " & Permission_Levels.Names);
      elsif Name = "Timeout"
        and then Durations.Seconds (To_String (Item.Item.Text)) = 0
      then
         return At_Value
           (Item,
            "'Timeout' is a number and a unit, such as ""30m""; found """
            & To_String (Item.Item.Text) & """");
      elsif Name = "Max_Iterations" and then Item.Item.Number < 1 then
         return At_Value (Item, "'Max_Iterations' is at least 1");
      elsif Name = "When" and then Item.Item.Kind = Syntax.JSON_Value
        and then Guards.Problem (Item.Item.Json).Found
      then
         return At_Value
           (Item,
            "'When': "
            & To_String (Guards.Problem (Item.Item.Json).Value));
      elsif Name = "Tools" and then not Strings_Only (Item.Item.Json) then
         return At_Value (Item, "'Tools' is a JSON list of strings");
      end if;
      return Error_Options.None;
   end Check;

end Synapse.Pipeline.Attributes;
