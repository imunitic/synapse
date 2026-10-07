package body Synapse.Core.Frontmatter with
  SPARK_Mode
is

   LF : constant Character := Character'Val (10);
   CR : constant Character := Character'Val (13);
   HT : constant Character := Character'Val (9);

   --  Offsets below are 0-based distances from the text's first byte.

   --  The offset of the line feed ending the line that contains Pos, or the
   --  end of the text when it has none.
   function Line_End (Text : String; Pos : Natural) return Natural with
     Pre  => Text'Last < Positive'Last and then Pos <= Text'Length,
     Post => Line_End'Result in Pos .. Text'Length
   is
      I : Natural := Pos;
   begin
      while I < Text'Length and then Text (Text'First + I) /= LF loop
         pragma Loop_Invariant (I in Pos .. Text'Length);
         pragma Loop_Variant (Increases => I);
         I := I + 1;
      end loop;
      return I;
   end Line_End;

   --  Where the line's own text ends: before a CR that precedes the line end.
   function Content_Stop
     (Text : String; Pos, Stop : Natural) return Natural with
     Pre  =>
      Text'Last < Positive'Last and then Pos <= Stop
      and then Stop <= Text'Length,
     Post => Content_Stop'Result in Pos .. Stop
   is
   begin
      if Stop > Pos and then Text (Text'First + Stop - 1) = CR then
         return Stop - 1;
      end if;
      return Stop;
   end Content_Stop;

   function Is_Fence (Text : String; Pos, Stop : Natural) return Boolean with
     Pre =>
      Text'Last < Positive'Last and then Pos <= Stop
      and then Stop <= Text'Length
   is
   begin
      return
        Stop - Pos = 3 and then Text (Text'First + Pos) = '-'
        and then Text (Text'First + Pos + 1) = '-'
        and then Text (Text'First + Pos + 2) = '-';
   end Is_Fence;

   ---------------------------------------------------------------------------
   --  Locating the block
   ---------------------------------------------------------------------------

   function Locate (Text : String) return Block is
      Len   : constant Natural := Text'Length;
      Start : Natural;
   begin
      --  The opening fence: `---` and a line ending.
      if Len >= 4 and then Text (Text'First) = '-'
        and then Text (Text'First + 1) = '-'
        and then Text (Text'First + 2) = '-'
        and then Text (Text'First + 3) = LF
      then
         Start := 4;
      elsif Len >= 5 and then Text (Text'First) = '-'
        and then Text (Text'First + 1) = '-'
        and then Text (Text'First + 2) = '-'
        and then Text (Text'First + 3) = CR and then Text (Text'First + 4) = LF
      then
         Start := 5;
      else
         return (Present => False);
      end if;

      declare
         Pos : Natural := Start;
      begin
         while Pos < Len loop
            pragma Loop_Invariant (Pos >= Start and then Pos <= Len);
            pragma Loop_Variant (Increases => Pos);
            declare
               Stop : constant Natural := Line_End (Text, Pos);
               Next : constant Natural :=
                 (if Stop < Len then Stop + 1 else Len);
            begin
               if Is_Fence (Text, Pos, Content_Stop (Text, Pos, Stop)) then
                  return
                    (Present    => True, Lines_Start => Start, Close => Pos,
                     Body_Start => Next);
               end if;
               Pos := Next;
            end;
         end loop;
      end;
      return (Present => False);
   end Locate;

   procedure Next_Line
     (Text  : String; B : Block; Position : in out Natural; Line : out Span;
      Found : out Boolean)
   is
   begin
      if Position >= B.Close then
         Line  := (First => Position, Stop => Position);
         Found := False;
         return;
      end if;

      declare
         --  The line before the closing fence ends at a line feed.
         Stop : constant Natural :=
           Natural'Min (Line_End (Text, Position), B.Close - 1);
      begin
         Line     :=
           (First => Position, Stop => Content_Stop (Text, Position, Stop));
         Position := Stop + 1;
         Found    := True;
      end;
   end Next_Line;

   function Body_After (Text : String) return Span is
      B : constant Block := Locate (Text);
   begin
      return
        (if B.Present then (First => B.Body_Start, Stop => Text'Length)
         else (First => 0, Stop => Text'Length));
   end Body_After;

   ---------------------------------------------------------------------------
   --  Reading
   ---------------------------------------------------------------------------

   function Find_Key_Line (Text, Key : String) return Maybe_Span is
      B : constant Block := Locate (Text);
   begin
      if not B.Present then
         return (Found => False);
      end if;

      declare
         Position : Natural := B.Lines_Start;
         Line     : Span;
         Found    : Boolean;
      begin
         loop
            pragma Loop_Invariant (Position <= B.Close);
            pragma Loop_Variant (Increases => Position);
            Next_Line (Text, B, Position, Line, Found);
            exit when not Found;
            if Is_Key_Line
                (Text (Text'First + Line.First .. Text'First + Line.Stop - 1),
                 Key)
            then
               return (Found => True, Value => Line);
            end if;
         end loop;
      end;
      return (Found => False);
   end Find_Key_Line;

   function Find_Field (Text, Key : String) return Maybe_Span is
      Line : constant Maybe_Span := Find_Key_Line (Text, Key);
   begin
      if not Line.Found then
         return (Found => False);
      end if;

      declare
         --  Start just past the colon.
         First : Natural := Line.Value.First + Key'Length + 1;
         Stop  : Natural := Line.Value.Stop;
      begin
         while First < Stop and then Text (Text'First + First) in ' ' | HT loop
            pragma Loop_Invariant (First <= Stop);
            pragma Loop_Variant (Increases => First);
            First := First + 1;
         end loop;
         if First < Stop and then Text (Text'First + First) = '"' then
            First := First + 1;
         end if;
         if First < Stop and then Text (Text'First + Stop - 1) = '"' then
            Stop := Stop - 1;
         end if;
         return (Found => True, Value => (First => First, Stop => Stop));
      end;
   end Find_Field;

   procedure Split_Key_Value
     (Line : String; Found : out Boolean; Key, Value : out Span)
   is
      Len   : constant Natural := Line'Length;
      Colon : Natural          := 0;
   begin
      Found := False;
      Key   := (First => 0, Stop => 0);
      Value := (First => 0, Stop => 0);

      if Len = 0 or else Line (Line'First) in ' ' | HT then
         return;
      end if;
      while Colon < Len and then Line (Line'First + Colon) /= ':' loop
         pragma Loop_Invariant (Colon <= Len);
         pragma Loop_Variant (Increases => Colon);
         Colon := Colon + 1;
      end loop;
      if Colon = Len then
         return;
      end if;

      declare
         K1 : Natural := 0;
         K2 : Natural := Colon;
         V1 : Natural := Colon + 1;
         V2 : Natural := Len;
      begin
         while K1 < K2 and then Line (Line'First + K1) = ' ' loop
            pragma Loop_Invariant (K1 <= K2 and then K2 <= Len);
            pragma Loop_Variant (Increases => K1);
            K1 := K1 + 1;
         end loop;
         while K2 > K1 and then Line (Line'First + K2 - 1) = ' ' loop
            pragma Loop_Invariant (K1 <= K2 and then K2 <= Len);
            pragma Loop_Variant (Decreases => K2);
            K2 := K2 - 1;
         end loop;
         if K1 = K2 then
            return;
         end if;
         while V1 < V2 and then Line (Line'First + V1) = ' ' loop
            pragma Loop_Invariant (V1 <= V2 and then V2 <= Len);
            pragma Loop_Variant (Increases => V1);
            V1 := V1 + 1;
         end loop;
         while V2 > V1 and then Line (Line'First + V2 - 1) = ' ' loop
            pragma Loop_Invariant (V1 <= V2 and then V2 <= Len);
            pragma Loop_Variant (Decreases => V2);
            V2 := V2 - 1;
         end loop;
         Found := True;
         Key   := (First => K1, Stop => K2);
         Value := (First => V1, Stop => V2);
      end;
   end Split_Key_Value;

   ---------------------------------------------------------------------------
   --  Quoting
   ---------------------------------------------------------------------------

   function Needs_Quoting (S : String) return Boolean is
   begin
      if S'Length = 0 then
         return True;
      end if;
      if S (S'First) in ' ' | HT or else S (S'Last) in ' ' | HT
        or else S (S'Last) = ':'
        or else S (S'First) in
          '"' | ''' | '#' | '&' | '*' | '!' | '|' | '>' | '%' | '@' | '`' | '['
          | ']' | '{' | '}' | ','
      then
         return True;
      end if;
      if
        (for some I in S'First .. S'Last - 1 =>
           (S (I) = ':' and then S (I + 1) = ' ')
           or else (S (I) = ' ' and then S (I + 1) = '#'))
        or else (for some C of S => C in LF | CR)
      then
         return True;
      end if;
      if S in "true" | "false" | "null" | "~" then
         return True;
      end if;
      --  Only digits would read back as an integer.
      return (for all C of S => C in '0' .. '9');
   end Needs_Quoting;

   function Quoted (S : String) return String is
      Buffer : String (1 .. 2 * S'Length + 2) := [others => ' '];
      Last   : Positive                       := 1;
   begin
      Buffer (1) := '"';
      for I in S'Range loop
         pragma Loop_Invariant (Last >= 1 + (I - S'First));
         pragma Loop_Invariant (Last <= 1 + 2 * (I - S'First));
         pragma Loop_Invariant (Buffer (1) = '"');
         case S (I) is
            when '\' =>
               Buffer (Last + 1) := '\';
               Buffer (Last + 2) := '\';
               Last              := Last + 2;

            when '"' =>
               Buffer (Last + 1) := '\';
               Buffer (Last + 2) := '"';
               Last              := Last + 2;

            when LF =>
               Buffer (Last + 1) := '\';
               Buffer (Last + 2) := 'n';
               Last              := Last + 2;

            when CR =>
               Buffer (Last + 1) := '\';
               Buffer (Last + 2) := 'r';
               Last              := Last + 2;

            when others =>
               Buffer (Last + 1) := S (I);
               Last              := Last + 1;
         end case;
      end loop;
      Buffer (Last + 1) := '"';
      return Buffer (1 .. Last + 1);
   end Quoted;

   function Render_Scalar (S : String) return String is
     (if Needs_Quoting (S) then Quoted (S) else S);

   ---------------------------------------------------------------------------
   --  Writing
   ---------------------------------------------------------------------------

   function Set_Rendered (Note, Key, Rendered : String) return String is
      B        : constant Block         := Locate (Note);
      Existing : constant Maybe_Span    := Find_Key_Line (Note, Key);
      Line_Len : constant Natural       := Key'Length + 2 + Rendered'Length;
      New_Line : String (1 .. Line_Len) := [others => ' '];
   begin
      New_Line (1 .. Key'Length)                  := Key;
      New_Line (Key'Length + 1 .. Key'Length + 2) := ": ";
      New_Line (Key'Length + 3 .. Line_Len)       := Rendered;

      if Existing.Found then
         declare
            Head   : constant Natural := Existing.Value.First;
            Tail   : constant Natural := Existing.Value.Stop;
            Result : String (1 .. Head + Line_Len + (Note'Length - Tail)) :=
              [others => ' '];
         begin
            Result (1 .. Head) := Note (Note'First .. Note'First + Head - 1);
            Result (Head + 1 .. Head + Line_Len)        := New_Line;
            Result (Head + Line_Len + 1 .. Result'Last) :=
              Note (Note'First + Tail .. Note'Last);
            return Result;
         end;
      end if;

      --  A new line goes before the closing fence, ended the way that fence
      --  line is.
      declare
         Close_Is_CRLF : constant Boolean :=
           B.Close + 3 < Note'Length
           and then Note (Note'First + B.Close + 3) = CR;
         Ending : constant String := (if Close_Is_CRLF then CR & LF else [LF]);
         Head          : constant Natural := B.Close;
         Result        :
           String
             (1 .. Head + Line_Len + Ending'Length + (Note'Length - Head)) :=
           [others => ' '];
      begin
         Result (1 .. Head) := Note (Note'First .. Note'First + Head - 1);
         Result (Head + 1 .. Head + Line_Len) := New_Line;
         Result (Head + Line_Len + 1 .. Head + Line_Len + Ending'Length) :=
           Ending;
         Result (Head + Line_Len + Ending'Length + 1 .. Result'Last)     :=
           Note (Note'First + Head .. Note'Last);
         return Result;
      end;
   end Set_Rendered;

end Synapse.Core.Frontmatter;
