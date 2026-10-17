with Ada.Strings.Fixed;

with Synapse.Core.Schema_Pattern;
with Synapse.Core.Schema_Rules;
with Synapse.Core.Decimal_Image;

package body Synapse.Core.Note_Schema is

   use Ada.Strings.Unbounded;
   use JSON;

   function Parse_Severity (Text : String) return Maybe_Severity is
     (if Text = "ignore" then (Found => True, Value => Ignore)
      elsif Text = "warn" then (Found => True, Value => Warn)
      elsif Text = "error" then (Found => True, Value => Error_Level)
      else (Found => False));

   ---------------------------------------------------------------------------
   --  Results and small helpers
   ---------------------------------------------------------------------------

   Fine : constant Check_Result := Check_Results.Success (Unit.Nothing);

   function Bad (Message : String) return Check_Result is
     (Check_Results.Failure (To_Unbounded_String (Message)));

   function Has (V : Value; Key : String) return Boolean is
     (Kind_Of (V) = JSON_Object and then Has_Member (V, Key));

   function Child (V : Value; Key : String) return Value is
     (Member_Value (V, Key)) with
     Pre => Has (V, Key);

   --  A mapping under Key.
   function Map_At (V : Value; Key : String) return Boolean is
     (Has (V, Key) and then Kind_Of (Child (V, Key)) = JSON_Object);

   --  A string under Key.
   function String_At (V : Value; Key : String) return Boolean is
     (Has (V, Key) and then Kind_Of (Child (V, Key)) = JSON_String);

   function Text_At (V : Value; Key : String) return String is
     (As_String (Child (V, Key))) with
     Pre => String_At (V, Key);

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

   function Is_Map_List (V : Value) return Boolean is
   begin
      if Kind_Of (V) /= JSON_Array then
         return False;
      end if;
      for I in 1 .. Length (V) loop
         if Kind_Of (Element (V, I)) /= JSON_Object then
            return False;
         end if;
      end loop;
      return True;
   end Is_Map_List;

   --  The first key of V that Allowed (space-separated names) does not list;
   --  a value that is not a mapping has the key `<non-mapping>`.
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

   --  The fault of a pattern, or "" when it is valid.
   function Pattern_Fault (Pattern : String) return String is
     (Fault_Name (Schema_Pattern.Validate (Pattern)));

   --  Checks an optional boolean under Key, with the message prefix.
   function Boolean_Rule
     (V : Value; Key, Prefix : String) return Check_Result is
     (if Has (V, Key) and then Kind_Of (Child (V, Key)) /= JSON_Boolean then
        Bad (Prefix & ": must be boolean")
      else Fine);

   --  An optional integer bound under Key: an integer, at least Lowest.
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

   ---------------------------------------------------------------------------
   --  Header
   ---------------------------------------------------------------------------

   function Header (Top : Value; Expected_Id : String) return Check_Result is
   begin
      if not String_At (Top, "schema") then
         return Bad ("schema.schema: required string is missing");
      end if;
      if Text_At (Top, "schema") /= "synapse-note-schema/v1" then
         return
           Bad
             ("schema.schema: unsupported language '" &
              Text_At (Top, "schema") & "'");
      end if;
      if not String_At (Top, "id") then
         return Bad ("schema.id: required string is missing");
      end if;
      if Text_At (Top, "id") /= Expected_Id then
         return
           Bad
             ("schema.id: expected '" & Expected_Id & "', found '" &
              Text_At (Top, "id") & "'");
      end if;
      return Fine;
   end Header;

   ---------------------------------------------------------------------------
   --  Frontmatter
   ---------------------------------------------------------------------------

   function Field_Rule (Field : String; Rule : Value) return Check_Result is
      Prefix : constant String := "schema.frontmatter.fields." & Field;
      Key    : Unbounded_String;
   begin
      if Kind_Of (Rule) /= JSON_Object then
         return Bad (Prefix & ": must be a mapping");
      end if;
      if Unknown_Key
          (Rule,
           "type required const min_length pattern mutable format timezone" &
           " update_on items enum",
           Key)
      then
         return Bad (Prefix & "." & To_String (Key) & ": unsupported v1 key");
      end if;
      if not String_At (Rule, "type") then
         return Bad (Prefix & ".type: required string is missing");
      end if;

      declare
         Type_Name : constant String := Text_At (Rule, "type");
      begin
         if Type_Name not in
             "string" | "timestamp" | "list" | "integer" | "boolean" | "any"
         then
            return
              Bad (Prefix & ".type: unsupported type '" & Type_Name & "'");
         end if;

         declare
            Required : constant Check_Result :=
              Boolean_Rule (Rule, "required", Prefix & ".required");
            Mutable  : constant Check_Result :=
              Boolean_Rule (Rule, "mutable", Prefix & ".mutable");
            Length   : constant Check_Result :=
              Integer_Rule
                (Rule, "min_length", Prefix & ".min_length", 1,
                 "must be at least 1");
         begin
            if not Check_Results.Is_Success (Required) then
               return Required;
            elsif not Check_Results.Is_Success (Mutable) then
               return Mutable;
            elsif not Check_Results.Is_Success (Length) then
               return Length;
            end if;
         end;

         if Has (Rule, "pattern") then
            if Kind_Of (Child (Rule, "pattern")) /= JSON_String then
               return Bad (Prefix & ".pattern: must be string");
            end if;
            declare
               Fault : constant String :=
                 Pattern_Fault (Text_At (Rule, "pattern"));
            begin
               if Fault /= "" then
                  return Bad (Prefix & ".pattern: " & Fault);
               end if;
            end;
         end if;

         if Has (Rule, "enum")
           and then not Is_String_List (Child (Rule, "enum"))
         then
            return Bad (Prefix & ".enum: must be a string list");
         end if;

         if Type_Name = "list" then
            if not String_At (Rule, "items") then
               return Bad (Prefix & ".items: required string is missing");
            end if;
            if Text_At (Rule, "items") /= "string" then
               return Bad (Prefix & ".items: only string is supported in v1");
            end if;
         end if;
      end;
      return Fine;
   end Field_Rule;

   function Frontmatter_Rules (Top : Value) return Check_Result is
      Key : Unbounded_String;
   begin
      if not Map_At (Top, "frontmatter") then
         return Bad ("schema.frontmatter: required mapping is missing");
      end if;
      declare
         Frontmatter : constant Value := Child (Top, "frontmatter");
      begin
         if Unknown_Key (Frontmatter, "fields field_order", Key) then
            return
              Bad
                ("schema.frontmatter." & To_String (Key) &
                 ": unsupported v1 key");
         end if;
         if Has (Frontmatter, "field_order") then
            if Kind_Of (Child (Frontmatter, "field_order")) /= JSON_String then
               return Bad ("schema.frontmatter.field_order: must be string");
            end if;
            if Text_At (Frontmatter, "field_order") /= "relative" then
               return
                 Bad
                   ("schema.frontmatter.field_order: unsupported value '" &
                    Text_At (Frontmatter, "field_order") & "'");
            end if;
         end if;
         if not Map_At (Frontmatter, "fields") then
            return
              Bad ("schema.frontmatter.fields: required mapping is missing");
         end if;
         declare
            Fields : constant Value := Child (Frontmatter, "fields");
         begin
            for I in 1 .. Length (Fields) loop
               declare
                  Result : constant Check_Result :=
                    Field_Rule (Member_Key (Fields, I), Member_At (Fields, I));
               begin
                  if not Check_Results.Is_Success (Result) then
                     return Result;
                  end if;
               end;
            end loop;
         end;
      end;
      return Fine;
   end Frontmatter_Rules;

   ---------------------------------------------------------------------------
   --  Body
   ---------------------------------------------------------------------------

   function Section_Rule (Section : Value; Index : Natural) return Check_Result
   is
      Prefix : constant String :=
        "schema.body.sections[" & Decimal_Image.Image (Index) & "]";
      Key    : Unbounded_String;
   begin
      if Unknown_Key
          (Section,
           "title level required non_empty max_occurs content children" &
           " repeatable title_pattern",
           Key)
      then
         return Bad (Prefix & "." & To_String (Key) & ": unsupported v1 key");
      end if;
      if not Has (Section, "title") and then not Has (Section, "title_pattern")
      then
         return Bad (Prefix & ": title or title_pattern is required");
      end if;

      declare
         Level   : constant Check_Result :=
           Integer_Rule
             (Section, "level", Prefix & ".level", 1, "must be at least 1");
         Maximum : constant Check_Result :=
           Integer_Rule
             (Section, "max_occurs", Prefix & ".max_occurs", 1,
              "must be at least 1");
      begin
         if not Check_Results.Is_Success (Level) then
            return Level;
         elsif not Check_Results.Is_Success (Maximum) then
            return Maximum;
         end if;
      end;

      declare
         Flags : constant array (1 .. 3) of Check_Result :=
           [Boolean_Rule (Section, "required", Prefix & ".required"),
           Boolean_Rule (Section, "non_empty", Prefix & ".non_empty"),
           Boolean_Rule (Section, "repeatable", Prefix & ".repeatable")];
      begin
         for Flag of Flags loop
            if not Check_Results.Is_Success (Flag) then
               return Flag;
            end if;
         end loop;
      end;

      if Has (Section, "title_pattern") then
         if Kind_Of (Child (Section, "title_pattern")) /= JSON_String then
            return Bad (Prefix & ".title_pattern: must be string");
         end if;
         declare
            Fault : constant String :=
              Pattern_Fault (Text_At (Section, "title_pattern"));
         begin
            if Fault /= "" then
               return Bad (Prefix & ".title_pattern: " & Fault);
            end if;
         end;
      end if;

      if Has (Section, "content") then
         declare
            Content : constant Value := Child (Section, "content");
         begin
            if Unknown_Key (Content, "type enum", Key) then
               return
                 Bad
                   (Prefix & ".content." & To_String (Key) &
                    ": unsupported v1 key");
            end if;
            if Has (Content, "enum")
              and then not Is_String_List (Child (Content, "enum"))
            then
               return Bad (Prefix & ".content.enum: must be a string list");
            end if;
         end;
      end if;

      if Has (Section, "children") then
         declare
            Children : constant Value := Child (Section, "children");
         begin
            if Kind_Of (Children) /= JSON_Array then
               return Bad (Prefix & ".children: must be a list");
            end if;
            --  A child's diagnostics carry its own index in `children`.
            for I in 1 .. Length (Children) loop
               declare
                  Result : constant Check_Result :=
                    Section_Rule (Element (Children, I), I - 1);
               begin
                  if not Check_Results.Is_Success (Result) then
                     return Result;
                  end if;
               end;
            end loop;
         end;
      end if;
      return Fine;
   end Section_Rule;

   function Body_Rules (Top : Value) return Check_Result is
      Key : Unbounded_String;
   begin
      if not Map_At (Top, "body") then
         return Bad ("schema.body: required mapping is missing");
      end if;

      declare
         Body_Value : constant Value := Child (Top, "body");
      begin
         if Unknown_Key
             (Body_Value, "h1 preamble sections section_order lead checklist",
              Key)
         then
            return
              Bad ("schema.body." & To_String (Key) & ": unsupported v1 key");
         end if;
         if not Map_At (Body_Value, "h1") then
            return Bad ("schema.body.h1: required mapping is missing");
         end if;

         declare
            H1     : constant Value := Child (Body_Value, "h1");
            Counts : Check_Result;
         begin
            if Unknown_Key (H1, "required count equals", Key) then
               return
                 Bad
                   ("schema.body.h1." & To_String (Key) &
                    ": unsupported v1 key");
            end if;
            Counts :=
              Integer_Rule
                (H1, "count", "schema.body.h1.count", 1, "must be at least 1");
            if not Check_Results.Is_Success (Counts) then
               return Counts;
            end if;
         end;

         if Has (Body_Value, "sections") then
            declare
               Sections : constant Value := Child (Body_Value, "sections");
            begin
               if Kind_Of (Sections) /= JSON_Array then
                  return Bad ("schema.body.sections: must be a list");
               end if;
               for I in 1 .. Length (Sections) loop
                  declare
                     Result : constant Check_Result :=
                       Section_Rule (Element (Sections, I), I - 1);
                  begin
                     if not Check_Results.Is_Success (Result) then
                        return Result;
                     end if;
                  end;
               end loop;
            end;
         end if;

         if Has (Body_Value, "preamble") then
            declare
               Preamble : constant Value := Child (Body_Value, "preamble");
            begin
               if not Is_Map_List (Preamble) then
                  return
                    Bad ("schema.body.preamble: must be a list of mappings");
               end if;
               for I in 1 .. Length (Preamble) loop
                  declare
                     Rule   : constant Value  := Element (Preamble, I);
                     Prefix : constant String :=
                       "schema.body.preamble[" & Decimal_Image.Image (I - 1) &
                       "]";
                  begin
                     if Unknown_Key
                         (Rule, "type required position marker pattern", Key)
                     then
                        return
                          Bad
                            (Prefix & "." & To_String (Key) &
                             ": unsupported v1 key");
                     end if;
                     if String_At (Rule, "pattern") then
                        declare
                           Fault : constant String :=
                             Pattern_Fault (Text_At (Rule, "pattern"));
                        begin
                           if Fault /= "" then
                              return Bad (Prefix & ".pattern: " & Fault);
                           end if;
                        end;
                     end if;
                  end;
               end loop;
            end;
         end if;

         if Has (Body_Value, "lead") then
            declare
               Lead     : constant Value := Child (Body_Value, "lead");
               Required : Check_Result;
            begin
               if Unknown_Key (Lead, "type required position", Key) then
                  return
                    Bad
                      ("schema.body.lead." & To_String (Key) &
                       ": unsupported v1 key");
               end if;
               Required :=
                 Boolean_Rule (Lead, "required", "schema.body.lead.required");
               if not Check_Results.Is_Success (Required) then
                  return Required;
               end if;
            end;
         end if;

         if Has (Body_Value, "checklist") then
            declare
               Checklist : constant Value := Child (Body_Value, "checklist");
               Required  : Check_Result;
               Minimum   : Check_Result;
            begin
               if Unknown_Key
                   (Checklist,
                    "required min_items position nested_items" &
                    " allowed_children",
                    Key)
               then
                  return
                    Bad
                      ("schema.body.checklist." & To_String (Key) &
                       ": unsupported v1 key");
               end if;
               Required :=
                 Boolean_Rule
                   (Checklist, "required", "schema.body.checklist.required");
               if not Check_Results.Is_Success (Required) then
                  return Required;
               end if;
               Minimum :=
                 Integer_Rule
                   (Checklist, "min_items", "schema.body.checklist.min_items",
                    0, "must not be negative");
               if not Check_Results.Is_Success (Minimum) then
                  return Minimum;
               end if;
               if Has (Checklist, "allowed_children")
                 and then not Is_String_List
                   (Child (Checklist, "allowed_children"))
               then
                  return
                    Bad
                      ("schema.body.checklist.allowed_children:" &
                       " must be a string list");
               end if;
            end;
         end if;
      end;
      return Fine;
   end Body_Rules;

   ---------------------------------------------------------------------------
   --  checks and lints
   ---------------------------------------------------------------------------

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

   --  Shared by `checks:` and `lints:`: one rule, an optional string message,
   --  no stray null, no unknown operator. Section is "checks" or "lints".
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
         if not Parse_Severity (Text_At (Item, "severity")).Found then
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

   function Checks_Rules
     (Top : Value; Ops : JSON_Logic.Operator_Set'Class) return Check_Result
   is
   begin
      if not Has (Top, "checks") then
         return Bad ("schema.checks: required list is missing");
      end if;
      declare
         Checks : constant Value := Child (Top, "checks");
      begin
         if Kind_Of (Checks) /= JSON_Array then
            return Bad ("schema.checks: must be a list");
         end if;
         for I in 1 .. Length (Checks) loop
            declare
               Result : constant Check_Result :=
                 Entry_Rule (Element (Checks, I), "checks", I - 1, Ops, False);
            begin
               if not Check_Results.Is_Success (Result) then
                  return Result;
               end if;
            end;
         end loop;
      end;
      return Fine;
   end Checks_Rules;

   --  Unlike `checks:`, optional: a schema with nothing to lint declares no
   --  `lints:` key at all.
   function Lints_Rules
     (Top : Value; Ops : JSON_Logic.Operator_Set'Class) return Check_Result
   is
   begin
      if not Has (Top, "lints") then
         return Fine;
      end if;
      declare
         Lints : constant Value := Child (Top, "lints");
      begin
         if Kind_Of (Lints) /= JSON_Array then
            return Bad ("schema.lints: must be a list");
         end if;
         for I in 1 .. Length (Lints) loop
            declare
               Result : constant Check_Result :=
                 Entry_Rule (Element (Lints, I), "lints", I - 1, Ops, True);
            begin
               if not Check_Results.Is_Success (Result) then
                  return Result;
               end if;
            end;
         end loop;
      end;
      return Fine;
   end Lints_Rules;

   ---------------------------------------------------------------------------
   --  The document
   ---------------------------------------------------------------------------

   function Validate_Schema
     (Root : JSON.Value; Expected_Id : String;
      Ops  : JSON_Logic.Operator_Set'Class := JSON_Logic.No_Operators)
      return Check_Result
   is
   begin
      if Kind_Of (Root) /= JSON_Object then
         return Bad ("schema: document root must be a mapping");
      end if;

      declare
         Result : Check_Result := Header (Root, Expected_Id);
      begin
         if Check_Results.Is_Success (Result) then
            Result := Frontmatter_Rules (Root);
         end if;
         if Check_Results.Is_Success (Result) then
            Result := Body_Rules (Root);
         end if;
         if Check_Results.Is_Success (Result) then
            Result := Checks_Rules (Root, Ops);
         end if;
         if Check_Results.Is_Success (Result) then
            Result := Lints_Rules (Root, Ops);
         end if;
         return Result;
      end;
   end Validate_Schema;

end Synapse.Core.Note_Schema;
