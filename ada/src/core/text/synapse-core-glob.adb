package body Synapse.Core.Glob with SPARK_Mode is

   --  Offsets below are 0-based distances from a string's first byte.

   --  Whether Seg (SO .. SO + Len - 1) occurs in Text at offset TO.
   function Matches_At
     (Text : String; TO : Natural; Seg : String; SO, Len : Natural)
      return Boolean
   with
     Pre =>
       Text'Last < Positive'Last
       and then Seg'Last < Positive'Last
       and then SO <= Seg'Length
       and then Len <= Seg'Length - SO
       and then TO <= Text'Length
       and then Len <= Text'Length - TO
   is
   begin
      for K in 0 .. Len - 1 loop
         pragma Loop_Invariant
           (for all J in 0 .. K - 1
            => Text (Text'First + TO + J) = Seg (Seg'First + SO + J));
         if Text (Text'First + TO + K) /= Seg (Seg'First + SO + K) then
            return False;
         end if;
      end loop;
      return True;
   end Matches_At;

   --  The leftmost offset at or after From where the segment occurs.
   procedure Find_From
     (Text  : String;
      From  : Natural;
      Seg   : String;
      SO    : Natural;
      Len   : Natural;
      Found : out Boolean;
      Index : out Natural)
   with
     Pre  =>
       Text'Last < Positive'Last
       and then Seg'Last < Positive'Last
       and then SO <= Seg'Length
       and then Len <= Seg'Length - SO
       and then From <= Text'Length,
     Post => (if Found then Index <= Text'Length and then Len <= Text'Length - Index)
   is
      I : Natural := From;
   begin
      Found := False;
      Index := 0;
      while Len <= Text'Length - I loop
         pragma Loop_Invariant (I >= From and then I <= Text'Length);
         pragma Loop_Variant (Increases => I);
         if Matches_At (Text, I, Seg, SO, Len) then
            Found := True;
            Index := I;
            return;
         end if;
         exit when I = Text'Length;
         I := I + 1;
      end loop;
   end Find_From;

   function Glob_Match (Pattern, Text : String) return Boolean is
   begin
      if Pattern'Length = 0 then
         return Text'Length = 0;
      end if;

      declare
         Ends_With_Star : constant Boolean :=
           Pattern (Pattern'Last) = '*';
         Seg_Start      : Natural := 0;
         Seg_End        : Natural;
         Pos            : Natural := 0;  --  text consumed so far
         First          : Boolean := True;
         Last_Start     : Natural := 0;  --  the last non-empty segment
         Last_Len       : Natural := 0;
      begin
         loop
            pragma Loop_Invariant (Seg_Start <= Pattern'Length);
            pragma Loop_Invariant (Pos <= Text'Length);
            pragma Loop_Invariant (Last_Start <= Pattern'Length);
            pragma Loop_Invariant (Last_Len <= Pattern'Length - Last_Start);
            pragma Loop_Variant (Increases => Seg_Start);

            --  The segment runs to the next '*', or to the end.
            Seg_End := Seg_Start;
            while Seg_End < Pattern'Length
              and then Pattern (Pattern'First + Seg_End) /= '*'
            loop
               pragma Loop_Invariant
                 (Seg_End >= Seg_Start and then Seg_End < Pattern'Length);
               pragma Loop_Variant (Increases => Seg_End);
               Seg_End := Seg_End + 1;
            end loop;

            declare
               Len : constant Natural := Seg_End - Seg_Start;
            begin
               if Len = 0 then
                  First := False;
               else
                  Last_Start := Seg_Start;
                  Last_Len := Len;
                  if First then
                     if Len > Text'Length
                       or else not Matches_At
                                     (Text, 0, Pattern, Seg_Start, Len)
                     then
                        return False;
                     end if;
                     Pos := Len;
                     First := False;
                  else
                     declare
                        Found : Boolean;
                        Index : Natural;
                     begin
                        Find_From (Text, Pos, Pattern, Seg_Start, Len,
                                   Found, Index);
                        if not Found then
                           return False;
                        end if;
                        Pos := Index + Len;
                     end;
                  end if;
               end if;
            end;

            exit when Seg_End = Pattern'Length;
            Seg_Start := Seg_End + 1;
         end loop;

         --  Without a trailing '*' the last literal must end the text.
         if not Ends_With_Star and then Pos /= Text'Length then
            return
              Last_Len <= Text'Length
              and then Matches_At
                         (Text, Text'Length - Last_Len,
                          Pattern, Last_Start, Last_Len);
         end if;
         return True;
      end;
   end Glob_Match;

end Synapse.Core.Glob;
