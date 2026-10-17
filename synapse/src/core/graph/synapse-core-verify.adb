with Ada.Strings.Fixed;
with Ada.Strings.Maps;

with Synapse.Core.Frontmatter;
with Synapse.Core.Graph_Model;
with Synapse.Core.Hashing;
with Synapse.Core.Line_Slice;
with Synapse.Core.Node_Format;

package body Synapse.Core.Verify is

   use Line_Slice;
   use type Ada.Containers.Count_Type;

   Blanks : constant Ada.Strings.Maps.Character_Set :=
     Ada.Strings.Maps.To_Set (" " & Character'Val (9));

   Quotes : constant Ada.Strings.Maps.Character_Set :=
     Ada.Strings.Maps.To_Set ("""");

   function Reason (S : Staleness) return String is
   begin
      case S.Kind is
         when Clean =>
            return "";

         when Node_File_Missing =>
            return "node file missing from the vault";

         when No_Digest =>
            return "no sources_digest (built before the digest existed)";

         when No_Sources =>
            return "no sources listed";

         when Hashing_Failed =>
            return "hashing failed";

         when Content_Changed =>
            return "content changed";

         when Sources_Gone =>
            declare
               Text : Unbounded_String :=
                 To_Unbounded_String ("source files gone: ");
            begin
               for I in 1 .. Natural (S.Gone.Length) loop
                  if I > 1 then
                     Append (Text, " ");
                  end if;
                  Append (Text, S.Gone (I));
               end loop;
               return To_String (Text);
            end;
      end case;
   end Reason;

   function Check
     (Present : Boolean; Has_Digest : Boolean; Stored_Digest : String;
      Paths   : Text_Lists.Vector; Missing : Text_Lists.Vector;
      Hashes  : Text_Lists.Vector) return Staleness
   is
      Sources : Graph_Model.Source_Vectors.Vector;
   begin
      if not Present then
         return (Kind => Node_File_Missing);
      end if;
      if not Has_Digest or else Stored_Digest = "" then
         return (Kind => No_Digest);
      end if;
      if Paths.Is_Empty then
         return (Kind => No_Sources);
      end if;
      if not Missing.Is_Empty then
         return (Kind => Sources_Gone, Gone => Missing);
      end if;
      if Hashes.Length /= Paths.Length then
         return (Kind => Hashing_Failed);
      end if;
      for I in 1 .. Natural (Paths.Length) loop
         declare
            Hash : constant Graph_Model.Hash_Result :=
              Graph_Model.Hash_From_Hex (To_String (Hashes (I)));
         begin
            if not Hash.Found then
               return (Kind => Hashing_Failed);
            end if;
            Sources.Append
              (Graph_Model.Source_Ref'
                 (Path => Paths (I), Which => Hash.Value));
         end;
      end loop;
      return
        (if Node_Format.Sources_Digest (Sources) = Stored_Digest then
           (Kind => Clean)
         else (Kind => Content_Changed));
   end Check;

   function Range_Of (G : Grounding) return Maybe_Range is
      Text : constant String  := To_String (G.Lines);
      Dash : constant Natural := Ada.Strings.Fixed.Index (Text, "-");

      function Number (S : String) return Integer is
         Value : Natural := 0;
      begin
         if S'Length = 0 then
            return -1;
         end if;
         for C of S loop
            if C not in '0' .. '9' then
               return -1;
            end if;
            if Value > (Positive'Last - 9) / 10 then
               return Positive'Last;
            end if;
            Value := Value * 10 + (Character'Pos (C) - Character'Pos ('0'));
         end loop;
         return Value;
      end Number;
   begin
      if Dash = 0 then
         return (Found => False);
      end if;
      declare
         First : constant Integer := Number (Text (Text'First .. Dash - 1));
         Last  : constant Integer := Number (Text (Dash + 1 .. Text'Last));
      begin
         if First < 1 or else Last < First then
            return (Found => False);
         end if;
         return (Found => True, Value => (First => First, Last => Last));
      end;
   end Range_Of;

   --  The value of `key: value` in a line, blanks and every quote trimmed.
   function Field_Value
     (Line, Key : String; Value : out Unbounded_String) return Boolean
   is
   begin
      if Line'Length <= Key'Length
        or else Line (Line'First .. Line'First + Key'Length - 1) /= Key
        or else Line (Line'First + Key'Length) /= ':'
      then
         return False;
      end if;
      Value :=
        To_Unbounded_String
          (Ada.Strings.Fixed.Trim
             (Ada.Strings.Fixed.Trim
                (Line (Line'First + Key'Length + 1 .. Line'Last), Blanks,
                 Ada.Strings.Maps.Null_Set),
              Quotes, Quotes));
      return True;
   end Field_Value;

   function Groundings (Text : String) return Grounding_Vectors.Vector is
      Result   : Grounding_Vectors.Vector;
      Block    : constant Frontmatter.Block := Frontmatter.Locate (Text);
      In_Block : Boolean                    := False;
      Current  : Grounding;
      Has_Item : Boolean                    := False;
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
               Line : constant String :=
                 Text
                   (Text'First + Where.First .. Text'First + Where.Stop - 1);
            begin
               if Line'Length > 0
                 and then Line (Line'First) in 'a' .. 'z' | 'A' .. 'Z' | '_'
               then
                  if Has_Item then
                     Result.Append (Current);
                     Has_Item := False;
                  end if;
                  In_Block := Line = "grounded_in:";
               elsif In_Block then
                  declare
                     Trimmed : constant String :=
                       Ada.Strings.Fixed.Trim
                         (Line, Blanks, Ada.Strings.Maps.Null_Set);
                     Value   : Unbounded_String;
                  begin
                     if Trimmed'Length >= 2
                       and then Trimmed (Trimmed'First .. Trimmed'First + 1) =
                         "- "
                     then
                        if Has_Item then
                           Result.Append (Current);
                        end if;
                        Current  := (others => <>);
                        Has_Item := True;
                        if Field_Value
                            (Ada.Strings.Fixed.Trim
                               (Trimmed (Trimmed'First + 2 .. Trimmed'Last),
                                Blanks, Ada.Strings.Maps.Null_Set),
                             "path", Value)
                        then
                           Current.Path := Value;
                        end if;
                     elsif Has_Item then
                        if Field_Value (Trimmed, "path", Value) then
                           Current.Path := Value;
                        end if;
                        if Field_Value (Trimmed, "lines", Value) then
                           Current.Lines := Value;
                        end if;
                        if Field_Value (Trimmed, "digest", Value) then
                           Current.Digest := Value;
                        end if;
                     end if;
                  end;
               end if;
            end;
         end loop;
      end;
      if Has_Item then
         Result.Append (Current);
      end if;
      return Result;
   end Groundings;

   function Find_Moved
     (Content : String; Span : Natural; Digest : String) return Maybe_Range
   is
      --  The position of the line after the one that starts at From.
      function After_Line (From : Integer) return Integer is
         Stop : constant Natural := Next_Line_Feed (Content, From);
      begin
         return (if Stop = 0 then Content'Last + 1 else Stop + 1);
      end After_Line;

      Total        : constant Natural :=
        Count_Lines (Content) +
        (if
           Content'Length > 0
           and then Content (Content'Last) = Character'Val (10)
         then 0
         else 1);
      Window_Start : Integer          := Content'First;
      Window_End   : Integer          := Content'First;
      Start        : Positive         := 1;
   begin
      if Span = 0 or else Span > Total then
         return (Found => False);
      end if;
      for I in 1 .. Span loop
         Window_End := After_Line (Window_End);
      end loop;
      while Start + Span - 1 <= Total loop
         if Hashing.Sha256_Hex (Content (Window_Start .. Window_End - 1)) =
           Digest
         then
            return
              (Found => True,
               Value => (First => Start, Last => Start + Span - 1));
         end if;
         Window_Start := After_Line (Window_Start);
         Window_End   := After_Line (Window_End);
         Start        := Start + 1;
      end loop;
      return (Found => False);
   end Find_Moved;

end Synapse.Core.Verify;
