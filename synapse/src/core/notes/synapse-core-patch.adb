with Ada.Containers.Vectors;

with Synapse.Core.Frontmatter;
with Synapse.Core.Frontmatter.Edit;

package body Synapse.Core.Patch is

   --  Every helper below takes a text that Apply or Map_Of copied into
   --  `1 .. Length` first, so its positions are indexes and not offsets.
   pragma Warnings (Off, "index for ""B"" may assume lower bound of 1");

   LF : constant Character := Character'Val (10);

   --  The text is worked on as `1 .. Length` whatever the caller's bounds.
   subtype Level_Range is Positive range 1 .. 6;

   type Heading_Info is record
      Level         : Level_Range;
      --  The trimmed title, as its bounds in the text.
      Text_First    : Positive;
      Text_Last     : Natural;
      --  The `#` that starts the heading's line.
      Line_Start    : Positive;
      --  The first byte after the heading line's line feed, or one past the
      --  end when the heading is the last line.
      Content_Start : Positive;
   end record;

   package Heading_Vectors is new Ada.Containers.Vectors
     (Positive, Heading_Info);

   function Is_Blank (C : Character) return Boolean is
     (C in ' ' | Character'Val (9));

   function Is_Blank_Or_CR (C : Character) return Boolean is
     (C in ' ' | Character'Val (9) | Character'Val (13));

   function Starts_With
     (B : String; At_Index : Positive; Part : String) return Boolean is
     (At_Index + Part'Length - 1 <= B'Last
      and then B (At_Index .. At_Index + Part'Length - 1) = Part);

   --  The index of the next line feed at or after From, or 0.
   function Next_LF (B : String; From : Positive) return Natural is
   begin
      for I in From .. B'Last loop
         if B (I) = LF then
            return I;
         end if;
      end loop;
      return 0;
   end Next_LF;

   --  Every `#` to `######` heading, in document order. A fenced code block
   --  never contributes one, whatever a line inside it starts with.
   function Scan_Headings (B : String) return Heading_Vectors.Vector is
      Result   : Heading_Vectors.Vector;
      Idx      : Positive := 1;
      In_Fence : Boolean  := False;
   begin
      while Idx <= B'Last loop
         declare
            NL       : constant Natural  := Next_LF (B, Idx);
            Line_End : constant Positive :=
              (if NL = 0 then B'Last + 1 else NL);
            First    : Positive          := Idx;
         begin
            while First < Line_End and then Is_Blank (B (First)) loop
               First := First + 1;
            end loop;
            if Starts_With (B, First, "```")
              or else Starts_With (B, First, "~~~")
            then
               In_Fence := not In_Fence;
            elsif not In_Fence then
               declare
                  Hashes : Natural := 0;
               begin
                  while Idx + Hashes < Line_End and then Hashes < 6
                    and then B (Idx + Hashes) = '#'
                  loop
                     Hashes := Hashes + 1;
                  end loop;
                  if Hashes > 0 and then Idx + Hashes < Line_End
                    and then B (Idx + Hashes) = ' '
                  then
                     declare
                        From : Positive := Idx + Hashes + 1;
                        Last : Natural  := Line_End - 1;
                     begin
                        while From <= Last and then Is_Blank_Or_CR (B (From))
                        loop
                           From := From + 1;
                        end loop;
                        while Last >= From and then Is_Blank_Or_CR (B (Last))
                        loop
                           Last := Last - 1;
                        end loop;
                        Result.Append
                          (Heading_Info'
                             (Level         => Hashes, Text_First => From,
                              Text_Last     => Last, Line_Start => Idx,
                              Content_Start =>
                                (if NL = 0 then B'Last + 1 else NL + 1)));
                     end;
                  end if;
               end;
            end if;
            exit when NL = 0;
            Idx := Line_End + 1;
         end;
      end loop;
      return Result;
   end Scan_Headings;

   --  The index of the next heading at or above Level, starting at From: the
   --  boundary that ends a section. One past the last when none follows.
   function Section_End
     (Headings : Heading_Vectors.Vector; From : Positive; Level : Level_Range)
      return Positive
   is
   begin
      for I in From .. Natural (Headings.Length) loop
         if Headings (I).Level <= Level then
            return I;
         end if;
      end loop;
      return Natural (Headings.Length) + 1;
   end Section_End;

   function Title_Is
     (B : String; H : Heading_Info; Text : String) return Boolean is
     (B (H.Text_First .. H.Text_Last) = Text);

   --  Walks Path down the heading tree. Each segment after the first is
   --  looked for only in the section of the one before it, so a name used
   --  under two parents resolves to the right one. The first of a duplicate in one
   --  scope wins. Zero when it is not found.
   function Find_Heading_Path
     (B : String; Headings : Heading_Vectors.Vector; Path : Text_Lists.Vector)
      return Natural
   is
      Search_Start : Positive := 1;
      Search_End   : Positive := Natural (Headings.Length) + 1;
      Found        : Natural  := 0;
   begin
      for Segment of Path loop
         declare
            At_Index : Natural := 0;
         begin
            for I in Search_Start .. Search_End - 1 loop
               if Title_Is
                   (B, Headings (I), Ada.Strings.Unbounded.To_String (Segment))
               then
                  At_Index := I;
                  exit;
               end if;
            end loop;
            if At_Index = 0 then
               return 0;
            end if;
            Found        := At_Index;
            Search_Start := At_Index + 1;
            Search_End   :=
              Section_End (Headings, At_Index + 1, Headings (At_Index).Level);
         end;
      end loop;
      return Found;
   end Find_Heading_Path;

   --  A section's own blank line before the next heading is part of the
   --  note's structure and not of the section's content, so a replace or an
   --  append must not consume it: one trailing blank line at the end of the
   --  range is left out of it. More than one in a row is left alone past the
   --  first.
   function Without_One_Blank_Line
     (B : String; Start, Stop : Positive) return Positive is
     (if
        Stop >= Start + 2 and then B (Stop - 1) = LF and then B (Stop - 2) = LF
      then Stop - 1
      else Stop);

   --  Replaces, prepends to or appends within [Start, Stop).
   function Splice
     (B : String; Start, Stop : Positive; Op : Operation; Content : String)
      return String is
     (case Op is
        when Replace => B (1 .. Start - 1) & Content & B (Stop .. B'Last),
        when Prepend => B (1 .. Start - 1) & Content & B (Start .. B'Last),
        when Append => B (1 .. Stop - 1) & Content & B (Stop .. B'Last),
        when Rename => B);

   function Done (Text : String) return Results.Result is
     (Results.Success (To_Unbounded_String (Text)));

   function Failed (Why : Error_Kind) return Results.Result is
     (Results.Failure (Why));

   --  Creates what of Path does not exist yet: at the end of the deepest
   --  ancestor that does, or at the end of the note when none does. Each new
   --  segment is a level deeper than its parent.
   function Create_Heading_Path
     (B : String; Headings : Heading_Vectors.Vector; Path : Text_Lists.Vector;
      Content : String) return String
   is
      Matched      : Natural  := 0;
      Anchor       : Natural  := 0;
      Search_Start : Positive := 1;
      Search_End   : Positive := Natural (Headings.Length) + 1;
   begin
      while Matched < Natural (Path.Length) loop
         declare
            At_Index : Natural         := 0;
            Wanted   : constant String :=
              Ada.Strings.Unbounded.To_String (Path (Matched + 1));
         begin
            for I in Search_Start .. Search_End - 1 loop
               if Title_Is (B, Headings (I), Wanted) then
                  At_Index := I;
                  exit;
               end if;
            end loop;
            exit when At_Index = 0;
            Anchor       := At_Index;
            Matched      := Matched + 1;
            Search_Start := At_Index + 1;
            Search_End   :=
              Section_End (Headings, At_Index + 1, Headings (At_Index).Level);
         end;
      end loop;

      declare
         Section    : Unbounded_String;
         Base_Level : constant Positive :=
           (if Anchor > 0 then Headings (Anchor).Level else 1);
      begin
         for Offset in 0 .. Natural (Path.Length) - Matched - 1 loop
            declare
               Level : constant Level_Range :=
                 Positive'Min (6, Base_Level + Offset + 1);
            begin
               Append (Section, [1 .. Level => '#']);
               Append (Section, " " & Path (Matched + 1 + Offset) & LF);
            end;
         end loop;
         Append (Section, Content);

         if Anchor > 0 then
            declare
               H       : constant Heading_Info := Headings (Anchor);
               End_Idx : constant Positive     :=
                 Section_End (Headings, Anchor + 1, H.Level);
               Bound   : constant Positive     :=
                 (if End_Idx <= Natural (Headings.Length) then
                    Headings (End_Idx).Line_Start
                  else B'Last + 1);
               Insert  : constant Positive     :=
                 Without_One_Blank_Line (B, H.Content_Start, Bound);
            begin
               return Splice (B, Insert, Insert, Append, To_String (Section));
            end;
         end if;

         --  Nothing matched: at the very end, with a blank line between unless
         --  the note already ends in one.
         declare
            Ends_LF  : constant Boolean :=
              B'Length >= 1 and then B (B'Last) = LF;
            Ends_2LF : constant Boolean :=
              B'Length >= 2 and then B (B'Last) = LF
              and then B (B'Last - 1) = LF;
         begin
            return
              B &
              (if B'Length /= 0 and then not Ends_2LF then
                 (if Ends_LF then "" & LF else LF & LF)
               else "") &
              To_String (Section);
         end;
      end;
   end Create_Heading_Path;

   function Apply_Heading
     (B : String; Path : Text_Lists.Vector; Op : Operation; Content : String;
      Create : Boolean) return Results.Result
   is
      Headings : constant Heading_Vectors.Vector := Scan_Headings (B);
      At_Index : constant Natural := Find_Heading_Path (B, Headings, Path);
   begin
      if At_Index > 0 then
         declare
            H       : constant Heading_Info := Headings (At_Index);
            End_Idx : constant Positive     :=
              Section_End (Headings, At_Index + 1, H.Level);
            Stop    : constant Positive     :=
              (if End_Idx <= Natural (Headings.Length) then
                 Headings (End_Idx).Line_Start
               else B'Last + 1);
            Touched : constant Positive     :=
              Without_One_Blank_Line (B, H.Content_Start, Stop);
         begin
            return Done (Splice (B, H.Content_Start, Touched, Op, Content));
         end;
      end if;
      if not Create then
         return Failed (Target_Not_Found);
      end if;
      return Done (Create_Heading_Path (B, Headings, Path, Content));
   end Apply_Heading;

   --  Relabels the heading at Path, splicing only its title text and leaving
   --  the `#` run, the section's content and every heading below it alone.
   --  There is no create: a rename with nothing to find is an error.
   function Apply_Rename
     (B : String; Path : Text_Lists.Vector; New_Text : String)
      return Results.Result
   is
   begin
      for C of New_Text loop
         if C = LF then
            return Failed (Multiline_Heading_Text);
         end if;
      end loop;
      declare
         Headings : constant Heading_Vectors.Vector := Scan_Headings (B);
         At_Index : constant Natural := Find_Heading_Path (B, Headings, Path);
      begin
         if At_Index = 0 then
            return Failed (Target_Not_Found);
         end if;
         declare
            H : constant Heading_Info := Headings (At_Index);
         begin
            return
              Done
                (B (1 .. H.Text_First - 1) & New_Text &
                 B (H.Text_Last + 1 .. B'Last));
         end;
      end;
   end Apply_Rename;

   type Block_Line is record
      Found      : Boolean  := False;
      Line_Start : Positive := 1;
      --  One past the last byte of the text before ` ^id`.
      Text_End   : Positive := 1;
   end record;

   --  A block is a line ending in a space, a caret and the id, and scoped to
   --  a single line: the overwhelmingly common shape (a paragraph or a list
   --  item). A multi-line block would need real paragraph boundaries.
   function Find_Block_Line (B : String; Id : String) return Block_Line is
      Idx : Positive := 1;
   begin
      while Idx <= B'Last loop
         declare
            NL         : constant Natural  := Next_LF (B, Idx);
            Line_End   : constant Positive :=
              (if NL = 0 then B'Last + 1 else NL);
            Suffix_Len : constant Positive := 2 + Id'Length;
         begin
            if Line_End - Idx >= Suffix_Len
              and then B (Line_End - Suffix_Len) = ' '
              and then B (Line_End - Suffix_Len + 1) = '^'
              and then B (Line_End - Id'Length .. Line_End - 1) = Id
            then
               return
                 (Found    => True, Line_Start => Idx,
                  Text_End => Line_End - Suffix_Len);
            end if;
            exit when NL = 0;
            Idx := Line_End + 1;
         end;
      end loop;
      return (others => <>);
   end Find_Block_Line;

   function Apply_Block
     (B : String; Id : String; Op : Operation; Content : String)
      return Results.Result
   is
      Found : constant Block_Line := Find_Block_Line (B, Id);
   begin
      if not Found.Found then
         return Failed (Target_Not_Found);
      end if;
      case Op is
         when Replace =>
            --  Keeps ` ^id`.
            return
              Done
                (B (1 .. Found.Line_Start - 1) & Content &
                 B (Found.Text_End .. B'Last));

         when Prepend =>
            return
              Done
                (Splice
                   (B, Found.Line_Start, Found.Line_Start, Append, Content));

         when Append =>
            return
              Done
                (Splice (B, Found.Text_End, Found.Text_End, Append, Content));

         when Rename =>
            return Failed (Invalid_Operation_For_Target);
      end case;
   end Apply_Block;

   function Apply
     (Text : String; Where : Target; Op : Operation; Content : String;
      Create_If_Missing : Boolean) return Results.Result
   is
      B : constant String (1 .. Text'Length) := Text;
   begin
      if Op = Rename then
         return
           (case Where.Kind is
              when Heading => Apply_Rename (B, Where.Path, Content),
              when Block_Id | Frontmatter_Key =>
                Failed (Invalid_Operation_For_Target));
      end if;
      case Where.Kind is
         when Frontmatter_Key =>
            declare
               Key : constant String := To_String (Where.Name);
            begin
               if B'Length > Frontmatter.Max_Note_Length
                 or else Key'Length > Frontmatter.Max_Key_Length
                 or else Content'Length > Frontmatter.Edit.Max_Scalar_Length
                 or else Text'Last = Positive'Last
                 or else Key'Last = Positive'Last
                 or else Content'Last = Positive'Last
               then
                  return Failed (Too_Large);
               end if;
               if not Frontmatter.Has_Frontmatter (B) then
                  return Failed (No_Frontmatter);
               end if;
               return Done (Frontmatter.Edit.Set_Scalar (B, Key, Content));
            end;

         when Heading =>
            return
              Apply_Heading (B, Where.Path, Op, Content, Create_If_Missing);

         when Block_Id =>
            return Apply_Block (B, To_String (Where.Name), Op, Content);
      end case;
   end Apply;

   ---------------------------------------------------------------------------
   --  The document map
   ---------------------------------------------------------------------------

   --  The id a line ends in, when it ends in ` ^id` of letters, digits,
   --  hyphens and underscores.
   function Block_Id_Suffix (Line : String) return String is
      Caret : Natural := 0;
   begin
      for I in reverse Line'Range loop
         if Line (I) = '^' then
            Caret := I;
            exit;
         end if;
      end loop;
      if Caret = 0 or else Caret = Line'First or else Line (Caret - 1) /= ' '
        or else Caret = Line'Last
      then
         return "";
      end if;
      for C of Line (Caret + 1 .. Line'Last) loop
         if C not in 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' then
            return "";
         end if;
      end loop;
      return Line (Caret + 1 .. Line'Last);
   end Block_Id_Suffix;

   function Map_Of (Text : String) return Document_Map is
      B        : constant String (1 .. Text'Length) := Text;
      Result   : Document_Map;
      Headings : constant Heading_Vectors.Vector    := Scan_Headings (B);
      package Index_Stacks is new Ada.Containers.Vectors (Positive, Positive);
      Stack : Index_Stacks.Vector;
   begin
      --  The ancestors, popped back to the last one shallower than the
      --  heading: the walk `Find_Heading_Path` does a segment at a time.
      for I in 1 .. Natural (Headings.Length) loop
         while not Stack.Is_Empty
           and then Headings (Stack.Last_Element).Level >= Headings (I).Level
         loop
            Stack.Delete_Last;
         end loop;
         Stack.Append (I);
         declare
            Path : Unbounded_String;
         begin
            for K in 1 .. Natural (Stack.Length) loop
               if K > 1 then
                  Append (Path, "::");
               end if;
               Append
                 (Path,
                  B (Headings (Stack (K)).Text_First ..
                         Headings (Stack (K)).Text_Last));
            end loop;
            Result.Headings.Append (Path);
         end;
      end loop;

      declare
         Idx : Positive := 1;
      begin
         while Idx <= B'Last loop
            declare
               NL       : constant Natural  := Next_LF (B, Idx);
               Line_End : constant Positive :=
                 (if NL = 0 then B'Last + 1 else NL);
               Id       : constant String   :=
                 Block_Id_Suffix (B (Idx .. Line_End - 1));
            begin
               if Id /= "" then
                  Result.Blocks.Append (To_Unbounded_String (Id));
               end if;
               exit when NL = 0;
               Idx := Line_End + 1;
            end;
         end loop;
      end;

      if B'Last < Positive'Last and then Frontmatter.Has_Frontmatter (B) then
         declare
            Block    : constant Frontmatter.Block := Frontmatter.Locate (B);
            Position : Natural                    := Block.Lines_Start;
            Line     : Frontmatter.Span;
            Found    : Boolean;
         begin
            loop
               Frontmatter.Next_Line (B, Block, Position, Line, Found);
               exit when not Found;
               declare
                  Text_Line  : constant String :=
                    B (B'First + Line.First .. B'First + Line.Stop - 1);
                  Has_Pair   : Boolean;
                  Key, Value : Frontmatter.Span;
               begin
                  Frontmatter.Split_Key_Value
                    (Text_Line, Has_Pair, Key, Value);
                  if Has_Pair then
                     Result.Frontmatter_Keys.Append
                       (To_Unbounded_String
                          (Text_Line
                             (Text_Line'First + Key.First ..
                                  Text_Line'First + Key.Stop - 1)));
                  end if;
               end;
            end loop;
         end;
      end if;
      return Result;
   end Map_Of;

end Synapse.Core.Patch;
