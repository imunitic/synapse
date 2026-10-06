with Ada.Strings.Unbounded;

with Synapse.Core.Unicode;

package body Synapse.Core.Text_Search is

   use Ada.Strings.Unbounded;

   LF : constant Character := Character'Val (10);

   function Contains_Any
     (Line : String; Terms : Text_Lists.Vector) return Boolean is
   begin
      for Term of Terms loop
         declare
            Needle : constant String := To_String (Term);
         begin
            if Needle'Last < Positive'Last
              and then Unicode.Contains_Case_Fold (Line, Needle)
            then
               return True;
            end if;
         end;
      end loop;
      return False;
   end Contains_Any;

   --  Calls Visit with each line's bytes and 1-based number; stops when it
   --  returns False.
   generic
      with
        function Visit (First, Last : Natural; Number : Positive)
          return Boolean;
   procedure For_Each_Line (Text : String);

   procedure For_Each_Line (Text : String) is
      Start  : Positive := Text'First;
      Number : Positive := 1;
   begin
      for I in Text'First .. Text'Last + 1 loop
         if I > Text'Last or else Text (I) = LF then
            exit when not Visit (Start, I - 1, Number);
            Start := I + 1;
            Number := Number + 1;
         end if;
      end loop;
   end For_Each_Line;

   function First_Matching_Line (Text, Query : String) return Maybe_Line is
      Result : Maybe_Line;

      function Visit (First, Last : Natural; Number : Positive) return Boolean
      is
         pragma Unreferenced (Number);
      begin
         if Last >= First
           and then Unicode.Contains_Case_Fold (Text (First .. Last), Query)
         then
            Result := (Found => True, First => First, Last => Last);
            return False;
         end if;
         return True;
      end Visit;

      procedure Scan is new For_Each_Line (Visit);
   begin
      Scan (Text);
      return Result;
   end First_Matching_Line;

   function First_Matching_Line_Any
     (Text : String; Terms : Text_Lists.Vector) return Maybe_Line
   is
      Result : Maybe_Line;

      function Visit (First, Last : Natural; Number : Positive) return Boolean
      is
         pragma Unreferenced (Number);
      begin
         if Last >= First and then Contains_Any (Text (First .. Last), Terms)
         then
            Result := (Found => True, First => First, Last => Last);
            return False;
         end if;
         return True;
      end Visit;

      procedure Scan is new For_Each_Line (Visit);
   begin
      Scan (Text);
      return Result;
   end First_Matching_Line_Any;

   function Count_Ignore_Case (Haystack, Needle : String) return Natural
   is (Unicode.Count_Case_Fold (Haystack, Needle));

   function Match_Ranges
     (Text       : String;
      First_Line : Positive;
      Terms      : Text_Lists.Vector) return Range_Vectors.Vector
   is
      Result : Range_Vectors.Vector;

      function Visit (First, Last : Natural; Number : Positive) return Boolean
      is
         Line : constant Positive := First_Line + Number - 1;
      begin
         if Last >= First and then Contains_Any (Text (First .. Last), Terms)
         then
            if not Result.Is_Empty
              and then Result.Last_Element.Last + 1 = Line
            then
               Result.Reference (Result.Last_Index).Last := Line;
            else
               Result.Append (Line_Range'(First => Line, Last => Line));
            end if;
         end if;
         return True;
      end Visit;

      procedure Scan is new For_Each_Line (Visit);
   begin
      Scan (Text);
      return Result;
   end Match_Ranges;

   function Image (Ranges : Range_Vectors.Vector) return String is
      Result : Unbounded_String;

      function Number (N : Positive) return String is
         Text : constant String := Positive'Image (N);
      begin
         return Text (Text'First + 1 .. Text'Last);
      end Number;
   begin
      for I in 1 .. Natural (Ranges.Length) loop
         if I > 1 then
            Append (Result, ",");
         end if;
         Append (Result, Number (Ranges (I).First));
         if Ranges (I).Last /= Ranges (I).First then
            Append (Result, "-" & Number (Ranges (I).Last));
         end if;
      end loop;
      return To_String (Result);
   end Image;

end Synapse.Core.Text_Search;
