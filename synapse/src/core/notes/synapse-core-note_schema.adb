with Synapse.Core.Decimal_Image;
with Synapse.Core.Schema_Checks;

package body Synapse.Core.Note_Schema is

   use Ada.Strings.Unbounded;
   use JSON;
   use Schema_Checks;

   function Parse_Severity (Text : String) return Maybe_Severity is
     (if Text = "ignore" then (Found => True, Value => Ignore)
      elsif Text = "warn" then (Found => True, Value => Warn)
      elsif Text = "error" then (Found => True, Value => Error_Level)
      else (Found => False));

   ---------------------------------------------------------------------------
   --  Small helpers
   ---------------------------------------------------------------------------

   --  A mapping under Key.
   function Map_At (V : Value; Key : String) return Boolean is
     (Has (V, Key) and then Kind_Of (Child (V, Key)) = JSON_Object);

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
           " update_on items enum description",
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

         --  A description documents the field for people; validating a note
         --  never reads it.
         if Has (Rule, "description")
           and then Kind_Of (Child (Rule, "description")) /= JSON_String
         then
            return Bad (Prefix & ".description: must be string");
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
