with Synapse.Core.Frontmatter;
with Synapse.Core.JSON_Logic;
with Synapse.Core.Note_Operators;
with Synapse.Core.Note_Text;
with Synapse.Core.Regex_Lite;
with Synapse.Core.Schema_Pattern;
with Synapse.Core.Schema_Rules;

package body Synapse.Core.Note_Check is

   use Ada.Strings.Unbounded;
   use JSON;
   use Note_Model;
   use type Schema_Pattern.Fault;
   use type Regex_Lite.Outcome;
   use type Note_Schema.Severity;

   LF : constant Character := Character'Val (10);

   Max_Rule_Text : constant := 512;

   ---------------------------------------------------------------------------
   --  Small helpers
   ---------------------------------------------------------------------------

   function Bad (Text : String) return Note_Schema.Check_Result
   is (Valid => False, Message => To_Unbounded_String (Text));

   Good : constant Note_Schema.Check_Result := (Valid => True);

   function Img (N : Long_Long_Integer) return String is
      Text : constant String := Long_Long_Integer'Image (N);
   begin
      return
        (if Text (Text'First) = ' '
         then Text (Text'First + 1 .. Text'Last)
         else Text);
   end Img;

   function Img (N : Natural) return String
   is (Img (Long_Long_Integer (N)));

   function Is_Mapping (V : Value) return Boolean
   is (Kind_Of (V) = JSON_Object);

   function Has (V : Value; Key : String) return Boolean
   is (Is_Mapping (V) and then Has_Member (V, Key));

   function Bool_At (V : Value; Key : String; Default : Boolean) return Boolean
   is (if Has (V, Key) and then Kind_Of (Member_Value (V, Key)) = JSON_Boolean
       then As_Boolean (Member_Value (V, Key))
       else Default);

   function Is_Explicitly_False (V : Value; Key : String) return Boolean
   is (Has (V, Key)
       and then Kind_Of (Member_Value (V, Key)) = JSON_Boolean
       and then not As_Boolean (Member_Value (V, Key)));

   function Has_String (V : Value; Key : String) return Boolean
   is (Has (V, Key) and then Kind_Of (Member_Value (V, Key)) = JSON_String);

   function String_At (V : Value; Key : String) return String
   is (if Has_String (V, Key) then As_String (Member_Value (V, Key)) else "");

   function Int_At (V : Value; Key : String; Default : Long_Long_Integer)
      return Long_Long_Integer
   is (if Has (V, Key) and then Kind_Of (Member_Value (V, Key)) = JSON_Integer
       then As_Integer (Member_Value (V, Key))
       else Default);

   --  Whether Text is one of the strings of the list Items.
   function In_List (Text : String; Items : Value) return Boolean is
   begin
      if Kind_Of (Items) /= JSON_Array then
         return False;
      end if;
      for I in 1 .. Length (Items) loop
         declare
            Item : constant Value := Element (Items, I);
         begin
            if Kind_Of (Item) = JSON_String and then As_String (Item) = Text
            then
               return True;
            end if;
         end;
      end loop;
      return False;
   end In_List;

   --  Text without leading and trailing characters of Set.
   function Trim_Of (Text : String; Set : String) return String is
      function Member (C : Character) return Boolean is
      begin
         for S of Set loop
            if S = C then
               return True;
            end if;
         end loop;
         return False;
      end Member;

      First : Natural := Text'First;
      Last  : Natural := Text'Last;
   begin
      while First <= Last and then Member (Text (First)) loop
         First := First + 1;
      end loop;
      while Last >= First and then Member (Text (Last)) loop
         Last := Last - 1;
      end loop;
      return Text (First .. Last);
   end Trim_Of;

   function Trim_Blank (Text : String) return String
   is (Trim_Of (Text, " " & Character'Val (9) & Character'Val (13)
                      & LF));

   function Without_CR (Line : String) return String
   is (if Line'Length > 0 and then Line (Line'Last) = Character'Val (13)
       then Line (Line'First .. Line'Last - 1)
       else Line);

   --  The number of characters of UTF-8 text: bytes that start a sequence.
   function Characters (Text : String) return Natural is
      Count : Natural := 0;
   begin
      for C of Text loop
         if Character'Pos (C) / 64 /= 2 then  --  not 10xxxxxx
            Count := Count + 1;
         end if;
      end loop;
      return Count;
   end Characters;

   --  Whether Text matches Pattern. A pattern that is not valid or runs out
   --  of steps matches nothing.
   function Matches (Pattern, Text : String) return Boolean
   is (Schema_Pattern.Validate (Pattern) = Schema_Pattern.None
       and then Schema_Pattern.Search (Pattern, Text) = Regex_Lite.Matched);

   ---------------------------------------------------------------------------
   --  Frontmatter fields
   ---------------------------------------------------------------------------

   function Check_Field
     (Key : String; Rule : Value; Note : String; Ctx : Context)
      return Note_Schema.Check_Result
   is
      Found   : constant Lookup := Lookup_Field (Note, Key);
      Prefix  : constant String := "frontmatter." & Key & ": ";
      Type_Name : constant String := String_At (Rule, "type");
   begin
      if Found.Duplicate then
         return Bad (Prefix & "field occurs more than once");
      end if;
      if not Found.Found then
         return (if Bool_At (Rule, "required", False)
                 then Bad (Prefix & "required field is missing")
                 else Good);
      end if;
      if not Has_Type (Found.Value, Type_Name) then
         return Bad (Prefix & "expected " & Type_Name);
      end if;

      if Found.Value.Kind = String_Field then
         declare
            Text : constant String := To_String (Found.Value.Text);
         begin
            if Has_String (Rule, "const")
              and then Text /= String_At (Rule, "const")
            then
               return Bad (Prefix & "expected '" & String_At (Rule, "const")
                           & "'");
            end if;
            if Has (Rule, "min_length") then
               declare
                  Bound : constant Long_Long_Integer :=
                    Int_At (Rule, "min_length", 0);
               begin
                  if Long_Long_Integer (Characters (Text)) < Bound then
                     return Bad (Prefix & "must be at least " & Img (Bound)
                                 & " characters");
                  end if;
               end;
            end if;
            if Has_String (Rule, "pattern")
              and then not Matches (String_At (Rule, "pattern"), Text)
            then
               return Bad (Prefix & "does not match required pattern");
            end if;
            if Has (Rule, "enum")
              and then not In_List (Text, Member_Value (Rule, "enum"))
            then
               return Bad (Prefix & "value '" & Text & "' is not allowed");
            end if;
            if Type_Name = "timestamp"
              and then not Note_Text.Valid_Timestamp (Text)
            then
               return Bad
                 (Prefix & "expected RFC3339, YYYY-MM-DDTHH:MM:SS then Z or a"
                  & " colon-separated numeric offset");
            end if;
         end;
      end if;

      if Ctx.Has_Existing
        and then Ctx.Mode /= Create
        and then Is_Explicitly_False (Rule, "mutable")
      then
         declare
            Old : constant Lookup :=
              Lookup_Field (To_String (Ctx.Existing), Key);
         begin
            if not Old.Found or else not Values_Equal (Old.Value, Found.Value)
            then
               return Bad (Prefix & "field is immutable");
            end if;
         end;
      end if;
      return Good;
   end Check_Field;

   function Check_Frontmatter
     (Schema : Value; Note : String; Ctx : Context)
      return Note_Schema.Check_Result
   is
      Rule      : constant Value := Member_Value (Schema, "frontmatter");
      Fields    : constant Value := Member_Value (Rule, "fields");
      Relative  : constant Boolean :=
        Has_String (Rule, "field_order")
        and then String_At (Rule, "field_order") = "relative";
      Positions : constant Position_Vectors.Vector :=
        (if Relative then Field_Positions (Note)
         else Position_Vectors.Empty_Vector);
      Previous  : Natural := 0;
      Have_Prev : Boolean := False;
   begin
      for I in 1 .. Length (Fields) loop
         declare
            Key    : constant String := Member_Key (Fields, I);
            Result : constant Note_Schema.Check_Result :=
              Check_Field (Key, Member_At (Fields, I), Note, Ctx);
         begin
            if not Result.Valid then
               return Result;
            end if;
            if Relative then
               for P of Positions loop
                  if To_String (P.Key) = Key then
                     if Have_Prev and then P.Line_Start < Previous then
                        return Bad ("frontmatter." & Key
                                    & ": declared fields are out of relative"
                                    & " order");
                     end if;
                     Previous := P.Line_Start;
                     Have_Prev := True;
                     exit;
                  end if;
               end loop;
            end if;
         end;
      end loop;
      return Good;
   end Check_Frontmatter;

   ---------------------------------------------------------------------------
   --  Body
   ---------------------------------------------------------------------------

   function Slice (Text : String; From, Stop : Natural) return String
   is (Text (Text'First + From .. Text'First + Stop - 1));

   --  The lines of Text, without line feeds.
   generic
      with procedure Visit (Line : String);
   procedure Each_Line (Text : String);

   procedure Each_Line (Text : String) is
      Start : Positive := Text'First;
   begin
      for I in Text'First .. Text'Last + 1 loop
         if I > Text'Last or else Text (I) = LF then
            Visit (Text (Start .. I - 1));
            Start := I + 1;
         end if;
      end loop;
   end Each_Line;

   function Check_Preamble
     (Rule : Value; Markdown : String; H1 : Heading)
      return Note_Schema.Check_Result
   is
      Pattern : constant String := String_At (Rule, "pattern");
      Marker  : constant String := String_At (Rule, "marker");
      Region  : constant String :=
        Slice (Markdown, H1.Content_Start, H1.Content_End);
      First_Line : Unbounded_String;
      Have_First : Boolean := False;
      Result     : Note_Schema.Check_Result := Good;

      procedure Find_First (Line : String) is
         Text : constant String := Trim_Of (Line, " " & Character'Val (9)
                                                  & Character'Val (13));
      begin
         if not Have_First and then Text'Length > 0 then
            Have_First := True;
            First_Line := To_Unbounded_String (Text);
         end if;
      end Find_First;

      procedure Check_Line (Line : String) is
         Text : constant String := Trim_Of (Line, " " & Character'Val (9)
                                                  & Character'Val (13));
      begin
         if not Result.Valid
           or else Text'Length < Marker'Length
           or else Text (Text'First .. Text'First + Marker'Length - 1)
                   /= Marker
         then
            return;
         end if;
         if not Have_First or else Text /= To_String (First_Line) then
            Result :=
              Bad ("body.preamble: '" & Marker
                   & "' annotation must immediately follow H1");
         elsif not Matches (Pattern, Text) then
            Result :=
              Bad ("body.preamble: '" & Marker & "' annotation is malformed");
         end if;
      end Check_Line;

      procedure Scan_Region is new Each_Line (Find_First);
      procedure Scan_All is new Each_Line (Check_Line);
   begin
      if not Has_String (Rule, "pattern")
        or else not Has_String (Rule, "marker")
      then
         return Good;
      end if;
      --  The first non-blank line below the H1, up to its section's end.
      if Region'Length > 0 then
         Scan_Region (Region);
      end if;
      Scan_All (Markdown);
      return Result;
   end Check_Preamble;

   function Check_Child
     (Rule     : Value;
      Headings : Heading_Array;
      Markdown : String;
      Parent   : Heading) return Note_Schema.Check_Result
   is
      Level : constant Long_Long_Integer :=
        Int_At (Rule, "level", Long_Long_Integer (Parent.Level) + 1);
      Count : Natural := 0;
      Parent_Title : constant String := To_String (Parent.Title);
   begin
      for H of Headings loop
         if H.Line_Start > Parent.Line_Start
           and then H.Line_Start < Parent.Content_End
           and then Long_Long_Integer (H.Level) = Level
         then
            declare
               Title   : constant String := To_String (H.Title);
               Matched : constant Boolean :=
                 (if Has_String (Rule, "title")
                  then Title = String_At (Rule, "title")
                  elsif Has_String (Rule, "title_pattern")
                  then Matches (String_At (Rule, "title_pattern"), Title)
                  else False);
            begin
               if not Matched then
                  if Has_String (Rule, "title_pattern") then
                     return Bad ("body.section." & Parent_Title
                                 & ": child heading '" & Title
                                 & "' has an invalid title");
                  end if;
               else
                  Count := Count + 1;
                  if Bool_At (Rule, "non_empty", False)
                    and then Trim_Blank
                               (Slice (Markdown, H.Content_Start,
                                       H.Content_End))'Length = 0
                  then
                     return Bad ("body.section." & Parent_Title & "."
                                 & Title & ": must not be empty");
                  end if;
               end if;
            end;
         end if;
      end loop;
      if Bool_At (Rule, "required", False) and then Count = 0 then
         return Bad ("body.section." & Parent_Title
                     & ": required child heading is missing");
      end if;
      if not Bool_At (Rule, "repeatable", False) and then Count > 1 then
         return Bad ("body.section." & Parent_Title
                     & ": child heading occurs more than once");
      end if;
      return Good;
   end Check_Child;

   function Is_Checklist_Line (Line : String) return Boolean
   is (Line'Length >= 6
       and then Line (Line'First) = '-'
       and then Line (Line'First + 1) = ' '
       and then Line (Line'First + 2) = '['
       and then Line (Line'First + 3) in ' ' | 'x' | 'X'
       and then Line (Line'First + 4) = ']'
       and then Line (Line'First + 5) = ' ');

   function Check_Lead_And_Checklist
     (Body_Rule : Value; Markdown : String; Headings : Heading_Array;
      H1        : Heading) return Note_Schema.Check_Result
   is
      Have_Heading : Boolean := False;
      Checklist    : Heading := H1;
      Have_Lead    : Boolean := False;
      Count        : Natural := 0;
      Nested       : Boolean := False;
      In_Fence     : Boolean := False;
   begin
      for H of Headings loop
         if H.Level = 2 and then To_String (H.Title) = "Checklist" then
            Have_Heading := True;
            Checklist := H;
            exit;
         end if;
      end loop;

      declare
         Lead_End : constant Natural :=
           Natural'Max (H1.Content_Start,
                        (if Have_Heading then Checklist.Line_Start
                         else H1.Content_End));

         procedure Lead_Line (Line : String) is
            Text : constant String :=
              Trim_Of (Without_CR (Line), " " & Character'Val (9));
         begin
            if Text'Length > 0 and then Text (Text'First) not in '#' | '>' then
               Have_Lead := True;
            end if;
         end Lead_Line;

         procedure Scan_Lead is new Each_Line (Lead_Line);
      begin
         Scan_Lead (Slice (Markdown, H1.Content_Start, Lead_End));
      end;

      if Have_Heading then
         declare
            procedure Item_Line (Line : String) is
               Raw  : constant String := Without_CR (Line);
               Text : constant String :=
                 Trim_Of (Raw, " " & Character'Val (9));
            begin
               if Nested then
                  return;
               end if;
               if Note_Text.Is_Fence_Line (Text) then
                  In_Fence := not In_Fence;
               elsif not In_Fence
                 and then Text'Length > 0
                 and then Is_Checklist_Line (Text)
               then
                  if Raw'Length /= Text'Length then
                     Nested := True;
                  else
                     Count := Count + 1;
                  end if;
               end if;
            end Item_Line;

            procedure Scan_Items is new Each_Line (Item_Line);
         begin
            Scan_Items
              (Slice (Markdown, Checklist.Content_Start,
                      Checklist.Content_End));
         end;
      end if;

      if Nested then
         return Bad ("body.checklist: nested checklist items are not allowed");
      end if;
      if Has (Body_Rule, "lead")
        and then Bool_At (Member_Value (Body_Rule, "lead"), "required", False)
        and then not Have_Lead
      then
         return Bad ("body.lead: prose before the checklist is required");
      end if;
      if Has (Body_Rule, "checklist") then
         declare
            Rule : constant Value := Member_Value (Body_Rule, "checklist");
            Min  : constant Long_Long_Integer :=
              Int_At (Rule, "min_items",
                      (if Bool_At (Rule, "required", False) then 1 else 0));
         begin
            if Long_Long_Integer (Count) < Min then
               return Bad ("body.checklist: expected at least " & Img (Min)
                           & " flat item(s), found " & Img (Count));
            end if;
         end;
      end if;
      return Good;
   end Check_Lead_And_Checklist;

   function Check_Section
     (Rule : Value; Headings : Heading_Array; Markdown : String;
      Previous : in out Natural; Have_Previous : in out Boolean)
      return Note_Schema.Check_Result
   is
      Title : constant String := String_At (Rule, "title");
      Level : constant Long_Long_Integer := Int_At (Rule, "level", 2);
      Count : Natural := 0;
      First : Natural := 0;  --  index of the first match
      Prefix : constant String := "body.section." & Title & ": ";
   begin
      for I in Headings'Range loop
         if Long_Long_Integer (Headings (I).Level) = Level
           and then To_String (Headings (I).Title) = Title
         then
            Count := Count + 1;
            if First = 0 then
               First := I;
            end if;
         end if;
      end loop;

      if Bool_At (Rule, "required", False) and then Count = 0 then
         return Bad (Prefix & "required heading is missing");
      end if;
      declare
         Maximum : constant Long_Long_Integer :=
           Int_At (Rule, "max_occurs", 1);
      begin
         if Long_Long_Integer (Count) > Maximum then
            return Bad (Prefix & "occurs " & Img (Count)
                        & " times; maximum is " & Img (Maximum));
         end if;
      end;
      if First = 0 then
         return Good;
      end if;

      declare
         H       : constant Heading := Headings (First);
         Content : constant String :=
           Trim_Blank (Slice (Markdown, H.Content_Start, H.Content_End));
      begin
         if Have_Previous and then H.Line_Start < Previous then
            return Bad (Prefix
                        & "declared sections are out of relative order");
         end if;
         Previous := H.Line_Start;
         Have_Previous := True;
         if Bool_At (Rule, "non_empty", False) and then Content'Length = 0 then
            return Bad (Prefix & "must not be empty");
         end if;
         if Has (Rule, "content")
           and then Has (Member_Value (Rule, "content"), "enum")
           and then not In_List
                          (Content,
                           Member_Value (Member_Value (Rule, "content"),
                                         "enum"))
         then
            return Bad (Prefix & "content '" & Content & "' is not allowed");
         end if;
         if Has (Rule, "children") then
            declare
               Children : constant Value := Member_Value (Rule, "children");
            begin
               for I in 1 .. Length (Children) loop
                  declare
                     Result : constant Note_Schema.Check_Result :=
                       Check_Child (Element (Children, I), Headings, Markdown,
                                    H);
                  begin
                     if not Result.Valid then
                        return Result;
                     end if;
                  end;
               end loop;
            end;
         end if;
      end;
      return Good;
   end Check_Section;

   function Check_Body
     (Schema : Value; Note : String) return Note_Schema.Check_Result
   is
      Body_Rule : constant Value := Member_Value (Schema, "body");
      Markdown  : constant String :=
        Slice (Note, Frontmatter.Body_After (Note).First,
               Frontmatter.Body_After (Note).Stop);
      Headings  : constant Heading_Array := Collect_Headings (Markdown);
      H1_Rule   : constant Value := Member_Value (Body_Rule, "h1");
      H1_Count  : Natural := 0;
      H1_Index  : Natural := 0;
      Wanted    : constant Long_Long_Integer := Int_At (H1_Rule, "count", 1);
      Title     : constant Lookup := Lookup_Field (Note, "title");
   begin
      for I in Headings'Range loop
         if Headings (I).Level = 1 then
            H1_Count := H1_Count + 1;
            if H1_Index = 0 then
               H1_Index := I;
            end if;
         end if;
      end loop;
      if Long_Long_Integer (H1_Count) /= Wanted then
         return Bad ("body.h1: expected " & Img (Wanted) & ", found "
                     & Img (H1_Count));
      end if;
      if H1_Index = 0 then
         return Bad ("body.h1: required heading is missing");
      end if;
      declare
         H1 : constant Heading := Headings (H1_Index);
      begin
         if To_String (H1.Title)
              /= (if Title.Found and then Title.Value.Kind = String_Field
                  then To_String (Title.Value.Text) else "")
         then
            return Bad ("body.h1: must equal frontmatter.title");
         end if;

         if Has (Body_Rule, "preamble") then
            declare
               Rules : constant Value := Member_Value (Body_Rule, "preamble");
            begin
               for I in 1 .. Length (Rules) loop
                  declare
                     Result : constant Note_Schema.Check_Result :=
                       Check_Preamble (Element (Rules, I), Markdown, H1);
                  begin
                     if not Result.Valid then
                        return Result;
                     end if;
                  end;
               end loop;
            end;
         end if;

         if Has (Body_Rule, "sections") then
            declare
               Rules         : constant Value :=
                 Member_Value (Body_Rule, "sections");
               Previous      : Natural := 0;
               Have_Previous : Boolean := False;
            begin
               for I in 1 .. Length (Rules) loop
                  if Has_String (Element (Rules, I), "title") then
                     declare
                        Result : constant Note_Schema.Check_Result :=
                          Check_Section
                            (Element (Rules, I), Headings, Markdown, Previous,
                             Have_Previous);
                     begin
                        if not Result.Valid then
                           return Result;
                        end if;
                     end;
                  end if;
               end loop;
            end;
         end if;

         if Has (Body_Rule, "lead") or else Has (Body_Rule, "checklist") then
            return
              Check_Lead_And_Checklist (Body_Rule, Markdown, Headings, H1);
         end if;
      end;
      return Good;
   end Check_Body;

   ---------------------------------------------------------------------------
   --  Rules
   ---------------------------------------------------------------------------

   --  The rule of a `checks:` or `lints:` entry, or nothing for an entry that
   --  has none.
   procedure Rule_Of
     (Entry_Value : Value; Found : out Boolean; Rule : out Value;
      Shape       : out Schema_Rules.Entry_Shape)
   is
      Converted : Schema_Rules.Rule_Result;
   begin
      Shape := Schema_Rules.Shape_Of (Entry_Value);
      Found := False;
      Rule := Null_Value;
      if not Shape.Is_Rule then
         return;
      end if;
      Converted := Schema_Rules.To_Rule (Schema_Rules.Rule_Object (Shape));
      if Converted.Ok then
         Found := True;
         Rule := Converted.Rule;
      end if;
   end Rule_Of;

   function Failure_Message
     (Entry_Value : Value; Shape : Schema_Rules.Entry_Shape; Rule : Value)
      return String is
   begin
      if Shape.Message_Present and then not Shape.Message_Invalid then
         return As_String (Member_Value (Entry_Value, "message"));
      end if;
      declare
         Text : constant String := To_String (Rule);
      begin
         return "rule failed: "
           & Text (Text'First
                   .. Text'First
                      + Natural'Min (Text'Length, Max_Rule_Text) - 1);
      end;
   end Failure_Message;

   function Holds (Rule : Value; Data : Value) return Boolean
   is (JSON_Logic.Truthy
         (JSON_Logic.Evaluate
            (Rule, (Data => Data, others => <>),
             Note_Operators.Operators)));

   function Check_Rules
     (Schema : Value; Note, Path : String; Ctx : Context)
      return Note_Schema.Check_Result
   is
      Checks : constant Value := Member_Value (Schema, "checks");
   begin
      if Length (Checks) = 0 then
         return Good;
      end if;
      declare
         Data : constant Value := Data_Tree (Path, Note, Ctx);
      begin
         for I in 1 .. Length (Checks) loop
            declare
               Entry_Value : constant Value := Element (Checks, I);
               Found       : Boolean;
               Rule        : Value;
               Shape       : Schema_Rules.Entry_Shape;
            begin
               Rule_Of (Entry_Value, Found, Rule, Shape);
               if Found and then not Holds (Rule, Data) then
                  return Bad (Failure_Message (Entry_Value, Shape, Rule));
               end if;
            end;
         end loop;
      end;
      return Good;
   end Check_Rules;

   ---------------------------------------------------------------------------
   --  Public
   ---------------------------------------------------------------------------

   function Validate_Note
     (Schema : JSON.Value;
      Note   : String;
      Path   : String;
      Ctx    : Note_Model.Context) return Note_Schema.Check_Result
   is
   begin
      if not Frontmatter.Has_Frontmatter (Note) then
         return
           Bad ("frontmatter: opening and closing delimiters are required");
      end if;
      declare
         Result : Note_Schema.Check_Result :=
           Check_Frontmatter (Schema, Note, Ctx);
      begin
         if Result.Valid then
            Result := Check_Body (Schema, Note);
         end if;
         if Result.Valid then
            Result := Check_Rules (Schema, Note, Path, Ctx);
         end if;
         return Result;
      end;
   end Validate_Note;

   function Lint_Note
     (Schema : JSON.Value; Note, Path : String) return Finding_Vectors.Vector
   is
      Result : Finding_Vectors.Vector;
   begin
      if not Has (Schema, "lints") then
         return Result;
      end if;
      declare
         Lints : constant Value := Member_Value (Schema, "lints");
         Data  : constant Value := Data_Tree (Path, Note, (others => <>));
      begin
         for I in 1 .. Length (Lints) loop
            declare
               Entry_Value : constant Value := Element (Lints, I);
               Level       : constant Note_Schema.Maybe_Severity :=
                 Note_Schema.Parse_Severity
                   (String_At (Entry_Value, "severity"));
               Found       : Boolean;
               Rule        : Value;
               Shape       : Schema_Rules.Entry_Shape;
            begin
               if Level.Found and then Level.Level /= Note_Schema.Ignore then
                  Rule_Of (Entry_Value, Found, Rule, Shape);
                  if Found and then not Holds (Rule, Data) then
                     Result.Append
                       (Finding'
                          (Message =>
                             To_Unbounded_String
                               (Failure_Message (Entry_Value, Shape, Rule)),
                           Level   => Level.Level));
                  end if;
               end if;
            end;
         end loop;
      end;
      return Result;
   end Lint_Note;

   function Schema_Id (Note : String) return Maybe_Text is
      Block    : constant Frontmatter.Block := Frontmatter.Locate (Note);
      Position : Natural;
      Line     : Frontmatter.Span;
      Found    : Boolean;
   begin
      if not Block.Present then
         return (Found => False);
      end if;
      Position := Block.Lines_Start;
      loop
         Frontmatter.Next_Line (Note, Block, Position, Line, Found);
         exit when not Found;
         declare
            Text  : constant String := Slice (Note, Line.First, Line.Stop);
            Colon : Natural := 0;
         begin
            if Text'Length > 0
              and then Text (Text'First) not in ' ' | Character'Val (9) | '#'
            then
               for I in Text'Range loop
                  if Text (I) = ':' then
                     Colon := I;
                     exit;
                  end if;
               end loop;
            end if;
            if Colon > 0
              and then Trim_Of (Text (Text'First .. Colon - 1), " ") = "schema"
            then
               declare
                  Tail  : constant String := Text (Colon + 1 .. Text'Last);
                  Value : constant String :=
                    Trim_Of
                      (Tail (Tail'First .. Tail'First
                             + Note_Text.Strip_Trailing_Comment (Tail) - 1),
                       " ");
               begin
                  if Value'Length >= 2
                    and then Value (Value'First) in ''' | '"'
                    and then Value (Value'Last) = Value (Value'First)
                  then
                     return
                       (Found => True,
                        Text  => To_Unbounded_String
                                   (Value (Value'First + 1
                                           .. Value'Last - 1)));
                  elsif Value'Length = 0
                    or else Value (Value'First) in '[' | '{'
                  then
                     return (Found => False);
                  end if;
                  return (Found => True, Text => To_Unbounded_String (Value));
               end;
            end if;
         end;
      end loop;
      return (Found => False);
   end Schema_Id;

end Synapse.Core.Note_Check;
