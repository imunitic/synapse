with Ada.Strings.Fixed;
with Ada.Strings.Maps;

with Synapse.Core.Line_Slice;
with Synapse.Core.Decimal_Image;

package body Synapse.Core.Emit is

   use Line_Slice;

   Blanks : constant Ada.Strings.Maps.Character_Set :=
     Ada.Strings.Maps.To_Set (" " & Character'Val (9));

   Blanks_And_CR : constant Ada.Strings.Maps.Character_Set :=
     Ada.Strings.Maps.To_Set (" " & Character'Val (9) & Character'Val (13));

   --  An em dash, in bytes: the source encoding is not relied on.
   Em_Dash : constant String :=
     Character'Val (16#E2#) & Character'Val (16#80#) & Character'Val (16#94#);

   function Trim (S : String) return String is
     (Ada.Strings.Fixed.Trim (S, Blanks, Blanks));

   function Trim_All (S : String) return String is
     (Ada.Strings.Fixed.Trim (S, Blanks_And_CR, Blanks_And_CR));

   function Starts_With (S, Prefix : String) return Boolean is
     (S'Length >= Prefix'Length
      and then S (S'First .. S'First + Prefix'Length - 1) = Prefix);

   function Ends_With (S, Suffix : String) return Boolean is
     (S'Length >= Suffix'Length
      and then S (S'Last - Suffix'Length + 1 .. S'Last) = Suffix);

   --  The first place Pattern occurs in Text (From .. To), or 0.
   function Find
     (Text, Pattern : String; From : Integer; To : Integer) return Natural
   is
      First : constant Integer := Integer'Max (From, Text'First);
      Last  : constant Integer := Integer'Min (To, Text'Last);
   begin
      if First > Last then
         return 0;
      end if;
      return Ada.Strings.Fixed.Index (Text (First .. Last), Pattern);
   end Find;

   function File_Title (Title : String) return String is
      Result : String := Title;
   begin
      for C of Result loop
         if C in '/' | ':' | '*' | '?' | '"' | '<' | '>' | '|' then
            C := '_';
         end if;
      end loop;
      return Result;
   end File_Title;

   function Directive_Arg (Inner, Keyword : String) return Maybe_Text is
      S : constant String :=
        Ada.Strings.Fixed.Trim (Inner, Blanks, Ada.Strings.Maps.Null_Set);
   begin
      if not Starts_With (S, Keyword) then
         return (Found => False);
      end if;
      declare
         Rest : constant String := S (S'First + Keyword'Length .. S'Last);
      begin
         if Rest'Length = 0 or else Rest (Rest'First) /= ':' then
            return (Found => False);
         end if;
         return
           (Found => True,
            Value =>
              To_Unbounded_String (Trim (Rest (Rest'First + 1 .. Rest'Last))));
      end;
   end Directive_Arg;

   function Directives (Text, Keyword : String) return Text_Lists.Vector is
      Result : Text_Lists.Vector;
      Here   : Integer := Text'First;
   begin
      loop
         declare
            Open  : constant Natural := Find (Text, "<!--", Here, Text'Last);
            Close : constant Natural :=
              (if Open = 0 then 0
               else Find (Text, "-->", Open + 4, Text'Last));
         begin
            exit when Open = 0 or else Close = 0;
            Here := Open + 4;
            if Directive_Arg (Text (Open + 4 .. Close - 1), Keyword).Found then
               Result.Append (To_Unbounded_String (Text (Open .. Close + 2)));
            end if;
         end;
      end loop;
      return Result;
   end Directives;

   function Find_Directive (Text, Keyword : String) return Maybe_Text is
      Found : constant Text_Lists.Vector := Directives (Text, Keyword);
   begin
      if Found.Is_Empty then
         return (Found => False);
      end if;
      return (Found => True, Value => Found.First_Element);
   end Find_Directive;

   function Section (Text, Heading : String) return Maybe_Text is
      Marker        : constant String := "## " & Heading;
      Start         : Integer         := Text'First;
      Content_Start : Integer         := 0;
   begin
      loop
         declare
            Stop       : constant Natural := Next_Line_Feed (Text, Start);
            Piece_Last : constant Integer :=
              (if Stop = 0 then Text'Last else Stop - 1);
            Line       : constant String  :=
              Ada.Strings.Fixed.Trim
                (Text (Start .. Piece_Last), Ada.Strings.Maps.Null_Set,
                 Ada.Strings.Maps.To_Set (Character'Val (13)));
         begin
            if Content_Start /= 0 then
               if Starts_With (Line, "## ")
                 or else Line = Node_Format.Generated_End
               then
                  return
                    (Found => True,
                     Value =>
                       To_Unbounded_String
                         (Text (Content_Start .. Start - 1)));
               end if;
            elsif Line = Marker then
               Content_Start := Piece_Last + 2;
            end if;
            exit when Stop = 0;
            Start := Stop + 1;
         end;
      end loop;
      if Content_Start = 0 then
         return (Found => False);
      end if;
      return
        (Found => True,
         Value =>
           To_Unbounded_String
             (Text (Integer'Min (Content_Start, Text'Last + 1) .. Text'Last)));
   end Section;

   --  Digits and nothing else, clamped to Natural'Last. -1 when it is not a
   --  run of digits.
   function Digits_Value (S : String) return Integer is
      Value : Natural := 0;
   begin
      if S'Length = 0 then
         return -1;
      end if;
      for C of S loop
         if C not in '0' .. '9' then
            return -1;
         end if;
         declare
            Digit : constant Natural :=
              Character'Pos (C) - Character'Pos ('0');
         begin
            Value :=
              (if Value > (Natural'Last - Digit) / 10 then Natural'Last
               else Value * 10 + Digit);
         end;
      end loop;
      return Value;
   end Digits_Value;

   function Parse_Span (Arg : String) return Maybe_Span is
      First_Blank : Natural := 0;
      Last_Blank  : Natural := 0;
   begin
      for I in Arg'Range loop
         if Arg (I) in ' ' | Character'Val (9) then
            if First_Blank = 0 then
               First_Blank := I;
            end if;
            Last_Blank := I;
         end if;
      end loop;
      --  The path ends at the first blank and the range begins after the
      --  last: no blank at all is no range.
      if First_Blank = 0 or else First_Blank = Arg'First then
         return (Found => False);
      end if;
      declare
         Path : constant String := Arg (Arg'First .. First_Blank - 1);
         Raw : constant String := Arg (Last_Blank + 1 .. Arg'Last);
         Range_Text            : String (1 .. Raw'Length);
         Used                  : Natural         := 0;
         Dash_First, Dash_Last : Natural         := 0;
      begin
         if Raw'Length > 64 then
            return (Found => False);
         end if;
         for C of Raw loop
            if C /= 'L' then
               Used              := Used + 1;
               Range_Text (Used) := C;
            end if;
         end loop;
         for I in 1 .. Used loop
            if Range_Text (I) = '-' then
               if Dash_First = 0 then
                  Dash_First := I;
               end if;
               Dash_Last := I;
            end if;
         end loop;
         if Dash_First = 0 then
            return (Found => False);
         end if;
         declare
            First : constant Integer :=
              Digits_Value (Range_Text (1 .. Dash_First - 1));
            Last  : constant Integer :=
              Digits_Value (Range_Text (Dash_Last + 1 .. Used));
         begin
            if First < 0 or else Last < 0 then
               return (Found => False);
            end if;
            return
              (Found => True,
               Value =>
                 (Path => To_Unbounded_String (Path), First => First,
                  Last => Last));
         end;
      end;
   end Parse_Span;

   function Claims (Paths : Text_Lists.Vector; Path : String) return Boolean is
      Low  : Natural := 1;
      High : Natural := Natural (Paths.Length);   --  exclusive end is High + 1
   begin
      while Low <= High loop
         declare
            Mid : constant Positive := Low + (High - Low) / 2;
         begin
            if Paths (Mid) < Path then
               Low := Mid + 1;
            elsif Paths (Mid) > Path then
               High := Mid - 1;
            else
               return True;
            end if;
         end;
      end loop;
      return False;
   end Claims;

   function Check_Span
     (Of_Span     : Span; Of_Kind : Span_Kind; Paths : Text_Lists.Vector;
      Total_Lines : Natural) return Span_Problem
   is
   begin
      if not Claims (Paths, To_String (Of_Span.Path)) then
         return (Kind => Not_Claimed);
      end if;
      if Of_Span.First < 1 or else Of_Span.Last < Of_Span.First
        or else Of_Span.Last > Total_Lines
      then
         return (Kind => Out_Of_Range, Total_Lines => Total_Lines);
      end if;
      if Lines (Of_Span) > Cap (Of_Kind) then
         return (Kind => Too_Long, Line_Count => Lines (Of_Span));
      end if;
      return (Kind => None);
   end Check_Span;

   function Crux_Block (Of_Span : Span; Sliced, Lang : String) return String is
      Text : Unbounded_String;
   begin
      Append (Text, "```" & Lang & LF);
      Append (Text, Sliced);
      if Sliced'Length > 0 and then Sliced (Sliced'Last) /= LF then
         Append (Text, LF);
      end if;
      Append (Text, "```" & LF);
      Append
        (Text,
         Em_Dash & " `" & To_String (Of_Span.Path) & "`:" &
         Decimal_Image.Image (Of_Span.First) & "-" &
         Decimal_Image.Image (Of_Span.Last) & LF);
      return To_String (Text);
   end Crux_Block;

   function Substitute_Line (Text, Marker, Replacement : String) return String
   is
      Result      : Unbounded_String;
      Done        : Boolean         := False;
      First_Piece : Boolean         := True;
      Start       : Integer         := Text'First;
      Replaced    : constant String :=
        Ada.Strings.Fixed.Trim
          (Replacement, Ada.Strings.Maps.Null_Set,
           Ada.Strings.Maps.To_Set (LF));
   begin
      loop
         declare
            Stop       : constant Natural := Next_Line_Feed (Text, Start);
            Piece_Last : constant Integer :=
              (if Stop = 0 then Text'Last else Stop - 1);
            Piece      : constant String  := Text (Start .. Piece_Last);
         begin
            if not First_Piece then
               Append (Result, LF);
            end if;
            First_Piece := False;
            if not Done and then Ada.Strings.Fixed.Index (Piece, Marker) > 0
            then
               Append (Result, Replaced);
               Done := True;
            else
               Append (Result, Piece);
            end if;
            exit when Stop = 0;
            Start := Stop + 1;
         end;
      end loop;
      return To_String (Result);
   end Substitute_Line;

   --  A line that is one comment and nothing else, and that comment is the
   --  directive. A line holding two comments is not.
   function Only_Directive (Line, Keyword : String) return Boolean is
   begin
      if Line'Length < 7 or else not Starts_With (Line, "<!--")
        or else not Ends_With (Line, "-->")
      then
         return False;
      end if;
      declare
         Inner : constant String := Line (Line'First + 4 .. Line'Last - 3);
      begin
         return
           Ada.Strings.Fixed.Index (Inner, "-->") = 0
           and then Directive_Arg (Inner, Keyword).Found;
      end;
   end Only_Directive;

   function Strip_Grounded (Text : String) return String is
      Result : Unbounded_String;
      First  : Boolean := True;
      Start  : Integer := Text'First;
   begin
      loop
         declare
            Stop       : constant Natural := Next_Line_Feed (Text, Start);
            Piece_Last : constant Integer :=
              (if Stop = 0 then Text'Last else Stop - 1);
         begin
            if not Only_Directive
                (Trim (Text (Start .. Piece_Last)), Kind_Grounded)
            then
               if not First then
                  Append (Result, LF);
               end if;
               First := False;
               declare
                  Rest : Integer := Start;
               begin
                  loop
                     declare
                        Open  : constant Natural :=
                          Find (Text, "<!--", Rest, Piece_Last);
                        Close : constant Natural :=
                          (if Open = 0 then 0
                           else Find (Text, "-->", Open + 4, Piece_Last));
                     begin
                        exit when Open = 0 or else Close = 0;
                        if Directive_Arg
                            (Text (Open + 4 .. Close - 1), Kind_Grounded)
                            .Found
                        then
                           Append (Result, Text (Rest .. Open - 1));
                        else
                           Append (Result, Text (Rest .. Close + 2));
                        end if;
                        Rest := Close + 3;
                     end;
                  end loop;
                  Append (Result, Text (Rest .. Piece_Last));
               end;
            end if;
            exit when Stop = 0;
            Start := Stop + 1;
         end;
      end loop;
      return To_String (Result);
   end Strip_Grounded;

   --  The exclusive end of Text (Start .. End_Ex - 1) once its trailing
   --  blank lines are gone; Start when nothing but blank lines is left.
   function Content_End (Text : String; Start, End_Ex : Integer) return Integer
   is
      Stop : Integer := End_Ex;
   begin
      while Stop > Start loop
         declare
            Line_Start : Integer := Start;
         begin
            for I in reverse Start .. Stop - 1 loop
               if Text (I) = LF then
                  Line_Start := I + 1;
                  exit;
               end if;
            end loop;
            if Trim_All (Text (Line_Start .. Stop - 1))'Length > 0 then
               return Stop;
            end if;
            if Line_Start = Start then
               return Start;
            end if;
            Stop := Line_Start - 1;
         end;
      end loop;
      return Stop;
   end Content_End;

   function Trim_Blank_Edges (Text : String) return String is
      Start : Integer := Text'First;
   begin
      while Start <= Text'Last loop
         declare
            Stop : constant Natural := Next_Line_Feed (Text, Start);
         begin
            exit when Stop = 0
              or else Trim_All (Text (Start .. Stop - 1))'Length > 0;
            Start := Stop + 1;
         end;
      end loop;
      return Text (Start .. Content_End (Text, Start, Text'Last + 1) - 1);
   end Trim_Blank_Edges;

   function Yaml_Quoted (Text : String) return String is
      Result : Unbounded_String;
   begin
      for C of Text loop
         case C is
            when '\' =>
               Append (Result, "\\");

            when '"' =>
               Append (Result, "\""");

            when LF =>
               Append (Result, "\n");

            when Character'Val (13) =>
               Append (Result, "\r");

            when others =>
               Append (Result, C);
         end case;
      end loop;
      return To_String (Result);
   end Yaml_Quoted;

   function Image (Of_Note : Note) return String is
      Text    : Unbounded_String;
      Trimmed : constant String :=
        Trim_Blank_Edges (To_String (Of_Note.Prose));
   begin
      Append (Text, "---" & LF);
      Append (Text, "schema: graph-node/v1" & LF);
      Append
        (Text,
         "title: """ & Yaml_Quoted (To_String (Of_Note.Title)) & """" & LF);
      Append
        (Text,
         "summary: """ & Yaml_Quoted (To_String (Of_Note.Summary)) & """" &
         LF);
      Append (Text, "node_type: synapse-node" & LF);
      --  The repository and the branch apart, as in the namespace's
      --  Index.md, so a query can ask for every branch's copy of one node.
      Append (Text, "project: " & To_String (Of_Note.Project) & LF);
      Append (Text, "branch: " & To_String (Of_Note.Branch) & LF);
      Append (Text, "sources_digest: " & To_String (Of_Note.Digest) & LF);
      Append (Text, "stale: false" & LF);
      Append (Text, "built_at: """ & To_String (Of_Note.Built_At) & """" & LF);
      if Length (Of_Note.Commit) > 0 then
         Append (Text, "commit: " & To_String (Of_Note.Commit) & LF);
      end if;
      if Of_Note.Has_Crux then
         Append (Text, "crux_path: " & To_String (Of_Note.Crux.Path) & LF);
         Append
           (Text,
            "crux_lines: """ & To_String (Of_Note.Crux.Lines) & """" & LF);
      end if;
      if not Of_Note.Grounded.Is_Empty then
         Append (Text, "grounded_in:" & LF);
         for Row of Of_Note.Grounded loop
            Append
              (Text,
               "  - path: " & To_String (Row.Path) & LF & "    lines: """ &
               To_String (Row.Lines) & """" & LF & "    digest: " &
               To_String (Row.Digest) & LF);
         end loop;
      end if;
      Append (Text, "sources:" & LF);
      for Source of Of_Note.Sources loop
         Append
           (Text,
            "  - path: " & To_String (Source.Path) & LF & "    hash: " &
            Graph_Model.Hash_To_Hex (Source.Which) & LF);
      end loop;
      Append (Text, "---" & LF & LF);

      Append (Text, "# " & To_String (Of_Note.Title) & LF);
      Append (Text, Node_Format.Generated_Start & LF & LF);
      Append (Text, Trimmed);
      if Trimmed'Length > 0 and then Trimmed (Trimmed'Last) /= LF then
         Append (Text, LF);
      end if;
      Append (Text, LF & "## Sources" & LF);
      if Natural (Of_Note.Sources.Length) < Sources_Path_Threshold then
         for Source of Of_Note.Sources loop
            Append (Text, "- `" & To_String (Source.Path) & "`" & LF);
         end loop;
      else
         for Module of Of_Note.Modules loop
            Append
              (Text,
               "- `" & To_String (Module.Module) & "` (" &
               Decimal_Image.Image (Module.Count) & ")" & LF);
         end loop;
      end if;
      Append (Text, Node_Format.Generated_End & LF);
      if Length (Of_Note.Tail) > 0 then
         Append (Text, Of_Note.Tail);
         Append (Text, LF);
      else
         Append (Text, LF & "## Notes" & LF & LF);
      end if;
      return To_String (Text);
   end Image;

   procedure Set_Stale_True
     (Text : String; Result : out Unbounded_String; Changed : out Boolean)
   is
      CR_LF  : constant String  := Character'Val (13) & LF;
      CRLF   : constant Boolean := Starts_With (Text, "---" & CR_LF);
      Ending : constant String  := (if CRLF then CR_LF else "" & LF);
      Done   : Boolean          := False;
      In_FM  : Boolean          := False;
      First  : Boolean          := True;
      Start  : Integer          := Text'First;
   begin
      Result  := Null_Unbounded_String;
      Changed := False;
      if not CRLF and then not Starts_With (Text, "---" & LF) then
         return;
      end if;

      loop
         declare
            Stop     : constant Natural := Next_Line_Feed (Text, Start);
            Raw_Last : constant Integer :=
              (if Stop = 0 then Text'Last else Stop - 1);
            Raw_Line : constant String  := Text (Start .. Raw_Last);
            --  Compared without a trailing CR but written as it was, so a
            --  CRLF file keeps its line endings.
            Line     : constant String  :=
              Ada.Strings.Fixed.Trim
                (Raw_Line, Ada.Strings.Maps.Null_Set,
                 Ada.Strings.Maps.To_Set (Character'Val (13)));
         begin
            if First then
               First := False;
               In_FM := True;
               Append (Result, Raw_Line & LF);
            elsif In_FM and then Line = "---" then
               --  An absent `stale:` goes just before the closing marker, so
               --  a node built before the field existed is still flaggable.
               if not Done then
                  Append (Result, "stale: true" & Ending);
                  Done    := True;
                  Changed := True;
               end if;
               In_FM := False;
               Append (Result, Raw_Line & LF);
            elsif In_FM and then not Done and then Starts_With (Line, "stale:")
            then
               Append (Result, "stale: true" & Ending);
               Done := True;
               if Trim (Line (Line'First + 6 .. Line'Last)) /= "true" then
                  Changed := True;
               end if;
            elsif Stop = 0 and then Raw_Line'Length = 0 then
               exit;  --  the piece after the last line feed is not a line
            else
               Append (Result, Raw_Line & LF);
            end if;
            exit when Stop = 0;
            Start := Stop + 1;
         end;
      end loop;
   end Set_Stale_True;

   function Fenced_Text (Text : String) return String is
      Result : Unbounded_String;
      Inside : Boolean := False;
      Start  : Integer := Text'First;
   begin
      loop
         declare
            Stop       : constant Natural := Next_Line_Feed (Text, Start);
            Piece_Last : constant Integer :=
              (if Stop = 0 then Text'Last else Stop - 1);
            Line       : constant String  := Text (Start .. Piece_Last);
         begin
            if Starts_With (Line, "```") then
               Inside := not Inside;
            elsif Inside then
               exit when Stop = 0 and then Line'Length = 0;
               Append (Result, Line & LF);
            end if;
            exit when Stop = 0;
            Start := Stop + 1;
         end;
      end loop;
      return To_String (Result);
   end Fenced_Text;

   --  The position of the first line at or after From that is not blank, or
   --  one past the end of Text.
   function Skip_Blank_Lines (Text : String; From : Integer) return Integer is
      Here : Integer := From;
   begin
      while Here <= Text'Last loop
         declare
            Stop : constant Natural := Next_Line_Feed (Text, Here);
            Last : constant Integer :=
              (if Stop = 0 then Text'Last else Stop - 1);
         begin
            exit when Trim_All (Text (Here .. Last))'Length > 0;
            if Stop = 0 then
               return Text'Last + 1;
            end if;
            Here := Stop + 1;
         end;
      end loop;
      return Here;
   end Skip_Blank_Lines;

   function Notes_Body (Text : String) return String is
      Marker : constant Natural :=
        Find (Text, Node_Format.Generated_End, Text'First, Text'Last);
   begin
      if Marker = 0 then
         return "";
      end if;
      declare
         After : constant Positive :=
           Marker + Node_Format.Generated_End'Length;
         Stop  : constant Natural  := Next_Line_Feed (Text, After);
      begin
         if Stop = 0 then
            return "";
         end if;
         declare
            Rest : Integer := Skip_Blank_Lines (Text, Stop + 1);
         begin
            --  The heading itself is not content, but a differently worded
            --  heading is, since something wrote it deliberately.
            if Starts_With (Text (Rest .. Text'Last), "## Notes") then
               declare
                  Line_End : constant Natural := Next_Line_Feed (Text, Rest);
                  Line     : constant Integer :=
                    (if Line_End = 0 then Text'Last else Line_End - 1);
               begin
                  if Trim_All (Text (Rest .. Line))'Length = 8 then
                     Rest :=
                       (if Line_End = 0 then Text'Last + 1 else Line_End + 1);
                  end if;
               end;
            end if;
            Rest := Skip_Blank_Lines (Text, Rest);
            return Text (Rest .. Content_End (Text, Rest, Text'Last + 1) - 1);
         end;
      end;
   end Notes_Body;

end Synapse.Core.Emit;
