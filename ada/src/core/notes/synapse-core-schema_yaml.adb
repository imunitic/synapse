with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.Schema_YAML_Lexical;
with Synapse.Core.UTF8;

package body Synapse.Core.Schema_YAML with SPARK_Mode => Off is

   package Lexical renames Synapse.Core.Schema_YAML_Lexical;

   use JSON;

   package Value_Vectors is new Ada.Containers.Vectors (Positive, Value);

   package Member_Vectors is new Ada.Containers.Vectors (Positive, Member);

   LF  : constant Character := Character'Val (10);
   CR  : constant Character := Character'Val (13);
   HT  : constant Character := Character'Val (9);

   ---------------------------------------------------------------------------
   --  Text helpers
   ---------------------------------------------------------------------------

   --  S without leading and trailing spaces (a slice; bounds preserved).
   function Trim (S : String) return String is
      First : Natural := S'First;
      Last  : Integer := S'Last;
   begin
      while First <= Last and then S (First) = ' ' loop
         First := First + 1;
      end loop;
      while Last >= First and then S (Last) = ' ' loop
         Last := Last - 1;
      end loop;
      return S (First .. Last);
   end Trim;

   function Make_Object_From (Members : Member_Vectors.Vector) return Value is
      List : Member_Array (1 .. Natural (Members.Length));
   begin
      for I in List'Range loop
         List (I) := Members (I);
      end loop;
      return Make_Object (List);
   end Make_Object_From;

   function Make_Array_From (Items : Value_Vectors.Vector) return Value is
      List : Value_Array (1 .. Natural (Items.Length));
   begin
      for I in List'Range loop
         List (I) := Items (I);
      end loop;
      return Make_Array (List);
   end Make_Array_From;

   function Index_Of (Members : Member_Vectors.Vector; Key : String)
      return Natural is
   begin
      for I in Members.First_Index .. Members.Last_Index loop
         if Ada.Strings.Unbounded.To_String (Members (I).Key) = Key then
            return I;
         end if;
      end loop;
      return 0;
   end Index_Of;

   ---------------------------------------------------------------------------
   --  Parsing
   ---------------------------------------------------------------------------

   function Parse (Source : String) return Parse_Result is

      Failure    : exception;
      Error_Kind : Parse_Fault := Empty_Document;
      Error_Line : Natural := 0;

      procedure Fail (Kind : Parse_Fault; Line : Natural) is
      begin
         Error_Kind := Kind;
         Error_Line := Line;
         raise Failure;
      end Fail;

      --  A kept line: its indentation, where its text sits in Source, and its
      --  1-based source line number.
      type Source_Line is record
         Indent : Natural;
         First  : Positive;
         Last   : Natural;
         Number : Positive;
      end record;

      package Line_Vectors is new
        Ada.Containers.Vectors (Positive, Source_Line);

      Lines : Line_Vectors.Vector;
      Index : Positive := 1;

      function Text (L : Source_Line) return String
      is (Source (L.First .. L.Last));

      ------------------------------------------------------------------------
      --  Lines
      ------------------------------------------------------------------------

      procedure Read_Lines is
         Pos    : Positive := Source'First;
         Number : Natural := 0;
         Done   : Boolean := Source'Length = 0;
      begin
         while not Done loop
            declare
               Stop : Natural := Pos;
            begin
               while Stop <= Source'Last and then Source (Stop) /= LF loop
                  Stop := Stop + 1;
               end loop;
               Number := Number + 1;

               declare
                  Raw_Last : Integer := Stop - 1;
               begin
                  if Raw_Last >= Pos and then Source (Raw_Last) = CR then
                     Raw_Last := Raw_Last - 1;
                  end if;

                  for I in Pos .. Raw_Last loop
                     if Source (I) = HT then
                        Fail (Tab_Indent, Number);
                     end if;
                  end loop;

                  declare
                     Raw : constant String := Source (Pos .. Raw_Last);
                     Cut : constant Natural := Lexical.Comment_Start (Raw);
                     Last : Integer := Pos + Cut - 1;
                  begin
                     while Last >= Pos and then Source (Last) = ' ' loop
                        Last := Last - 1;
                     end loop;
                     declare
                        First : Natural := Pos;
                     begin
                        while First <= Last and then Source (First) = ' ' loop
                           First := First + 1;
                        end loop;
                        if First <= Last then
                           declare
                              Content : constant String :=
                                Source (First .. Last);
                              Indent  : constant Natural := First - Pos;
                           begin
                              if Content = "---" or else Content = "..." then
                                 Fail (Multiple_Documents, Number);
                              end if;
                              if Indent mod 2 /= 0 then
                                 Fail (Invalid_Indent, Number);
                              end if;
                              Lines.Append
                                (Source_Line'
                                   (Indent => Indent,
                                    First  => First,
                                    Last   => Last,
                                    Number => Number));
                           end;
                        end if;
                     end;
                  end;
               end;

               if Stop > Source'Last then
                  Done := True;
               else
                  Pos := Stop + 1;
                  Done := Pos > Source'Last + 1;
               end if;
            end;
         end loop;

         if Lines.Is_Empty then
            Fail (Empty_Document, 0);
         end if;
         if Lines (1).Indent /= 0 then
            Fail (Unexpected_Indent, Lines (1).Number);
         end if;
      end Read_Lines;

      ------------------------------------------------------------------------
      --  Scalars
      ------------------------------------------------------------------------

      function Checked_String (S : String; Line : Natural) return Value is
      begin
         if S'Length > 0 and then not UTF8.Is_Valid (S) then
            Fail (Invalid_UTF8, Line);
         end if;
         return Make_String (S);
      end Checked_String;

      function Parse_Quoted (Text : String; Line : Natural) return Value is
         Quote : constant Character := Text (Text'First);
      begin
         if Text'Length < 2 or else Text (Text'Last) /= Quote then
            Fail (Unterminated_String, Line);
         end if;

         declare
            Inner : constant String := Text (Text'First + 1 .. Text'Last - 1);
         begin
            if Quote = ''' then
               for C of Inner loop
                  if C = ''' then
                     Fail (Invalid_Escape, Line);
                  end if;
               end loop;
               return Checked_String (Inner, Line);
            end if;

            declare
               Result : Ada.Strings.Unbounded.Unbounded_String;
               I      : Natural := Inner'First;
            begin
               while I <= Inner'Last loop
                  if Inner (I) /= '\' then
                     Ada.Strings.Unbounded.Append (Result, Inner (I));
                  else
                     I := I + 1;
                     if I > Inner'Last then
                        Fail (Invalid_Escape, Line);
                     end if;
                     case Inner (I) is
                        when '\' | '"' | '/' =>
                           Ada.Strings.Unbounded.Append (Result, Inner (I));

                        when 'n' =>
                           Ada.Strings.Unbounded.Append (Result, LF);

                        when 'r' =>
                           Ada.Strings.Unbounded.Append (Result, CR);

                        when 't' =>
                           Ada.Strings.Unbounded.Append (Result, HT);

                        when others =>
                           Fail (Invalid_Escape, Line);
                     end case;
                  end if;
                  I := I + 1;
               end loop;
               return
                 Checked_String
                   (Ada.Strings.Unbounded.To_String (Result), Line);
            end;
         end;
      end Parse_Quoted;

      function Parse_Scalar (Raw : String; Line : Natural) return Value;

      function Parse_Flow_List (Text : String; Line : Natural) return Value is
      begin
         if Text'Length < 2 or else Text (Text'Last) /= ']' then
            Fail (Invalid_Flow_List, Line);
         end if;

         declare
            Inner : constant String :=
              Trim (Text (Text'First + 1 .. Text'Last - 1));
            Items : Value_Vectors.Vector;
         begin
            if Inner'Length /= 0 then
               declare
                  Start   : Natural := Inner'First;
                  Quote   : Character := Character'Val (0);
                  Escaped : Boolean := False;
               begin
                  for I in Inner'First .. Inner'Last + 1 loop
                     if I > Inner'Last
                       or else (Quote = Character'Val (0)
                                and then Inner (I) = ',')
                     then
                        declare
                           Item : constant String :=
                             Trim (Inner (Start .. I - 1));
                        begin
                           if Item'Length = 0 then
                              Fail (Invalid_Flow_List, Line);
                           end if;
                           Items.Append (Parse_Scalar (Item, Line));
                           Start := I + 1;
                        end;
                     else
                        declare
                           C : constant Character := Inner (I);
                        begin
                           if Quote /= Character'Val (0) then
                              if Quote = '"' and then not Escaped
                                and then C = '\'
                              then
                                 Escaped := True;
                              else
                                 if not Escaped and then C = Quote then
                                    Quote := Character'Val (0);
                                 end if;
                                 Escaped := False;
                              end if;
                           elsif C in ''' | '"' then
                              Quote := C;
                           elsif C in '[' | ']' | '{' | '}' then
                              Fail (Invalid_Flow_List, Line);
                           end if;
                        end;
                     end if;
                  end loop;
                  if Quote /= Character'Val (0) then
                     Fail (Unterminated_String, Line);
                  end if;
               end;
            end if;
            return Make_Array_From (Items);
         end;
      end Parse_Flow_List;

      function Parse_Scalar (Raw : String; Line : Natural) return Value is
         Text : constant String := Trim (Raw);
      begin
         if Text'Length = 0 then
            Fail (Empty_Value, Line);
         end if;

         declare
            First : constant Character := Text (Text'First);
         begin
            if First in '&' | '*' then
               Fail (Anchor_Or_Alias, Line);
            elsif First = '!' then
               Fail (Custom_Tag, Line);
            elsif First in '|' | '>' then
               Fail (Block_Scalar, Line);
            elsif First = '{' then
               Fail (Flow_Map, Line);
            elsif First = '[' then
               return Parse_Flow_List (Text, Line);
            elsif First in ''' | '"' then
               return Parse_Quoted (Text, Line);
            end if;
         end;

         if Lexical.Has_Anchor_Mark (Text) then
            Fail (Anchor_Or_Alias, Line);
         elsif Text = "true" then
            return Make_Boolean (True);
         elsif Text = "false" then
            return Make_Boolean (False);
         elsif Text = "null" then
            return Null_Value;
         elsif Lexical.Is_Ambiguous_Implicit (Text) then
            Fail (Implicit_Type, Line);
         elsif Lexical.Looks_Numeric (Text) then
            if Text'Length > 1
              and then (Text (Text'First) = '0'
                        or else (Text (Text'First) = '-'
                                 and then Text'Length > 2
                                 and then Text (Text'First + 1) = '0'))
            then
               Fail (Implicit_Type, Line);
            end if;
            begin
               return Make_Integer (Long_Long_Integer'Value (Text));
            exception
               when Constraint_Error =>
                  Fail (Invalid_Integer, Line);
            end;
         end if;
         return Checked_String (Text, Line);
      end Parse_Scalar;

      ------------------------------------------------------------------------
      --  Blocks
      ------------------------------------------------------------------------

      --  Key and value text of a `key: value` string, or not Ok.
      procedure Split_Pair
        (Text      : String;
         Ok        : out Boolean;
         Why       : out Parse_Fault;
         Key_Last  : out Integer;
         Value_At  : out Natural)
      is
         Colon : constant Lexical.Colon := Lexical.Pair_Colon (Text);
      begin
         Ok := False;
         Why := Malformed_Mapping;
         Key_Last := Text'First - 1;
         Value_At := Text'Last + 1;
         if Colon.Stray_Bracket then
            Why := Invalid_Flow_List;
         elsif Colon.Found then
            declare
               At_Colon : constant Natural := Text'First + Colon.Offset;
               Key      : constant String :=
                 Trim (Text (Text'First .. At_Colon - 1));
            begin
               if Lexical.Valid_Key (Key) then
                  Ok := True;
                  Key_Last := At_Colon - 1;
                  Value_At := At_Colon + 1;
               end if;
            end;
         end if;
      end Split_Pair;

      function Parse_Block (Indent, Depth : Natural) return Value;

      --  The value of a `key:` with nothing after it: the block that follows,
      --  indented more than the key's own line.
      function Nested_Block
        (Indent, Depth : Natural; Line : Natural) return Value is
      begin
         if Index > Lines.Last_Index
           or else Lines (Index).Indent <= Indent
         then
            Fail (Empty_Value, Line);
         end if;
         return Parse_Block (Lines (Index).Indent, Depth + 1);
      end Nested_Block;

      procedure Parse_Map_Members
        (Indent, Depth : Natural; Members : in out Member_Vectors.Vector) is
      begin
         if Depth > Max_Depth then
            Fail (Too_Deep, Lines (Index).Number);
         end if;
         while Index <= Lines.Last_Index loop
            declare
               L : constant Source_Line := Lines (Index);
            begin
               exit when L.Indent < Indent;
               if L.Indent > Indent then
                  Fail (Unexpected_Indent, L.Number);
               end if;
               if Lexical.Is_List_Line (Text (L)) then
                  Fail (Mixed_Collection, L.Number);
               end if;
               Index := Index + 1;

               declare
                  Line_Text : constant String := Text (L);
                  Ok        : Boolean;
                  Why       : Parse_Fault;
                  Key_Last  : Integer;
                  Value_At  : Natural;
               begin
                  Split_Pair (Line_Text, Ok, Why, Key_Last, Value_At);
                  if not Ok then
                     Fail (Why, L.Number);
                  end if;
                  declare
                     Key   : constant String :=
                       Trim (Line_Text (Line_Text'First .. Key_Last));
                     Raw   : constant String :=
                       Trim (Line_Text (Value_At .. Line_Text'Last));
                     Child : Value;
                  begin
                     if Index_Of (Members, Key) /= 0 then
                        Fail (Duplicate_Key, L.Number);
                     end if;
                     if Raw'Length = 0 then
                        Child := Nested_Block (Indent, Depth, L.Number);
                     else
                        Child := Parse_Scalar (Raw, L.Number);
                     end if;
                     Members.Append
                       (Member'
                          (Key  => Ada.Strings.Unbounded.To_Unbounded_String
                                     (Key),
                           Item => Child));
                  end;
               end;
            end;
         end loop;
      end Parse_Map_Members;

      function Parse_Map (Indent, Depth : Natural) return Value is
         Members : Member_Vectors.Vector;
      begin
         Parse_Map_Members (Indent, Depth, Members);
         return Make_Object_From (Members);
      end Parse_Map;

      function Parse_List (Indent, Depth : Natural) return Value is
         Items : Value_Vectors.Vector;
      begin
         if Depth > Max_Depth then
            Fail (Too_Deep, Lines (Index).Number);
         end if;
         while Index <= Lines.Last_Index loop
            declare
               L : constant Source_Line := Lines (Index);
            begin
               exit when L.Indent < Indent;
               if L.Indent > Indent then
                  Fail (Unexpected_Indent, L.Number);
               end if;
               if not Lexical.Is_List_Line (Text (L)) then
                  Fail (Mixed_Collection, L.Number);
               end if;
               Index := Index + 1;

               declare
                  Line_Text : constant String := Text (L);
                  Rest      : constant String :=
                    (if Line_Text'Length > 1
                     then Trim (Line_Text (Line_Text'First + 1
                                           .. Line_Text'Last))
                     else "");
                  Ok        : Boolean;
                  Why       : Parse_Fault;
                  Key_Last  : Integer;
                  Value_At  : Natural;
               begin
                  if Rest'Length = 0 then
                     Fail (Empty_Value, L.Number);
                  end if;
                  Split_Pair (Rest, Ok, Why, Key_Last, Value_At);
                  if not Ok then
                     --  Not a `key: value` item: a scalar.
                     Items.Append (Parse_Scalar (Rest, L.Number));
                  else
                     declare
                        Members : Member_Vectors.Vector;
                        Key     : constant String :=
                          Trim (Rest (Rest'First .. Key_Last));
                        Raw     : constant String :=
                          Trim (Rest (Value_At .. Rest'Last));
                        Child   : Value;
                     begin
                        if Raw'Length = 0 then
                           Child := Nested_Block (Indent, Depth, L.Number);
                        else
                           Child := Parse_Scalar (Raw, L.Number);
                        end if;
                        Members.Append
                          (Member'
                             (Key  => Ada.Strings.Unbounded.To_Unbounded_String
                                        (Key),
                              Item => Child));

                        --  The item's other fields sit two columns past the
                        --  dash.
                        if Index <= Lines.Last_Index
                          and then Lines (Index).Indent = Indent + 2
                          and then not Lexical.Is_List_Line
                                         (Text (Lines (Index)))
                        then
                           declare
                              Remainder : Member_Vectors.Vector;
                           begin
                              Parse_Map_Members
                                (Indent + 2, Depth + 1, Remainder);
                              for M of Remainder loop
                                 if Index_Of
                                      (Members,
                                       Ada.Strings.Unbounded.To_String (M.Key))
                                    /= 0
                                 then
                                    Fail (Duplicate_Key, L.Number);
                                 end if;
                                 Members.Append (M);
                              end loop;
                           end;
                        end if;
                        Items.Append (Make_Object_From (Members));
                     end;
                  end if;
               end;
            end;
         end loop;
         return Make_Array_From (Items);
      end Parse_List;

      function Parse_Block (Indent, Depth : Natural) return Value is
      begin
         if Index > Lines.Last_Index then
            Fail (Empty_Value, Lines (Lines.Last_Index).Number);
         end if;
         if Lines (Index).Indent /= Indent then
            Fail (Unexpected_Indent, Lines (Index).Number);
         end if;
         if Depth > Max_Depth then
            Fail (Too_Deep, Lines (Index).Number);
         end if;
         if Lexical.Is_List_Line (Text (Lines (Index))) then
            return Parse_List (Indent, Depth);
         end if;
         return Parse_Map (Indent, Depth);
      end Parse_Block;

   begin
      Read_Lines;
      declare
         Root : constant Value := Parse_Block (0, 0);
      begin
         if Index <= Lines.Last_Index then
            Fail (Unexpected_Indent, Lines (Index).Number);
         end if;
         return Parse_Results.Success (Root);
      end;

   exception
      when Failure =>
         return
           Parse_Results.Failure ((Fault => Error_Kind, Line => Error_Line));
   end Parse;

   ---------------------------------------------------------------------------
   --  Merging
   ---------------------------------------------------------------------------

   function Merge (Base, Override : Value) return Merge_Result is

      Failure    : exception;
      Error_Kind : Merge_Fault := Patch_On_Non_List;

      procedure Fail (Kind : Merge_Fault) is
      begin
         Error_Kind := Kind;
         raise Failure;
      end Fail;

      function Is_Patch_Entry (V : Value) return Boolean
      is (Kind_Of (V) = JSON_Object and then Has_Member (V, "match"));

      --  A list with at least one `match` entry is a patch list.
      function Is_Patch_List (V : Value) return Boolean is
      begin
         if Kind_Of (V) /= JSON_Array then
            return False;
         end if;
         for I in 1 .. Length (V) loop
            if Is_Patch_Entry (Element (V, I)) then
               return True;
            end if;
         end loop;
         return False;
      end Is_Patch_List;

      function Merge_Value (B, O : Value) return Value;

      function Merge_Maps (B, O : Value) return Value is
         Members : Member_Vectors.Vector;
      begin
         for I in 1 .. Length (B) loop
            declare
               Key : constant String := Member_Key (B, I);
               Mine : constant Value := Member_At (B, I);
            begin
               if Has_Member (O, Key) then
                  declare
                     Theirs : constant Value := Member_Value (O, Key);
                  begin
                     --  A null in the override removes the key.
                     if Kind_Of (Theirs) /= JSON_Null then
                        Members.Append
                          (Member'
                             (Key  => Ada.Strings.Unbounded.To_Unbounded_String
                                        (Key),
                              Item => Merge_Value (Mine, Theirs)));
                     end if;
                  end;
               else
                  Members.Append
                    (Member'
                        (Key  =>
                           Ada.Strings.Unbounded.To_Unbounded_String (Key),
                        Item => Mine));
               end if;
            end;
         end loop;

         for I in 1 .. Length (O) loop
            declare
               Key    : constant String := Member_Key (O, I);
               Theirs : constant Value := Member_At (O, I);
            begin
               if not Has_Member (B, Key)
                 and then Kind_Of (Theirs) /= JSON_Null
               then
                  --  A patch with no list of the base's to patch.
                  if Is_Patch_List (Theirs) then
                     Fail (Patch_On_Non_List);
                  end if;
                  Members.Append
                    (Member'
                        (Key  =>
                           Ada.Strings.Unbounded.To_Unbounded_String (Key),
                        Item => Theirs));
               end if;
            end;
         end loop;
         return Make_Object_From (Members);
      end Merge_Maps;

      --  Every field of Pattern appears in Entry with an equal value.
      function Matches (Candidate, Pattern : Value) return Boolean is
      begin
         if Kind_Of (Candidate) /= JSON_Object then
            return False;
         end if;
         for I in 1 .. Length (Pattern) loop
            declare
               Key : constant String := Member_Key (Pattern, I);
            begin
               if not Has_Member (Candidate, Key)
                 or else Member_Value (Candidate, Key)
                         /= Member_At (Pattern, I)
               then
                  return False;
               end if;
            end;
         end loop;
         return True;
      end Matches;

      function Merge_List_Patch (B, Patches : Value) return Value is
         Working : Value_Vectors.Vector;
      begin
         if Kind_Of (B) /= JSON_Array then
            Fail (Patch_On_Non_List);
         end if;
         for I in 1 .. Length (B) loop
            Working.Append (Element (B, I));
         end loop;

         for P in 1 .. Length (Patches) loop
            declare
               Patch : constant Value := Element (Patches, P);
            begin
               if not Is_Patch_Entry (Patch) then
                  Fail (Mixed_Patch_List);
               end if;
               declare
                  Pattern : constant Value := Member_Value (Patch, "match");
                  Delta_Members : Member_Vectors.Vector;
                  Found   : Natural := 0;
                  I       : Natural := 1;
               begin
                  if Kind_Of (Pattern) /= JSON_Object then
                     Fail (Patch_Match_Not_Map);
                  end if;
                  for M in 1 .. Length (Patch) loop
                     if Member_Key (Patch, M) /= "match" then
                        Delta_Members.Append
                          (Member'
                             (Key  => Ada.Strings.Unbounded.To_Unbounded_String
                                        (Member_Key (Patch, M)),
                              Item => Member_At (Patch, M)));
                     end if;
                  end loop;

                  while I <= Natural (Working.Length) loop
                     if Matches (Working (I), Pattern) then
                        Found := Found + 1;
                        if Delta_Members.Is_Empty then
                           Working.Delete (I);
                        else
                           Working.Replace_Element
                             (I,
                              Merge_Maps
                                (Working (I),
                                 Make_Object_From (Delta_Members)));
                           I := I + 1;
                        end if;
                     else
                        I := I + 1;
                     end if;
                  end loop;
                  if Found = 0 then
                     Fail (Patch_Match_Not_Found);
                  end if;
               end;
            end;
         end loop;
         return Make_Array_From (Working);
      end Merge_List_Patch;

      function Merge_Value (B, O : Value) return Value is
      begin
         if Kind_Of (B) = JSON_Object and then Kind_Of (O) = JSON_Object then
            return Merge_Maps (B, O);
         elsif Is_Patch_List (O) then
            return Merge_List_Patch (B, O);
         end if;
         return O;
      end Merge_Value;

   begin
      return Merge_Results.Success (Merge_Value (Base, Override));
   exception
      when Failure =>
         return Merge_Results.Failure (Error_Kind);
   end Merge;

end Synapse.Core.Schema_YAML;
