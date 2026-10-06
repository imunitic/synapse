package body Synapse.Core.Note_Text with SPARK_Mode is

   Maximum : constant Long_Long_Integer := Long_Long_Integer'Last;
   Minimum : constant Long_Long_Integer := Long_Long_Integer'First;

   function Is_Digit (C : Character) return Boolean
   is (C in '0' .. '9');

   function Is_Whitespace (C : Character) return Boolean
   is (C in ' ' | Character'Val (9) | Character'Val (10)
         | Character'Val (11) | Character'Val (12) | Character'Val (13));

   ---------------------------------------------------------------------------
   --  Paths and comments
   ---------------------------------------------------------------------------

   function Filename_Stem (Path : String) return Span is
      Start : Natural := 0;
      Stop  : Natural := Path'Length;
   begin
      for I in 0 .. Path'Length - 1 loop
         pragma Loop_Invariant (Start <= I);
         if Path (Path'First + I) in '/' | '\' then
            Start := I + 1;
         end if;
      end loop;

      --  A trailing `.md` is not part of the stem.
      if Stop - Start >= 3
        and then Path (Path'First + Stop - 3) = '.'
        and then Path (Path'First + Stop - 2) = 'm'
        and then Path (Path'First + Stop - 1) = 'd'
      then
         Stop := Stop - 3;
      end if;
      return (First => Start, Stop => Stop);
   end Filename_Stem;

   function Strip_Trailing_Comment (Raw : String) return Natural is
      Quote : Character := Character'Val (0);
   begin
      for I in 0 .. Raw'Length - 1 loop
         pragma Loop_Invariant (I < Raw'Length);
         declare
            C : constant Character := Raw (Raw'First + I);
         begin
            if Quote /= Character'Val (0) then
               if C = Quote then
                  Quote := Character'Val (0);
               end if;
            elsif C in ''' | '"' then
               Quote := C;
            elsif C = '#'
              and then (I = 0 or else Is_Whitespace (Raw (Raw'First + I - 1)))
            then
               return I;
            end if;
         end;
      end loop;
      return Raw'Length;
   end Strip_Trailing_Comment;

   ---------------------------------------------------------------------------
   --  Numbers
   ---------------------------------------------------------------------------

   procedure Parse_Decimal
     (Raw : String; Valid : out Boolean; Value : out Long_Long_Integer)
   is
      Negative : constant Boolean :=
        Raw'Length > 0 and then Raw (Raw'First) = '-';
      Start    : constant Natural := (if Negative then 1 else 0);
      --  The magnitude is accumulated as a negative number, which holds one
      --  more value than a positive one.
      Acc      : Long_Long_Integer := 0;
   begin
      Valid := False;
      Value := 0;
      if Raw'Length <= Start then
         return;
      end if;

      for I in Start .. Raw'Length - 1 loop
         pragma Loop_Invariant (Acc <= 0);
         declare
            C : constant Character := Raw (Raw'First + I);
         begin
            if not Is_Digit (C) then
               return;
            end if;
            declare
               Digit : constant Long_Long_Integer :=
                 Long_Long_Integer (Character'Pos (C) - Character'Pos ('0'));
            begin
               if Acc < (Minimum + Digit) / 10 then
                  return;
               end if;
               Acc := Acc * 10 - Digit;
            end;
         end;
      end loop;

      if Negative then
         Value := Acc;
      elsif Acc = Minimum then
         return;
      else
         Value := -Acc;
      end if;
      Valid := True;
   end Parse_Decimal;

   ---------------------------------------------------------------------------
   --  Timestamps
   ---------------------------------------------------------------------------

   --  The character at offset I, or NUL when there is none.
   function At_Offset (S : String; I : Natural) return Character
   is (if I < S'Length then S (S'First + I) else Character'Val (0))
   with Pre => S'Last < Positive'Last;

   function Digit_At (S : String; I : Natural) return Boolean
   is (Is_Digit (At_Offset (S, I)))
   with Pre => S'Last < Positive'Last;

   --  The two decimal digits at offset I; 0 when they are not digits.
   function Two (S : String; I : Natural) return Natural
   with
     Pre  => S'Last < Positive'Last and then I < Natural'Last / 2,
     Post => Two'Result <= 99
   is
      A : constant Character := At_Offset (S, I);
      B : constant Character := At_Offset (S, I + 1);
   begin
      if Is_Digit (A) and then Is_Digit (B) then
         return
           (Character'Pos (A) - Character'Pos ('0')) * 10
           + (Character'Pos (B) - Character'Pos ('0'));
      end if;
      return 0;
   end Two;

   function Shape_Is_Valid (Value : String) return Boolean
   with Pre => Value'Last < Positive'Last
   is
   begin
      if Value'Length < 20 then
         return False;
      end if;
      for I in 0 .. 18 loop
         if I not in 4 | 7 | 10 | 13 | 16 and then not Digit_At (Value, I)
         then
            return False;
         end if;
      end loop;
      return
        At_Offset (Value, 4) = '-'
        and then At_Offset (Value, 7) = '-'
        and then At_Offset (Value, 10) = 'T'
        and then At_Offset (Value, 13) = ':'
        and then At_Offset (Value, 16) = ':';
   end Shape_Is_Valid;

   function Valid_Timestamp (Value : String) return Boolean is
   begin
      if not Shape_Is_Valid (Value) then
         return False;
      end if;
      if Two (Value, 5) not in 1 .. 12
        or else Two (Value, 8) not in 1 .. 31
        or else Two (Value, 11) > 23
        or else Two (Value, 14) > 59
        or else Two (Value, 17) > 59
      then
         return False;
      end if;

      --  The zone: `Z`, or a sign, two digits, a colon and two digits.
      if Value'Length = 20 then
         return At_Offset (Value, 19) = 'Z';
      elsif Value'Length /= 25 then
         return False;
      end if;
      return
        At_Offset (Value, 19) in '+' | '-'
        and then Digit_At (Value, 20)
        and then Digit_At (Value, 21)
        and then At_Offset (Value, 22) = ':'
        and then Digit_At (Value, 23)
        and then Digit_At (Value, 24)
        and then Two (Value, 20) <= 23
        and then Two (Value, 23) <= 59;
   end Valid_Timestamp;

   function Days_From_Civil
     (Year : Integer; Month, Day : Positive) return Long_Long_Integer
   is
      Y   : constant Long_Long_Integer :=
        Long_Long_Integer (if Month <= 2 then Year - 1 else Year);
      Era : constant Long_Long_Integer :=
        (if Y >= 0 then Y / 400 else (Y - 399) / 400);
      Yoe : constant Long_Long_Integer := Y - Era * 400;
      Mp  : constant Long_Long_Integer :=
        (Long_Long_Integer (Month) + 9) mod 12;
      Doy : constant Long_Long_Integer :=
        (153 * Mp + 2) / 5 + Long_Long_Integer (Day) - 1;
      Doe : constant Long_Long_Integer :=
        Yoe * 365 + Yoe / 4 - Yoe / 100 + Doy;
   begin
      return Era * 146_097 + Doe - 719_468;
   end Days_From_Civil;

   procedure Parse_Instant_Seconds
     (Value : String; Valid : out Boolean; Seconds : out Long_Long_Integer) is
   begin
      Seconds := 0;
      Valid := Valid_Timestamp (Value);
      if not Valid then
         return;
      end if;

      declare
         Year   : constant Natural := Two (Value, 0) * 100 + Two (Value, 2);
         Month  : constant Natural := Two (Value, 5);
         Day    : constant Natural := Two (Value, 8);
         Hour   : constant Natural := Two (Value, 11);
         Minute : constant Natural := Two (Value, 14);
         Second : constant Natural := Two (Value, 17);
         Offset : Long_Long_Integer := 0;
      begin
         if Value'Length = 25 then
            Offset :=
              Long_Long_Integer (Two (Value, 20)) * 3600
              + Long_Long_Integer (Two (Value, 23)) * 60;
            if At_Offset (Value, 19) = '-' then
               Offset := -Offset;
            end if;
         end if;
         if Month in 1 .. 12 and then Day in 1 .. 31 and then Year <= 9999 then
            Seconds :=
              Days_From_Civil (Year, Month, Day) * 86_400
              + Long_Long_Integer (Hour) * 3600
              + Long_Long_Integer (Minute) * 60
              + Long_Long_Integer (Second)
              - Offset;
         else
            Valid := False;
         end if;
      end;
   end Parse_Instant_Seconds;

   ---------------------------------------------------------------------------
   --  Markdown lines
   ---------------------------------------------------------------------------

   function Is_Fence_Line (Line : String) return Boolean is
      First : Natural := 0;
   begin
      while First < Line'Length
        and then Line (Line'First + First) in ' ' | Character'Val (9)
      loop
         pragma Loop_Invariant (First < Line'Length);
         pragma Loop_Variant (Increases => First);
         First := First + 1;
      end loop;
      return
        Line'Length - First >= 3
        and then
          ((Line (Line'First + First) = '`'
            and then Line (Line'First + First + 1) = '`'
            and then Line (Line'First + First + 2) = '`')
           or else
             (Line (Line'First + First) = '~'
              and then Line (Line'First + First + 1) = '~'
              and then Line (Line'First + First + 2) = '~'));
   end Is_Fence_Line;

   function Heading_Level (Line : String) return Natural is
      Level : Natural := 0;
   begin
      while Level < Line'Length and then Line (Line'First + Level) = '#' loop
         pragma Loop_Invariant (Level < Line'Length);
         pragma Loop_Variant (Increases => Level);
         Level := Level + 1;
      end loop;
      if Level in 1 .. 6
        and then Level < Line'Length
        and then Line (Line'First + Level) = ' '
      then
         return Level;
      end if;
      return 0;
   end Heading_Level;

   function Heading_Title (Line : String; Level : Positive) return Span is
      First : Natural := Level + 1;
      Stop  : Natural := Line'Length;
   begin
      while First < Stop
        and then Line (Line'First + First) in ' ' | Character'Val (9)
      loop
         pragma Loop_Invariant (First <= Stop);
         pragma Loop_Variant (Increases => First);
         First := First + 1;
      end loop;
      while Stop > First
        and then Line (Line'First + Stop - 1) in ' ' | Character'Val (9)
      loop
         pragma Loop_Invariant (First <= Stop and then Stop <= Line'Length);
         pragma Loop_Variant (Decreases => Stop);
         Stop := Stop - 1;
      end loop;
      return (First => First, Stop => Stop);
   end Heading_Title;

end Synapse.Core.Note_Text;
