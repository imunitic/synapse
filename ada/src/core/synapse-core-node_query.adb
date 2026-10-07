with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;

with Synapse.Core.Frontmatter;
with Synapse.Core.Line_Slice;

package body Synapse.Core.Node_Query is

   use Line_Slice;

   Blanks : constant Ada.Strings.Maps.Character_Set :=
     Ada.Strings.Maps.To_Set (" " & Character'Val (9));

   Only_LF : constant Ada.Strings.Maps.Character_Set :=
     Ada.Strings.Maps.To_Set (LF);

   function Starts_With (S, Prefix : String) return Boolean is
     (S'Length >= Prefix'Length
      and then S (S'First .. S'First + Prefix'Length - 1) = Prefix);

   function Trim_Left_Blanks (S : String) return String is
     (Ada.Strings.Fixed.Trim (S, Blanks, Ada.Strings.Maps.Null_Set));

   function Trim_Blanks (S : String) return String is
     (Ada.Strings.Fixed.Trim (S, Blanks, Blanks));

   function Without_CR (S : String) return String is
     (Ada.Strings.Fixed.Trim
        (S, Ada.Strings.Maps.Null_Set,
         Ada.Strings.Maps.To_Set (Character'Val (13))));

   --  The text of a span of Text.
   function Cut (Text : String; Where : Frontmatter.Span) return String is
     (Text (Text'First + Where.First .. Text'First + Where.Stop - 1));

   function Body_Of (Text : String) return Maybe_Text is
      Start : constant Natural :=
        Ada.Strings.Fixed.Index (Text, Node_Format.Generated_Start);
   begin
      if Start = 0 then
         return (Found => False);
      end if;
      declare
         After : constant Positive :=
           Start + Node_Format.Generated_Start'Length;
         Stop  : constant Natural  :=
           (if After > Text'Last then 0
            else Ada.Strings.Fixed.Index
                (Text (After .. Text'Last), Node_Format.Generated_End));
      begin
         if Stop = 0 then
            return (Found => False);
         end if;
         declare
            First : Integer := After;
            Last  : Integer := Stop - 1;
         begin
            if First <= Last and then Text (First) = LF then
               First := First + 1;
            end if;
            if First <= Last and then Text (Last) = LF then
               Last := Last - 1;
            end if;
            return
              (Found => True,
               Value => To_Unbounded_String (Text (First .. Last)));
         end;
      end;
   end Body_Of;

   function Body_After_Frontmatter (Text : String) return String is
   begin
      return Cut (Text, Frontmatter.Body_After (Text));
   end Body_After_Frontmatter;

   function Field (Text, Key : String) return Maybe_Text is
      Found : constant Frontmatter.Maybe_Span :=
        Frontmatter.Find_Field (Text, Key);
   begin
      if not Found.Found then
         return (Found => False);
      end if;
      return
        (Found => True,
         Value => To_Unbounded_String (Cut (Text, Found.Value)));
   end Field;

   function Scalar (Text, Key : String) return Maybe_Text is
      Line_Span : constant Frontmatter.Maybe_Span :=
        Frontmatter.Find_Key_Line (Text, Key);
   begin
      if not Line_Span.Found then
         return (Found => False);
      end if;
      declare
         Line : constant String := Cut (Text, Line_Span.Value);
         Raw  : constant String :=
           Trim_Left_Blanks (Line (Line'First + Key'Length + 1 .. Line'Last));
      begin
         --  A bare value carries no escapes, and unescaping it would be
         --  inventing a rule.
         if Raw'Length < 2 or else Raw (Raw'First) /= '"'
           or else Raw (Raw'Last) /= '"'
         then
            return (Found => True, Value => To_Unbounded_String (Raw));
         end if;
         declare
            Inner  : constant String := Raw (Raw'First + 1 .. Raw'Last - 1);
            Result : Unbounded_String;
            I      : Integer         := Inner'First;
         begin
            while I <= Inner'Last loop
               if Inner (I) = '\' and then I < Inner'Last
                 and then Inner (I + 1) in '\' | '"'
               then
                  I := I + 1;
               end if;
               Append (Result, Inner (I));
               I := I + 1;
            end loop;
            return (Found => True, Value => Result);
         end;
      end;
   end Scalar;

   --  The lines under `## Links`, up to the next `## ` heading, without the
   --  heading; none when the section is absent or empty.
   function Links_Block (Inner : String) return Maybe_Text is
      Heading : constant String  := "## Links" & LF;
      At_Head : constant Natural :=
        (if Starts_With (Inner, Heading) then Inner'First
         else Ada.Strings.Fixed.Index (Inner, LF & Heading));
   begin
      if At_Head = 0 then
         return (Found => False);
      end if;
      declare
         First : constant Integer :=
           (if At_Head = Inner'First and then Starts_With (Inner, Heading) then
              At_Head + Heading'Length
            else At_Head + 1 + Heading'Length);
         Rest  : constant String  :=
           (if First > Inner'Last then "" else Inner (First .. Inner'Last));
         Stop : constant Natural := Ada.Strings.Fixed.Index (Rest, LF & "## ");
         Block : constant String  :=
           Ada.Strings.Fixed.Trim
             ((if Stop = 0 then Rest else Rest (Rest'First .. Stop - 1)),
              Only_LF, Only_LF);
      begin
         if Block'Length = 0 then
            return (Found => False);
         end if;
         return (Found => True, Value => To_Unbounded_String (Block));
      end;
   end Links_Block;

   function Brief (Text : String) return Maybe_Text is
      Inner  : constant Maybe_Text := Body_Of (Text);
      Result : Unbounded_String;
   begin
      if not Inner.Found then
         return (Found => False);
      end if;
      declare
         Summary : constant Maybe_Text := Scalar (Text, "summary");
         Path    : constant Maybe_Text := Field (Text, "crux_path");
         Lines   : constant Maybe_Text := Field (Text, "crux_lines");
         Links : constant Maybe_Text := Links_Block (To_String (Inner.Value));
      begin
         if Summary.Found then
            Append (Result, "summary: " & Summary.Value & LF);
         end if;
         if Path.Found and then Length (Path.Value) > 0 then
            Append (Result, "crux: " & Path.Value);
            if Lines.Found and then Length (Lines.Value) > 0 then
               Append (Result, ":" & Lines.Value);
            end if;
            Append (Result, LF);
         end if;
         if Links.Found then
            Append (Result, "## Links" & LF & Links.Value & LF);
         end if;
      end;
      return (Found => True, Value => Result);
   end Brief;

   --  A run of digits as a line number, clamped; 0 when it is not a run of
   --  digits or is zero.
   function Line_Number (S : String) return Natural is
      Value : Natural := 0;
   begin
      if S'Length = 0 then
         return 0;
      end if;
      for C of S loop
         if C not in '0' .. '9' then
            return 0;
         end if;
         declare
            Digit : constant Natural :=
              Character'Pos (C) - Character'Pos ('0');
         begin
            Value :=
              (if Value > (Positive'Last - Digit) / 10 then Positive'Last
               else Value * 10 + Digit);
         end;
      end loop;
      return Value;
   end Line_Number;

   function Parse_Line_Ranges (Spec : String) return Maybe_Ranges is
      Result : Text_Search.Range_Vectors.Vector;
      Start  : Integer := Spec'First;
   begin
      loop
         declare
            Comma : constant Natural :=
              (if Start > Spec'Last then 0
               else Ada.Strings.Fixed.Index (Spec (Start .. Spec'Last), ","));
            Item  : constant String  :=
              Spec (Start .. (if Comma = 0 then Spec'Last else Comma - 1));
            Dash  : constant Natural := Ada.Strings.Fixed.Index (Item, "-");
            First : constant Natural :=
              Line_Number
                (if Dash = 0 then Item else Item (Item'First .. Dash - 1));
            Last  : constant Natural :=
              (if Dash = 0 then First
               else Line_Number (Item (Dash + 1 .. Item'Last)));
         begin
            if First = 0 or else Last < First then
               return (Found => False);
            end if;
            Result.Append
              (Text_Search.Line_Range'(First => First, Last => Last));
            exit when Comma = 0;
            Start := Comma + 1;
         end;
      end loop;
      return (Found => True, Value => Result);
   end Parse_Line_Ranges;

   function Lines_In
     (Text : String; Ranges : Text_Search.Range_Vectors.Vector)
      return Maybe_Text
   is
      Total  : constant Natural :=
        Count_Lines (Text) +
        (if Text'Length > 0 and then Text (Text'Last) /= LF then 1 else 0);
      Result : Unbounded_String;
   begin
      for R of Ranges loop
         if R.First > Total then
            return (Found => False);
         end if;
      end loop;
      for R of Ranges loop
         declare
            Found : constant Maybe_Bounds :=
              Bounds (Text, R.First, Natural'Min (R.Last, Total));
         begin
            if Found.Found then
               Append (Result, Text (Found.Value.From .. Found.Value.To));
               if Found.Value.To < Found.Value.From
                 or else Text (Found.Value.To) /= LF
               then
                  Append (Result, LF);
               end if;
            end if;
         end;
      end loop;
      return (Found => True, Value => Result);
   end Lines_In;

   --  Whether a frontmatter line opens or closes a block: a letter or an
   --  underscore at column zero is a new top-level key.
   function Starts_A_Key (Line : String) return Boolean is
     (Line'Length > 0
      and then (Line (Line'First) in 'a' .. 'z' | 'A' .. 'Z' | '_'));

   --  `  - path: X` with any leading blanks; none for any other line.
   function Dash_Path (Line : String) return Maybe_Text is
      Rest : constant String := Trim_Left_Blanks (Line);
   begin
      if not Starts_With (Rest, "-") then
         return (Found => False);
      end if;
      declare
         After : constant String :=
           Trim_Left_Blanks (Rest (Rest'First + 1 .. Rest'Last));
      begin
         if not Starts_With (After, "path:") then
            return (Found => False);
         end if;
         return
           (Found => True,
            Value =>
              To_Unbounded_String
                (Trim_Left_Blanks (After (After'First + 5 .. After'Last))));
      end;
   end Dash_Path;

   function Sources (Text : String) return Text_Lists.Vector is
      Result     : Text_Lists.Vector;
      Block      : constant Frontmatter.Block := Frontmatter.Locate (Text);
      In_Sources : Boolean                    := False;
   begin
      if not Block.Present then
         return Result;
      end if;
      declare
         Position : Natural := Block.Lines_Start;
         Where    : Frontmatter.Span;
         Found    : Boolean;
      begin
         loop
            Frontmatter.Next_Line (Text, Block, Position, Where, Found);
            exit when not Found;
            declare
               Line : constant String := Cut (Text, Where);
            begin
               if Starts_A_Key (Line) then
                  In_Sources := Line = "sources:";
               elsif In_Sources then
                  declare
                     Path : constant Maybe_Text := Dash_Path (Line);
                  begin
                     if Path.Found then
                        Result.Append (Path.Value);
                     end if;
                  end;
               end if;
            end;
         end loop;
      end;
      return Result;
   end Sources;

   function Module_Counts
     (Paths : Text_Lists.Vector; Chains : Text_Lists.Vector)
      return Node_Format.Module_Count_Vectors.Vector
   is
      package Count_Maps is new Ada.Containers.Indefinite_Ordered_Maps
        (String, Natural);

      Counts : Count_Maps.Map;
      Result : Node_Format.Module_Count_Vectors.Vector;
   begin
      for Path of Paths loop
         if Length (Path) > 0 then
            declare
               Module : constant String            :=
                 Node_Format.Module_Of (To_String (Path), Chains);
               Place  : constant Count_Maps.Cursor := Counts.Find (Module);
            begin
               if Count_Maps.Has_Element (Place) then
                  Counts.Replace_Element
                    (Place, Count_Maps.Element (Place) + 1);
               else
                  Counts.Insert (Module, 1);
               end if;
            end;
         end if;
      end loop;
      for Place in Counts.Iterate loop
         Result.Append
           (Node_Format.Module_Count'
              (Module => To_Unbounded_String (Count_Maps.Key (Place)),
               Count  => Count_Maps.Element (Place)));
      end loop;
      return Result;
   end Module_Counts;

   --  The edge on a line of `## Links`, if it is one.
   procedure Take_Edge (Line : String; Result : in out Edge_Vectors.Vector) is
   begin
      if not Starts_With (Line, "-") then
         return;
      end if;
      declare
         After : constant String  :=
           Trim_Left_Blanks (Line (Line'First + 1 .. Line'Last));
         Open  : constant Natural := Ada.Strings.Fixed.Index (After, "[[");
      begin
         if Open = 0 then
            return;
         end if;
         declare
            Close    : constant Natural :=
              (if Open + 2 > After'Last then 0
               else Ada.Strings.Fixed.Index
                   (After (Open + 2 .. After'Last), "]]"));
            Relation : constant String  :=
              Trim_Blanks (After (After'First .. Open - 1));
         begin
            if Close = 0 or else Relation'Length = 0 or else Close = Open + 2
            then
               return;
            end if;
            Result.Append
              (Edge'
                 (Relation => To_Unbounded_String (Relation),
                  Target   =>
                    To_Unbounded_String (After (Open + 2 .. Close - 1))));
         end;
      end;
   end Take_Edge;

   function Edges (Text : String) return Edge_Vectors.Vector is
      Result   : Edge_Vectors.Vector;
      In_Links : Boolean := False;
      Start    : Integer := Text'First;
   begin
      loop
         declare
            Stop : constant Natural := Next_Line_Feed (Text, Start);
            Line : constant String  :=
              Without_CR
                (Text (Start .. (if Stop = 0 then Text'Last else Stop - 1)));
         begin
            if Line = "## Links" then
               In_Links := True;
            elsif In_Links and then Starts_With (Line, "## ") then
               exit;
            elsif In_Links then
               Take_Edge (Line, Result);
            end if;
            exit when Stop = 0;
            Start := Stop + 1;
         end;
      end loop;
      return Result;
   end Edges;

end Synapse.Core.Node_Query;
