with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Synapse.Core.Decimal_Image;
with Synapse.Core.Field_Rules;
with Synapse.Core.JSON_Logic;
with Synapse.Core.Note_Check;
with Synapse.Core.Note_Schema;
with Synapse.Core.Optional_Text;
with Synapse.Core.Schema_Checks;
with Synapse.Core.Schema_Rules;

package body Synapse.Core.Object_Schema is

   use Ada.Strings.Unbounded;
   use JSON;
   use Schema_Checks;

   subtype Problems is Text_Lists.Vector;

   --  As in Note_Check: a rule written into a message is cut here.
   Max_Rule_Text : constant := 512;

   procedure Add (List : in out Problems; Problem : String) is
   begin
      List.Append (To_Unbounded_String (Problem));
   end Add;

   --  Adds the problem of Result, if it has one.
   procedure Add (List : in out Problems; Result : Check_Result) is
   begin
      if not Note_Schema.Check_Results.Is_Success (Result) then
         List.Append (Note_Schema.Check_Results.Error (Result));
      end if;
   end Add;

   function Index_Image (I : Positive) return String is
     ("[" & Decimal_Image.Image (I) & "]");

   function Is_Field_Name (Name : String) return Boolean is
     (Name'Length > 0 and then Name (Name'First) in 'a' .. 'z'
      and then
      (for all C of Name (Name'First + 1 .. Name'Last) =>
         C in 'a' .. 'z' | '0' .. '9' | '_'));

   ---------------------------------------------------------------------------
   --  The declaration
   ---------------------------------------------------------------------------

   Item_Types : constant String := "string integer boolean timestamp";

   function Is_Item_Type (Name : String) return Boolean is
     (Name in "string" | "integer" | "boolean" | "timestamp");

   procedure Check_Fields
     (Holder : Value; Prefix : String; List : in out Problems);

   procedure Check_Items
     (Rule : Value; Prefix : String; List : in out Problems)
   is
      Items : Value;
   begin
      if not Has (Rule, "items") then
         Add (List, Prefix & ": required for a list");
         return;
      end if;
      Items := Child (Rule, "items");
      case Kind_Of (Items) is
         when JSON_String =>
            if not Is_Item_Type (As_String (Items)) then
               Add
                 (List,
                  Prefix & ": unsupported type '" & As_String (Items) &
                  "', expected one of " & Item_Types & " or fields");
            end if;
         when JSON_Object =>
            for I in 1 .. Length (Items) loop
               if Member_Key (Items, I) /= "fields" then
                  Add
                    (List,
                     Prefix & "." & Member_Key (Items, I) &
                     ": unsupported key");
               end if;
            end loop;
            Check_Fields (Items, Prefix & ".fields", List);
         when others =>
            Add
              (List,
               Prefix & ": must be a type name or {""fields"": {...}}");
      end case;
   end Check_Items;

   procedure Check_Field
     (Rule : Value; Prefix : String; List : in out Problems)
   is
   begin
      if Kind_Of (Rule) /= JSON_Object then
         Add (List, Prefix & ": must be a mapping");
         return;
      end if;

      for I in 1 .. Length (Rule) loop
         declare
            Key : constant String := Member_Key (Rule, I);
         begin
            if Key in "mutable" | "format" | "timezone" | "update_on" then
               Add (List, Prefix & "." & Key & ": not allowed in an input");
            elsif Ada.Strings.Fixed.Index
                (" type required min_length const pattern enum items" &
                 " description ",
                 " " & Key & " ") =
              0
            then
               Add (List, Prefix & "." & Key & ": unsupported key");
            end if;
         end;
      end loop;

      if not String_At (Rule, "description") then
         Add (List, Prefix & ".description: required string is missing");
      end if;

      Add (List, Boolean_Rule (Rule, "required", Prefix & ".required"));
      Add
        (List,
         Integer_Rule
           (Rule, "min_length", Prefix & ".min_length", 1,
            "must be at least 1"));

      if Has (Rule, "const")
        and then Kind_Of (Child (Rule, "const")) /= JSON_String
      then
         Add (List, Prefix & ".const: must be string");
      end if;

      if Has (Rule, "pattern") then
         if Kind_Of (Child (Rule, "pattern")) /= JSON_String then
            Add (List, Prefix & ".pattern: must be string");
         else
            declare
               Fault : constant String :=
                 Pattern_Fault (Text_At (Rule, "pattern"));
            begin
               if Fault /= "" then
                  Add (List, Prefix & ".pattern: " & Fault);
               end if;
            end;
         end if;
      end if;

      if Has (Rule, "enum") and then not Is_String_List (Child (Rule, "enum"))
      then
         Add (List, Prefix & ".enum: must be a string list");
      end if;

      if not String_At (Rule, "type") then
         Add (List, Prefix & ".type: required string is missing");
         return;
      end if;
      declare
         Type_Name : constant String := Text_At (Rule, "type");
      begin
         if Type_Name = "any" then
            Add (List, Prefix & ".type: any is not allowed in an input");
         elsif Type_Name = "list" then
            Check_Items (Rule, Prefix & ".items", List);
         elsif not Is_Item_Type (Type_Name) then
            Add (List, Prefix & ".type: unsupported type '" & Type_Name & "'");
         end if;
      end;
   end Check_Field;

   --  Checks the `fields` mapping of Holder, a declaration or a list's
   --  `items`.
   procedure Check_Fields
     (Holder : Value; Prefix : String; List : in out Problems)
   is
   begin
      if not Has (Holder, "fields") then
         Add (List, Prefix & ": required mapping is missing");
         return;
      end if;
      declare
         Declared : constant Value := Child (Holder, "fields");
      begin
         if Kind_Of (Declared) /= JSON_Object then
            Add (List, Prefix & ": must be a mapping");
            return;
         end if;
         if Length (Declared) = 0 then
            Add (List, Prefix & ": must declare at least one field");
            return;
         end if;
         for I in 1 .. Length (Declared) loop
            declare
               Name : constant String := Member_Key (Declared, I);
            begin
               if Is_Field_Name (Name) then
                  Check_Field
                    (Member_At (Declared, I), Prefix & "." & Name, List);
               else
                  Add
                    (List,
                     Prefix & "." & Name &
                     ": a field name must match ^[a-z][a-z0-9_]*$");
               end if;
            end;
         end loop;
      end;
   end Check_Fields;

   --  Entry_Rule reports under "schema.checks[N]"; an input says "input.".
   function As_Input (Message : Unbounded_String) return String is
      Text : constant String := To_String (Message);
      Old  : constant String := "schema.";
   begin
      if Text'Length >= Old'Length
        and then Text (Text'First .. Text'First + Old'Length - 1) = Old
      then
         return "input." & Text (Text'First + Old'Length .. Text'Last);
      end if;
      return Text;
   end As_Input;

   function Validate_Declaration
     (Declared : JSON.Value) return Synapse.Core.Text_Lists.Vector
   is
      List : Problems;
   begin
      if Kind_Of (Declared) /= JSON_Object then
         Add (List, "input: must be a mapping");
         return List;
      end if;

      for I in 1 .. Length (Declared) loop
         if Member_Key (Declared, I) not in "fields" | "checks" then
            Add
              (List,
               "input." & Member_Key (Declared, I) & ": unsupported key");
         end if;
      end loop;

      Check_Fields (Declared, "input.fields", List);

      if Has (Declared, "checks") then
         declare
            Checks : constant Value := Child (Declared, "checks");
         begin
            if Kind_Of (Checks) /= JSON_Array then
               Add (List, "input.checks: must be a list");
            else
               for I in 1 .. Length (Checks) loop
                  declare
                     Result : constant Check_Result :=
                       Entry_Rule
                         (Element (Checks, I), "checks", I,
                          JSON_Logic.No_Operators, False);
                  begin
                     if not Note_Schema.Check_Results.Is_Success (Result) then
                        Add
                          (List,
                           As_Input
                             (Note_Schema.Check_Results.Error (Result)));
                     end if;
                  end;
               end loop;
            end if;
         end;
      end if;
      return List;
   end Validate_Declaration;

   ---------------------------------------------------------------------------
   --  The object
   ---------------------------------------------------------------------------

   --  An optional field given as "" or [] counts as not given.
   function Is_Empty (V : Value) return Boolean is
     ((Kind_Of (V) = JSON_String and then As_String (V) = "")
      or else (Kind_Of (V) = JSON_Array and then Length (V) = 0));

   procedure Check_Object
     (Fields : Value; Given : Value; Prefix : String; List : in out Problems);

   procedure Check_Given
     (Rule : Value; Given : Value; Prefix : String; List : in out Problems)
   is
      Problem : constant Optional_Text.Option :=
        Field_Rules.Check_Value (Prefix, Rule, Given);
   begin
      if Problem.Found then
         List.Append (Problem.Value);
         return;
      end if;
      if Kind_Of (Given) /= JSON_Array then
         return;
      end if;

      declare
         Items : constant Value := Child (Rule, "items");
      begin
         for I in 1 .. Length (Given) loop
            declare
               Item : constant Value  := Element (Given, I);
               Path : constant String := Prefix & Index_Image (I);
            begin
               if Kind_Of (Items) = JSON_String then
                  Check_Given
                    (Make_Object
                       ([(Key  => To_Unbounded_String ("type"),
                          Item => Items)]),
                     Item, Path, List);
               elsif Kind_Of (Item) /= JSON_Object then
                  Add (List, Path & ": expected a JSON object");
               else
                  Check_Object (Child (Items, "fields"), Item, Path, List);
               end if;
            end;
         end loop;
      end;
   end Check_Given;

   procedure Check_Object
     (Fields : Value; Given : Value; Prefix : String; List : in out Problems)
   is
   begin
      for I in 1 .. Length (Fields) loop
         declare
            Name : constant String := Member_Key (Fields, I);
            Rule : constant Value  := Member_At (Fields, I);
            Path : constant String := Prefix & "." & Name;
            Required : constant Boolean :=
              Has (Rule, "required")
              and then Kind_Of (Child (Rule, "required")) = JSON_Boolean
              and then As_Boolean (Child (Rule, "required"));
         begin
            if not Has_Member (Given, Name) then
               if Required then
                  Add (List, Path & ": required field is missing");
               end if;
            elsif Required or else not Is_Empty (Member_Value (Given, Name))
            then
               Check_Given (Rule, Member_Value (Given, Name), Path, List);
            end if;
         end;
      end loop;

      for I in 1 .. Length (Given) loop
         if not Has_Member (Fields, Member_Key (Given, I)) then
            Add
              (List, Prefix & "." & Member_Key (Given, I) & ": unknown field");
         end if;
      end loop;
   end Check_Object;

   function Failure_Message
     (Entry_Value : Value; Shape : Schema_Rules.Entry_Shape; Rule : Value)
      return String
   is
   begin
      if Shape.Message_Present and then not Shape.Message_Invalid then
         return As_String (Member_Value (Entry_Value, "message"));
      end if;
      declare
         Text : constant String := To_String (Rule);
      begin
         return
           "rule failed: " &
           Text
             (Text'First ..
                  Text'First + Natural'Min (Text'Length, Max_Rule_Text) - 1);
      end;
   end Failure_Message;

   procedure Run_Checks
     (Checks : Value; Given : Value; List : in out Problems)
   is
   begin
      for I in 1 .. Length (Checks) loop
         declare
            Entry_Value : constant Value                    :=
              Element (Checks, I);
            Shape       : constant Schema_Rules.Entry_Shape :=
              Schema_Rules.Shape_Of (Entry_Value);
         begin
            if Shape.Is_Rule then
               declare
                  Converted : constant Schema_Rules.Rule_Result :=
                    Schema_Rules.To_Rule (Schema_Rules.Rule_Object (Shape));
               begin
                  if Converted.Found
                    and then not JSON_Logic.Truthy
                      (JSON_Logic.Evaluate
                         (Converted.Value, (Data => Given, others => <>)))
                  then
                     Add
                       (List,
                        Failure_Message (Entry_Value, Shape, Converted.Value));
                  end if;
               exception
                  when E : JSON_Logic.Invalid_Arguments
                    | JSON_Logic.Unknown_Operator
                    | JSON_Logic.Pattern_Too_Complex =>
                     Add
                       (List,
                        "input.checks" & Index_Image (I) & ": " &
                        Note_Check.Fault_Name (E));
               end;
            end if;
         end;
      end loop;
   end Run_Checks;

   function Validate_Object
     (Declared, Given : JSON.Value) return Synapse.Core.Text_Lists.Vector
   is
      List : Problems;
   begin
      if Kind_Of (Given) /= JSON_Object then
         Add (List, "input: expected a JSON object");
         return List;
      end if;
      Check_Object (Child (Declared, "fields"), Given, "input", List);
      if List.Is_Empty and then Has (Declared, "checks") then
         Run_Checks (Child (Declared, "checks"), Given, List);
      end if;
      return List;
   end Validate_Object;

end Synapse.Core.Object_Schema;
