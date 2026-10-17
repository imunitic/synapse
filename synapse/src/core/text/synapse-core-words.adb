with Ada.Strings.Unbounded;

with Synapse.Core.UTF8;

package body Synapse.Core.Words is

   use Ada.Strings.Unbounded;

   function Is_Upper (C : Character) return Boolean
   is (C in 'A' .. 'Z');

   function Is_Lower_Or_Digit (C : Character) return Boolean
   is (C in 'a' .. 'z' | '0' .. '9');

   function Is_High (C : Character) return Boolean
   is (Character'Pos (C) >= 16#80#);

   function Lower (S : String) return String is
      Result : String := S;
   begin
      for C of Result loop
         if Is_Upper (C) then
            C := Character'Val (Character'Pos (C) + 32);
         end if;
      end loop;
      return Result;
   end Lower;

   function Split_Words (Text : String) return Text_Lists.Vector is
      Result : Text_Lists.Vector;
      I      : Natural := Text'First;
   begin
      while I <= Text'Last loop
         declare
            Start : constant Natural := I;
         begin
            if Is_Upper (Text (I)) then
               while I <= Text'Last and then Is_Upper (Text (I)) loop
                  I := I + 1;
               end loop;
               while I <= Text'Last and then Is_Lower_Or_Digit (Text (I)) loop
                  I := I + 1;
               end loop;
            elsif Is_Lower_Or_Digit (Text (I)) then
               while I <= Text'Last and then Is_Lower_Or_Digit (Text (I)) loop
                  I := I + 1;
               end loop;
            elsif Is_High (Text (I)) then
               while I <= Text'Last and then Is_High (Text (I)) loop
                  I := I + 1;
               end loop;
            end if;

            if I > Start then
               Result.Append
                 (To_Unbounded_String (Lower (Text (Start .. I - 1))));
            else
               I := I + 1;  --  a separator
            end if;
         end;
      end loop;
      return Result;
   end Split_Words;

   --  The number of characters: bytes that do not continue a sequence, or
   --  the number of bytes when Word is not valid UTF-8.
   function Characters (Word : String) return Natural is
      Count : Natural := 0;
   begin
      if not UTF8.Is_Valid (Word) then
         return Word'Length;
      end if;
      for C of Word loop
         if Character'Pos (C) / 64 /= 2 then
            Count := Count + 1;
         end if;
      end loop;
      return Count;
   end Characters;

   function Keep (Word : String; Stopwords : Text_Lists.Set) return Boolean
   is (Characters (Word) >= 4
       and then not (for all C of Word => C in '0' .. '9')
       and then not Stopwords.Contains (Word));

   function Query_Terms
     (Query : String; Stopwords : Text_Lists.Set) return Text_Lists.Vector
   is
      Result : Text_Lists.Vector;
   begin
      for Word of Split_Words (Query) loop
         declare
            Text : constant String := To_String (Word);
         begin
            if Keep (Text, Stopwords) and then not Result.Contains (Word) then
               Result.Append (Word);
            end if;
         end;
      end loop;
      return Result;
   end Query_Terms;

   function Distinctiveness
     (Docs_With_Term, Docs, K : Natural) return Long_Float
   is
      D : constant Long_Float :=
        Long_Float (Natural'Max (2, Docs / Natural'Max (1, K)));
   begin
      return D / (D + Long_Float (Docs_With_Term));
   end Distinctiveness;

   function Weighted_Score
     (Counts, Doc_Freq : Natural_Array; Docs : Natural) return Long_Float
   is
      Sum : Long_Float := 0.0;
   begin
      for I in Counts'Range loop
         if Counts (I) > 0 then
            Sum :=
              Sum
              + Long_Float (Counts (I))
                * Distinctiveness (Doc_Freq (I), Docs, 20);
         end if;
      end loop;
      return Sum;
   end Weighted_Score;

   function Parse_Stopwords (Conf_Text : String) return Text_Lists.Set is
      Result : Text_Lists.Set;
      Start  : Natural := Conf_Text'First;

      procedure Take (Raw : String) is
         First : Natural := Raw'First;
         Last  : Natural := Raw'Last;
      begin
         while First <= Last
           and then Raw (First) in ' ' | Character'Val (9) | Character'Val (13)
         loop
            First := First + 1;
         end loop;
         while Last >= First
           and then Raw (Last) in ' ' | Character'Val (9) | Character'Val (13)
         loop
            Last := Last - 1;
         end loop;
         if First <= Last and then Raw (First) /= '#' then
            Result.Include (Lower (Raw (First .. Last)));
         end if;
      end Take;
   begin
      for I in Conf_Text'First .. Conf_Text'Last + 1 loop
         if I > Conf_Text'Last or else Conf_Text (I) = Character'Val (10) then
            Take (Conf_Text (Start .. I - 1));
            Start := I + 1;
         end if;
      end loop;
      return Result;
   end Parse_Stopwords;

end Synapse.Core.Words;
