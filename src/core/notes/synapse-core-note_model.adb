with Synapse.Core.Frontmatter;
with Synapse.Core.Note_Text;
with Synapse.Core.UTF8;

package body Synapse.Core.Note_Model is

   LF : constant Character := Character'Val (10);
   CR : constant Character := Character'Val (13);

   function Slice (Text : String; From : Frontmatter.Span) return String
   is (Text (Text'First + From.First .. Text'First + From.Stop - 1));

   function Slice (Text : String; From : Note_Text.Span) return String
   is (Text (Text'First + From.First .. Text'First + From.Stop - 1));

   function Is_Blank (S : String) return Boolean
   is (for all C of S => C = ' ');

   --  S without leading and trailing spaces.
   function Trim (S : String) return String is
      First : Natural := S'First;
      Last  : Natural := S'Last;
   begin
      while First <= Last and then S (First) = ' ' loop
         First := First + 1;
      end loop;
      while Last >= First and then S (Last) = ' ' loop
         Last := Last - 1;
      end loop;
      return S (First .. Last);
   end Trim;

   --  S without leading and trailing spaces, tabs and carriage returns.
   function Trim_Space_Tab_CR (S : String) return String is
      First : Natural := S'First;
      Last  : Natural := S'Last;
   begin
      while First <= Last and then S (First) in ' ' | Character'Val (9) | CR
      loop
         First := First + 1;
      end loop;
      while Last >= First and then S (Last) in ' ' | Character'Val (9) | CR
      loop
         Last := Last - 1;
      end loop;
      return S (First .. Last);
   end Trim_Space_Tab_CR;

   --  S without leading and trailing spaces and tabs.
   function Trim_Blanks (S : String) return String is
      First : Natural := S'First;
      Last  : Natural := S'Last;
   begin
      while First <= Last and then S (First) in ' ' | Character'Val (9) loop
         First := First + 1;
      end loop;
      while Last >= First and then S (Last) in ' ' | Character'Val (9) loop
         Last := Last - 1;
      end loop;
      return S (First .. Last);
   end Trim_Blanks;

   --  S inside one matching pair of quotes loses them.
   function Unquote (S : String) return String
   is (if S'Length >= 2
         and then S (S'First) in ''' | '"'
         and then S (S'Last) = S (S'First)
       then S (S'First + 1 .. S'Last - 1)
       else S);

   --  S with every byte sequence that is not UTF-8 replaced by U+FFFD, so it
   --  can be a JSON string.
   function Lossy (S : String) return String is
      Result : Unbounded_String;
      Pos    : Natural := S'First;
   begin
      if UTF8.Is_Valid (S) then
         return S;
      end if;
      while Pos <= S'Last loop
         declare
            Length : constant Natural :=
              (if S'Last < Positive'Last then UTF8.Sequence_Length (S, Pos)
               else 0);
         begin
            if Length = 0 then
               Append (Result, Character'Val (16#EF#));
               Append (Result, Character'Val (16#BF#));
               Append (Result, Character'Val (16#BD#));
               Pos := Pos + 1;
            else
               Append (Result, S (Pos .. Pos + Length - 1));
               Pos := Pos + Length;
            end if;
         end;
      end loop;
      return To_String (Result);
   end Lossy;

   function JSON_String (S : String) return JSON.Value
   is (JSON.Make_String (Lossy (S)));

   --  Splits a column-zero `key: value` line at its first colon. False for a
   --  line that starts with a space or tab, has no colon, or has an empty
   --  key.
   procedure Split_Line
     (Line  : String;
      Found : out Boolean;
      Key   : out Unbounded_String;
      Colon : out Natural) is
   begin
      Found := False;
      Key := Null_Unbounded_String;
      Colon := 0;
      if Line'Length = 0 or else Line (Line'First) in ' ' | Character'Val (9)
      then
         return;
      end if;
      for I in Line'Range loop
         if Line (I) = ':' then
            Colon := I;
            exit;
         end if;
      end loop;
      if Colon = 0 then
         return;
      end if;
      declare
         Name : constant String := Trim (Line (Line'First .. Colon - 1));
      begin
         Found := Name'Length > 0;
         Key := To_Unbounded_String (Name);
      end;
   end Split_Line;

   --  What follows the colon, without a trailing comment and trimmed.
   function Value_Text (Line : String; Colon : Natural) return String is
      Tail : constant String := Line (Colon + 1 .. Line'Last);
   begin
      return Trim (Tail (Tail'First .. Tail'First
                         + Note_Text.Strip_Trailing_Comment (Tail) - 1));
   end Value_Text;

   function Starts_With_Item (Child : String) return Boolean
   is (Child'Length >= 2
       and then Child (Child'First) = '-'
       and then Child (Child'First + 1) = ' ');

   --  The text of a block-list item `- text`: its comment dropped, trimmed
   --  and unquoted.
   function Item_Text (Item : String) return String is
      Tail : constant String := Item (Item'First + 2 .. Item'Last);
   begin
      return Unquote (Trim (Tail (Tail'First .. Tail'First
                            + Note_Text.Strip_Trailing_Comment (Tail) - 1)));
   end Item_Text;

   ---------------------------------------------------------------------------
   --  Typed fields
   ---------------------------------------------------------------------------

   --  The items of `[a, b]`, split at commas outside quotes. Raw starts with
   --  `[` and ends with `]`.
   function Flow_List (Raw : String) return Text_Vectors.Vector is
      Result : Text_Vectors.Vector;
      Inner  : constant String := Trim (Raw (Raw'First + 1 .. Raw'Last - 1));
      Quote  : Character := Character'Val (0);
      Start  : Natural := Inner'First;
   begin
      if Inner'Length = 0 then
         return Result;
      end if;
      for I in Inner'Range loop
         declare
            C : constant Character := Inner (I);
         begin
            if Quote /= Character'Val (0) then
               if C = Quote then
                  Quote := Character'Val (0);
               end if;
            elsif C in ''' | '"' then
               Quote := C;
            elsif C = ',' then
               Result.Append
                 (To_Unbounded_String
                    (Unquote (Trim (Inner (Start .. I - 1)))));
               Start := I + 1;
            end if;
         end;
      end loop;
      Result.Append
        (To_Unbounded_String (Unquote (Trim (Inner (Start .. Inner'Last)))));
      return Result;
   end Flow_List;

   --  The value written after a colon, typed. Raw has its comment removed and
   --  its spaces trimmed, and is not empty.
   function Scalar_Value (Raw : String) return Field_Value is
      Number : Long_Long_Integer;
      Valid  : Boolean;
   begin
      if Raw (Raw'First) = '[' then
         if Raw (Raw'Last) /= ']' then
            return (Kind => Invalid_Field);
         end if;
         return (Kind => List_Field, Items => Flow_List (Raw));
      end if;
      if Raw (Raw'First) in ''' | '"'
        and then (Raw'Length < 2 or else Raw (Raw'Last) /= Raw (Raw'First))
      then
         return (Kind => Invalid_Field);
      end if;
      if Raw = "true" then
         return (Kind => Boolean_Field, Flag => True);
      elsif Raw = "false" then
         return (Kind => Boolean_Field, Flag => False);
      end if;
      Note_Text.Parse_Decimal (Raw, Valid, Number);
      if Valid then
         return (Kind => Integer_Field, Number => Number);
      end if;
      return
        (Kind => String_Field, Text => To_Unbounded_String (Unquote (Raw)));
   end Scalar_Value;

   --  The block list that starts after Position: the indented `- item`
   --  lines, blank lines skipped. Invalid when an indented line is not an
   --  item.
   function Block_List
     (Note     : String;
      Block    : Frontmatter.Block;
      Position : in out Natural) return Field_Value
   is
      Result : Field_Value := (Kind => List_Field, Items => <>);
      Line   : Frontmatter.Span;
      Found  : Boolean;
   begin
      loop
         Frontmatter.Next_Line (Note, Block, Position, Line, Found);
         exit when not Found;
         declare
            Child : constant String := Slice (Note, Line);
         begin
            if not Is_Blank (Child) then
               exit when Child (Child'First) not in ' ' | Character'Val (9);
               declare
                  Item : constant String := Trim (Child);
               begin
                  if not Starts_With_Item (Item) then
                     return (Kind => Invalid_Field);
                  end if;
                  Result.Items.Append (To_Unbounded_String (Item_Text (Item)));
               end;
            end if;
         end;
      end loop;
      return Result;
   end Block_List;

   function Lookup_Field (Note, Name : String) return Lookup is
      Result   : Lookup;
      Block    : constant Frontmatter.Block := Frontmatter.Locate (Note);
      Position : Natural;
      Line     : Frontmatter.Span;
      Found    : Boolean;
   begin
      if not Block.Present then
         return Result;
      end if;
      Position := Block.Lines_Start;
      loop
         Frontmatter.Next_Line (Note, Block, Position, Line, Found);
         exit when not Found;
         declare
            Text      : constant String := Slice (Note, Line);
            Key_Found : Boolean := False;
            Key       : Unbounded_String;
            Colon     : Natural := 0;
         begin
            if Text'Length > 0 and then Text (Text'First) /= '#' then
               Split_Line (Text, Key_Found, Key, Colon);
            end if;

            if Key_Found and then To_String (Key) = Name then
               if Result.Found then
                  Result.Duplicate := True;
               else
                  Result.Found := True;
                  declare
                     Raw : constant String := Value_Text (Text, Colon);
                  begin
                     if Raw'Length > 0 then
                        Result.Value := Scalar_Value (Raw);
                     else
                        Result.Value := Block_List (Note, Block, Position);
                        return Result;
                     end if;
                  end;
               end if;
            end if;
         end;
      end loop;
      return Result;
   end Lookup_Field;

   function Has_Type (Value : Field_Value; Type_Name : String) return Boolean
   is (if Type_Name in "string" | "timestamp"
       then Value.Kind = String_Field
       elsif Type_Name = "list" then Value.Kind = List_Field
       elsif Type_Name = "integer" then Value.Kind = Integer_Field
       elsif Type_Name = "boolean" then Value.Kind = Boolean_Field
       else Type_Name = "any");

   function Values_Equal (A, B : Field_Value) return Boolean is
      use type Text_Vectors.Vector;
   begin
      if A.Kind /= B.Kind then
         return False;
      end if;
      case A.Kind is
         when String_Field =>
            return A.Text = B.Text;

         when Integer_Field =>
            return A.Number = B.Number;

         when Boolean_Field =>
            return A.Flag = B.Flag;

         when List_Field =>
            return A.Items = B.Items;

         when Invalid_Field =>
            return True;
      end case;
   end Values_Equal;

   ---------------------------------------------------------------------------
   --  Field order
   ---------------------------------------------------------------------------

   function Field_Positions (Note : String) return Position_Vectors.Vector is
      Result   : Position_Vectors.Vector;
      Block    : constant Frontmatter.Block := Frontmatter.Locate (Note);
      Position : Natural;
      Line     : Frontmatter.Span;
      Found    : Boolean;
   begin
      if not Block.Present then
         return Result;
      end if;
      Position := Block.Lines_Start;
      loop
         Frontmatter.Next_Line (Note, Block, Position, Line, Found);
         exit when not Found;
         declare
            Text : constant String := Slice (Note, Line);
         begin
            if Text'Length > 0
              and then Text (Text'First) not in ' ' | Character'Val (9) | '#'
            then
               for I in Text'Range loop
                  if Text (I) = ':' then
                     declare
                        Key  : constant String :=
                          Trim (Text (Text'First .. I - 1));
                        Seen : Boolean := False;
                     begin
                        for P of Result loop
                           if To_String (P.Key) = Key then
                              Seen := True;
                              exit;
                           end if;
                        end loop;
                        if not Seen then
                           Result.Append
                             (Field_Position'
                                (Key        => To_Unbounded_String (Key),
                                 Line_Start => Line.First));
                        end if;
                     end;
                     exit;
                  end if;
               end loop;
            end if;
         end;
      end loop;
      return Result;
   end Field_Positions;

   ---------------------------------------------------------------------------
   --  Headings
   ---------------------------------------------------------------------------

   function Collect_Headings (Markdown : String) return Heading_Array is
      package Heading_Vectors is new
        Ada.Containers.Vectors (Positive, Heading);

      Found    : Heading_Vectors.Vector;
      Offset   : Natural := 0;
      In_Fence : Boolean := False;
   begin
      loop
         declare
            Start : constant Positive := Markdown'First + Offset;
            Stop  : Natural := Markdown'Last + 1;
         begin
            for I in Start .. Markdown'Last loop
               if Markdown (I) = LF then
                  Stop := I;
                  exit;
               end if;
            end loop;

            declare
               Raw   : constant String := Markdown (Start .. Stop - 1);
               Line  : constant String :=
                 (if Raw'Length > 0 and then Raw (Raw'Last) = CR
                  then Raw (Raw'First .. Raw'Last - 1)
                  else Raw);
               Level : constant Natural := Note_Text.Heading_Level (Line);
            begin
               if Note_Text.Is_Fence_Line (Line) then
                  In_Fence := not In_Fence;
               elsif not In_Fence and then Level > 0 then
                  declare
                     Title : constant Note_Text.Span :=
                       Note_Text.Heading_Title (Line, Level);
                  begin
                     Found.Append
                       (Heading'(Level         => Level,
                         Title         =>
                           To_Unbounded_String (Slice (Line, Title)),
                         Line_Start    => Offset,
                         Content_Start =>
                           Natural'Min
                             (Stop - Markdown'First + 1, Markdown'Length),
                         Content_End   => Markdown'Length));
                  end;
               end if;
            end;

            exit when Stop > Markdown'Last;
            Offset := Stop - Markdown'First + 1;
         end;
      end loop;

      declare
         Result : Heading_Array (1 .. Natural (Found.Length));
      begin
         for I in Result'Range loop
            Result (I) := Found (I);
            for J in I + 1 .. Result'Last loop
               if Found (J).Level <= Found (I).Level then
                  Result (I).Content_End := Found (J).Line_Start;
                  exit;
               end if;
            end loop;
         end loop;
         return Result;
      end;
   end Collect_Headings;

   ---------------------------------------------------------------------------
   --  JSON views
   ---------------------------------------------------------------------------

   function Member (Key : String; Item : JSON.Value) return JSON.Member
   is (Key => To_Unbounded_String (Key), Item => Item);

   use type JSON.Member;

   package Member_Vectors is new
     Ada.Containers.Vectors (Positive, JSON.Member);

   function To_Object (Members : Member_Vectors.Vector) return JSON.Value is
      Items : JSON.Member_Array (1 .. Natural (Members.Length));
   begin
      for I in Items'Range loop
         Items (I) := Members (I);
      end loop;
      return JSON.Make_Object (Items);
   end To_Object;

   function To_Array (Items : Text_Vectors.Vector) return JSON.Value is
      Values : JSON.Value_Array (1 .. Natural (Items.Length));
   begin
      for I in Values'Range loop
         Values (I) := JSON_String (To_String (Items (I)));
      end loop;
      return JSON.Make_Array (Values);
   end To_Array;

   --  `[a, b]` split at every comma, or the text itself as a string.
   function Scalar_Or_List (Raw : String) return JSON.Value is
      Items : Text_Vectors.Vector;
      Start : Natural;
   begin
      if Raw'Length >= 2
        and then Raw (Raw'First) = '['
        and then Raw (Raw'Last) = ']'
      then
         declare
            Inner : constant String :=
              Trim (Raw (Raw'First + 1 .. Raw'Last - 1));
         begin
            if Inner'Length = 0 then
               return To_Array (Items);
            end if;
            Start := Inner'First;
            for I in Inner'First .. Inner'Last + 1 loop
               if I > Inner'Last or else Inner (I) = ',' then
                  Items.Append
                    (To_Unbounded_String
                       (Unquote (Trim (Inner (Start .. I - 1)))));
                  Start := I + 1;
               end if;
            end loop;
            return To_Array (Items);
         end;
      end if;
      return JSON_String (Unquote (Raw));
   end Scalar_Or_List;

   --  The `- item` lines that follow, blank lines skipped, up to the first
   --  line that is not one. Position moves past the lines it takes.
   function Plain_Block_List
     (Note     : String;
      Block    : Frontmatter.Block;
      Position : in out Natural) return Text_Vectors.Vector
   is
      Items : Text_Vectors.Vector;
   begin
      loop
         declare
            Ahead : Natural := Position;
            Next  : Frontmatter.Span;
            More  : Boolean;
         begin
            Frontmatter.Next_Line (Note, Block, Ahead, Next, More);
            exit when not More;
            declare
               Child : constant String := Slice (Note, Next);
            begin
               if Child'Length > 0 then
                  exit when Child (Child'First) not in ' ' | Character'Val (9);
                  declare
                     Item : constant String := Trim_Blanks (Child);
                  begin
                     exit when not Starts_With_Item (Item);
                     Items.Append
                       (To_Unbounded_String
                          (Unquote
                             (Trim (Item (Item'First + 2 .. Item'Last)))));
                  end;
               end if;
               Position := Ahead;
            end;
         end;
      end loop;
      return Items;
   end Plain_Block_List;

   function Frontmatter_As_JSON (Note : String) return JSON.Value is
      Members  : Member_Vectors.Vector;
      Block    : constant Frontmatter.Block := Frontmatter.Locate (Note);
      Position : Natural;
      Line     : Frontmatter.Span;
      Found    : Boolean;
   begin
      if not Block.Present then
         return JSON.Make_Object ([]);
      end if;
      Position := Block.Lines_Start;
      loop
         Frontmatter.Next_Line (Note, Block, Position, Line, Found);
         exit when not Found;
         declare
            Text      : constant String := Slice (Note, Line);
            Key_Found : Boolean;
            Key       : Unbounded_String;
            Colon     : Natural;
         begin
            Split_Line (Text, Key_Found, Key, Colon);
            if Key_Found then
               declare
                  Raw : constant String :=
                    Trim (Text (Colon + 1 .. Text'Last));
               begin
                  Members.Append
                    (Member
                       (To_String (Key),
                        (if Raw'Length > 0
                         then Scalar_Or_List (Raw)
                         else To_Array
                                (Plain_Block_List (Note, Block, Position)))));
               end;
            end if;
         end;
      end loop;
      return To_Object (Members);
   end Frontmatter_As_JSON;

   function Vocabulary_Items (Content : String) return JSON.Value is
      Items : Text_Vectors.Vector;
      Start : Natural := Content'First;
   begin
      for I in Content'First .. Content'Last + 1 loop
         if I > Content'Last or else Content (I) = LF then
            declare
               Raw  : constant String := Content (Start .. I - 1);
               Cut  : constant String :=
                 Raw (Raw'First
                      .. Raw'First + Note_Text.Strip_Trailing_Comment (Raw)
                         - 1);
               Line : constant String := Trim_Space_Tab_CR (Cut);
               Equals : Natural := 0;
            begin
               for K in Line'Range loop
                  if Line (K) = '=' then
                     Equals := K;
                     exit;
                  end if;
               end loop;
               if Line'Length > 0 then
                  Items.Append
                    (To_Unbounded_String
                       (if Equals > 0
                        then Trim_Blanks (Line (Equals + 1 .. Line'Last))
                        else Line));
               end if;
            end;
            Start := I + 1;
         end if;
      end loop;
      return To_Array (Items);
   end Vocabulary_Items;

   function Data_Tree
     (Path : String; Note : String; Ctx : Context) return JSON.Value
   is
      Body_Span : constant Frontmatter.Span := Frontmatter.Body_After (Note);
      Prose     : constant String := Slice (Note, Body_Span);
      Headings  : constant Heading_Array := Collect_Headings (Prose);
      Names     : Text_Vectors.Vector;
      Stem      : constant Note_Text.Span := Note_Text.Filename_Stem (Path);
      Creating  : constant Boolean := Ctx.Mode in Create | Migration;
      Vocabs    : Member_Vectors.Vector;

      function Epoch (Field : String) return JSON.Value is
         Field_Value : constant Lookup := Lookup_Field (Note, Field);
         Valid       : Boolean := False;
         Seconds     : Long_Long_Integer := 0;
      begin
         if Field_Value.Found and then Field_Value.Value.Kind = String_Field
         then
            Note_Text.Parse_Instant_Seconds
              (To_String (Field_Value.Value.Text), Valid, Seconds);
         end if;
         return
           (if Valid then JSON.Make_Integer (Seconds) else JSON.Null_Value);
      end Epoch;
   begin
      for H of Headings loop
         Names.Append (H.Title);
      end loop;
      for V of Ctx.Vocabularies loop
         Vocabs.Append
           (Member (To_String (V.Stem),
                    Vocabulary_Items (To_String (V.Content))));
      end loop;

      return
        JSON.Make_Object
          ([Member ("path", JSON_String (Path)),
            Member ("filename",
                    JSON.Make_Object
                      ([Member ("stem", JSON_String (Slice (Path, Stem)))])),
            Member ("frontmatter", Frontmatter_As_JSON (Note)),
            Member ("body",
                    JSON.Make_Object
                      ([Member ("prose", JSON_String (Prose)),
                        Member ("section_names", To_Array (Names))])),
            Member ("is_create", JSON.Make_Boolean (Creating)),
            Member ("id_is_unique",
                    (if Creating
                     then JSON.Make_Boolean (not Ctx.Has_Duplicate)
                     else JSON.Null_Value)),
            Member ("created_epoch", Epoch ("created")),
            Member ("updated_epoch", Epoch ("updated")),
            Member ("vocabularies", To_Object (Vocabs))]);
   end Data_Tree;

end Synapse.Core.Note_Model;
