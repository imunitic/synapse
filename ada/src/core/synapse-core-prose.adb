with Synapse.Core.Note_Text;

package body Synapse.Core.Prose is

   LF : constant Character := Character'Val (10);
   CR : constant Character := Character'Val (13);
   HT : constant Character := Character'Val (9);

   --  The line starting at From, up to its line feed or the end of Text, and
   --  the position of what follows it (Text'Last + 2 after the last line).
   procedure Next_Line
     (Text : String; From : Positive; Stop : out Natural; After : out Positive)
   is
   begin
      Stop := Text'Last + 1;
      for I in From .. Text'Last loop
         if Text (I) = LF then
            Stop := I;
            exit;
         end if;
      end loop;
      After := Stop + 1;
   end Next_Line;

   --  A line without its trailing carriage return.
   function Without_CR (Line : String) return String
   is (if Line'Length > 0 and then Line (Line'Last) = CR
       then Line (Line'First .. Line'Last - 1)
       else Line);

   function Is_Digit (C : Character) return Boolean
   is (C in '0' .. '9');

   function Starts_With (S, Prefix : String) return Boolean
   is (S'Length >= Prefix'Length
       and then S (S'First .. S'First + Prefix'Length - 1) = Prefix);

   function Is_Excluded_Line (Line : String) return Boolean is
      Text : constant String := Without_CR (Line);
   begin
      if Text'Length = 0 or else Text (Text'First) in ' ' | HT then
         return True;
      end if;
      if Text (Text'First) in '#' | '>' | '|'
        or else Starts_With (Text, "- ")
        or else Starts_With (Text, "* ")
        or else Starts_With (Text, "+ ")
        or else Note_Text.Is_Fence_Line (Text)
      then
         return True;
      end if;

      --  An ordered list item: digits, `.` or `)`, a space.
      declare
         I : Natural := Text'First;
      begin
         while I <= Text'Last and then Is_Digit (Text (I)) loop
            I := I + 1;
         end loop;
         return
           I > Text'First
           and then I < Text'Last
           and then Text (I) in '.' | ')'
           and then Text (I + 1) = ' ';
      end;
   end Is_Excluded_Line;

   ---------------------------------------------------------------------------
   --  Paragraph runs
   ---------------------------------------------------------------------------

   --  Calls Visit for every paragraph run of Text outside fences: the first
   --  position of its first line, the end of its last line (before the line
   --  feed) and how many lines it has. Stops early when Visit returns False.
   generic
      with function Visit (First, Stop, Lines : Natural) return Boolean;
   function Every_Run (Text : String) return Boolean;

   function Every_Run (Text : String) return Boolean is
      In_Fence : Boolean := False;
      Lines    : Natural := 0;
      First    : Natural := 0;
      Stop     : Natural := 0;
      Position : Positive := Text'First;

      --  Closes the open run; False when Visit rejects it.
      function Flush return Boolean is
         Result : constant Boolean :=
           Lines = 0 or else Visit (First, Stop, Lines);
      begin
         Lines := 0;
         return Result;
      end Flush;
   begin
      loop
         declare
            Line_Stop : Natural;
            After     : Positive;
         begin
            Next_Line (Text, Position, Line_Stop, After);
            declare
               Line : constant String := Text (Position .. Line_Stop - 1);
            begin
               if Note_Text.Is_Fence_Line (Without_CR (Line)) then
                  if not Flush then
                     return False;
                  end if;
                  In_Fence := not In_Fence;
               elsif In_Fence or else Is_Excluded_Line (Line) then
                  if not Flush then
                     return False;
                  end if;
               else
                  if Lines = 0 then
                     First := Position;
                  end if;
                  Stop := Line_Stop - 1;
                  Lines := Lines + 1;
               end if;
            end;
            exit when Line_Stop > Text'Last;
            Position := After;
         end;
      end loop;
      return Flush;
   end Every_Run;

   function Single_Line (First, Stop, Lines : Natural) return Boolean
   is (Lines <= 1 and then First <= Stop + 1);

   function No_Hard_Wrap (Text : String) return Boolean is
      function All_Single is new Every_Run (Single_Line);
   begin
      return All_Single (Text);
   end No_Hard_Wrap;

   ---------------------------------------------------------------------------
   --  Greedy wrapping
   ---------------------------------------------------------------------------

   --  The next word of S at or after Pos, the characters between separators.
   --  Tabs and spaces separate words; so do carriage returns and line feeds
   --  when Any_Break is set.
   procedure Next_Word
     (S         : String;
      Any_Break : Boolean;
      Pos       : in out Positive;
      First     : out Positive;
      Stop      : out Natural;
      Found     : out Boolean)
   is
      function Separator (C : Character) return Boolean
      is (C in ' ' | HT or else (Any_Break and then C in CR | LF));
   begin
      First := Pos;
      Stop := Pos - 1;
      Found := False;
      while Pos <= S'Last and then Separator (S (Pos)) loop
         Pos := Pos + 1;
      end loop;
      if Pos > S'Last then
         return;
      end if;
      First := Pos;
      while Pos <= S'Last and then not Separator (S (Pos)) loop
         Pos := Pos + 1;
      end loop;
      Stop := Pos - 1;
      Found := True;
   end Next_Word;

   --  Whether the lines of Run are what a greedy wrap of its words at Max
   --  characters makes of them.
   function Matches_Greedy_Wrap (Run : String; Max : Positive) return Boolean
   is
      Words        : Positive := Run'First;  --  the word stream
      Have_Pending : Boolean;
      P_First      : Positive;
      P_Stop       : Natural;
      Position     : Positive := Run'First;

      procedure Advance is
      begin
         Next_Word (Run, True, Words, P_First, P_Stop, Have_Pending);
      end Advance;
   begin
      Advance;
      loop
         declare
            Line_Stop : Natural;
            After     : Positive;
         begin
            Next_Line (Run, Position, Line_Stop, After);
            declare
               Raw  : constant String :=
                 Without_CR (Run (Position .. Line_Stop - 1));
               Trim_First : Positive := Raw'First;
               Trim_Last  : Natural := Raw'Last;
            begin
               while Trim_First <= Trim_Last
                 and then Raw (Trim_First) in ' ' | HT
               loop
                  Trim_First := Trim_First + 1;
               end loop;
               while Trim_Last >= Trim_First
                 and then Raw (Trim_Last) in ' ' | HT
               loop
                  Trim_Last := Trim_Last - 1;
               end loop;

               if Trim_First <= Trim_Last then
                  declare
                     Line    : constant String :=
                       Raw (Trim_First .. Trim_Last);
                     L_Pos   : Positive := Line'First;
                     L_First : Positive;
                     L_Stop  : Natural;
                     L_Found : Boolean;
                     Length  : Natural;
                  begin
                     if not Have_Pending then
                        return False;
                     end if;
                     Next_Word (Line, False, L_Pos, L_First, L_Stop, L_Found);
                     if not L_Found
                       or else Run (P_First .. P_Stop)
                               /= Line (L_First .. L_Stop)
                     then
                        return False;
                     end if;
                     Length := P_Stop - P_First + 1;
                     Advance;

                     while Have_Pending loop
                        declare
                           Candidate : constant Natural :=
                             Length + 1 + (P_Stop - P_First + 1);
                           Stop_After : Boolean := False;
                        begin
                           if Candidate > Max then
                              declare
                                 Overshoot  : constant Natural :=
                                   Candidate - Max;
                                 Undershoot : constant Natural :=
                                   (if Length < Max then Max - Length else 0);
                              begin
                                 exit when Overshoot >= Undershoot;
                                 Stop_After := True;
                              end;
                           end if;
                           Next_Word
                             (Line, False, L_Pos, L_First, L_Stop, L_Found);
                           if not L_Found
                             or else Run (P_First .. P_Stop)
                                     /= Line (L_First .. L_Stop)
                           then
                              return False;
                           end if;
                           Length := Candidate;
                           Advance;
                           exit when Stop_After;
                        end;
                     end loop;

                     Next_Word (Line, False, L_Pos, L_First, L_Stop, L_Found);
                     if L_Found then
                        return False;
                     end if;
                  end;
               end if;
            end;
            exit when Line_Stop > Run'Last;
            Position := After;
         end;
      end loop;
      return not Have_Pending;
   end Matches_Greedy_Wrap;

   function Hard_Wrap (Text : String; Max_Chars : Positive) return Boolean is
      function Matches (First, Stop, Lines : Natural) return Boolean
      is (Lines >= 1
          and then Matches_Greedy_Wrap (Text (First .. Stop), Max_Chars));
      function All_Match is new Every_Run (Matches);
   begin
      return All_Match (Text);
   end Hard_Wrap;

   ---------------------------------------------------------------------------
   --  Stray frontmatter
   ---------------------------------------------------------------------------

   --  Whether a line is `key: value` at column zero with a value.
   function Has_Key_Value (Line : String) return Boolean is
   begin
      if Line'Length = 0 or else Line (Line'First) in ' ' | HT then
         return False;
      end if;
      for I in Line'Range loop
         if Line (I) = ':' then
            declare
               Key_Blank : Boolean := True;
               Value_Blank : Boolean := True;
            begin
               for K in Line'First .. I - 1 loop
                  if Line (K) /= ' ' then
                     Key_Blank := False;
                  end if;
               end loop;
               for K in I + 1 .. Line'Last loop
                  if Line (K) /= ' ' then
                     Value_Blank := False;
                  end if;
               end loop;
               return not Key_Blank and then not Value_Blank;
            end;
         end if;
      end loop;
      return False;
   end Has_Key_Value;

   function No_Stray_Frontmatter (Text : String) return Boolean is
      In_Fence   : Boolean := False;
      Block_Open : Boolean := False;
      Saw_Value  : Boolean := False;
      Position   : Positive := Text'First;
   begin
      loop
         declare
            Line_Stop : Natural;
            After     : Positive;
         begin
            Next_Line (Text, Position, Line_Stop, After);
            declare
               Line : constant String :=
                 Without_CR (Text (Position .. Line_Stop - 1));
            begin
               if Note_Text.Is_Fence_Line (Line) then
                  In_Fence := not In_Fence;
               elsif not In_Fence then
                  if Line = "---" then
                     if Block_Open and then Saw_Value then
                        return False;
                     end if;
                     Block_Open := not Block_Open;
                     Saw_Value := False;
                  elsif Block_Open and then Has_Key_Value (Line) then
                     Saw_Value := True;
                  end if;
               end if;
            end;
            exit when Line_Stop > Text'Last;
            Position := After;
         end;
      end loop;
      return True;
   end No_Stray_Frontmatter;

end Synapse.Core.Prose;
