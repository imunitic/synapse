with Ada.Strings.Fixed;

with Synapse.Core.Schema_Pattern;
with Synapse.Core.Schema_Rules;
with Synapse.Core.Decimal_Image;

package body Synapse.Core.Schema_Checks is

   use Ada.Strings.Unbounded;
   use JSON;

   subtype Value is JSON.Value;

   function Bad (Message : String) return Check_Result is
     (Note_Schema.Check_Results.Failure (To_Unbounded_String (Message)));

   function Is_String_List (V : Value) return Boolean is
   begin
      if Kind_Of (V) /= JSON_Array then
         return False;
      end if;
      for I in 1 .. Length (V) loop
         if Kind_Of (Element (V, I)) /= JSON_String then
            return False;
         end if;
      end loop;
      return True;
   end Is_String_List;

   function Unknown_Key
     (V : Value; Allowed : String; Key : out Unbounded_String) return Boolean
   is
   begin
      if Kind_Of (V) /= JSON_Object then
         Key := To_Unbounded_String ("<non-mapping>");
         return True;
      end if;
      for I in 1 .. Length (V) loop
         declare
            Name : constant String := Member_Key (V, I);
         begin
            if Ada.Strings.Fixed.Index
                (" " & Allowed & " ", " " & Name & " ") =
              0
            then
               Key := To_Unbounded_String (Name);
               return True;
            end if;
         end;
      end loop;
      return False;
   end Unknown_Key;

   --  The name a pattern fault is reported under, so messages are stable.
   function Fault_Name (F : Schema_Pattern.Fault) return String is
     (case F is when Schema_Pattern.None => "",
        when Schema_Pattern.Invalid_Escape => "InvalidEscape",
        when Schema_Pattern.Unterminated_Class => "UnterminatedClass",
        when Schema_Pattern.Empty_Class => "EmptyClass",
        when Schema_Pattern.Invalid_Quantifier => "InvalidQuantifier",
        when Schema_Pattern.Unsupported_Construct => "UnsupportedConstruct");

   function Pattern_Fault (Pattern : String) return String is
     (Fault_Name (Schema_Pattern.Validate (Pattern)));

   function Boolean_Rule
     (V : Value; Key, Prefix : String) return Check_Result is
     (if Has (V, Key) and then Kind_Of (Child (V, Key)) /= JSON_Boolean then
        Bad (Prefix & ": must be boolean")
      else Fine);

   function Integer_Rule
     (V       : Value; Key, Prefix : String; Lowest : Long_Long_Integer;
      Too_Low : String) return Check_Result
   is
   begin
      if not Has (V, Key) then
         return Fine;
      end if;
      if Kind_Of (Child (V, Key)) /= JSON_Integer then
         return Bad (Prefix & ": must be integer");
      end if;
      if As_Integer (Child (V, Key)) < Lowest then
         return Bad (Prefix & ": " & Too_Low);
      end if;
      return Fine;
   end Integer_Rule;

   --  The first operator name in Rule that is neither built in nor in Ops.
   function First_Unknown_Operator
     (Rule :     Value; Ops : JSON_Logic.Operator_Set'Class;
      Name : out Unbounded_String) return Boolean
   is
   begin
      case Kind_Of (Rule) is
         when JSON_Object =>
            if Length (Rule) = 1 then
               declare
                  Operator : constant String := Member_Key (Rule, 1);
               begin
                  if not JSON_Logic.Is_Built_In (Operator)
                    and then not Ops.Has_Operator (Operator)
                  then
                     Name := To_Unbounded_String (Operator);
                     return True;
                  end if;
                  return
                    First_Unknown_Operator (Member_At (Rule, 1), Ops, Name);
               end;
            end if;
            for I in 1 .. Length (Rule) loop
               if First_Unknown_Operator (Member_At (Rule, I), Ops, Name) then
                  return True;
               end if;
            end loop;
            return False;

         when JSON_Array =>
            for I in 1 .. Length (Rule) loop
               if First_Unknown_Operator (Element (Rule, I), Ops, Name) then
                  return True;
               end if;
            end loop;
            return False;

         when others =>
            return False;
      end case;
   end First_Unknown_Operator;

   function Entry_Rule
     (Item : Value; Section : String; Index : Natural;
      Ops  : JSON_Logic.Operator_Set'Class; With_Severity : Boolean)
      return Check_Result
   is
      Prefix : constant String                   :=
        "schema." & Section & "[" & Decimal_Image.Image (Index) & "]";
      Shape  : constant Schema_Rules.Entry_Shape :=
        Schema_Rules.Shape_Of (Item);
   begin
      if not Shape.Is_Rule then
         return Bad (Prefix & ": exactly one rule operator is required");
      end if;
      if Shape.Message_Invalid then
         return Bad (Prefix & ".message: must be string");
      end if;

      if With_Severity then
         if not String_At (Item, "severity") then
            return Bad (Prefix & ".severity: required string is missing");
         end if;
         if not Note_Schema.Parse_Severity (Text_At (Item, "severity")).Found
         then
            return
              Bad
                (Prefix & ".severity: unsupported value '" &
                 Text_At (Item, "severity") & "'");
         end if;
      end if;

      declare
         Converted : constant Schema_Rules.Rule_Result :=
           Schema_Rules.To_Rule (Schema_Rules.Rule_Object (Shape));
         Name      : Unbounded_String;
      begin
         if not Converted.Found then
            return
              Bad
                (Prefix & "." & To_String (Shape.Key) &
                 ": a bare null is not valid here");
         end if;
         if First_Unknown_Operator (Converted.Value, Ops, Name) then
            return
              Bad (Prefix & ": unknown operator '" & To_String (Name) & "'");
         end if;
      end;
      return Fine;
   end Entry_Rule;

end Synapse.Core.Schema_Checks;
