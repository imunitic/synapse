with Synapse.Core.Decimal_Image;
with Synapse.Core.JSON;

package body Synapse.Core.Doctor is

   LF : constant Character := Character'Val (10);

   function Label (S : Status) return String is
     (case S is when Ok => "ok", when Warn => "warn", when Fail => "FAIL");

   function Exit_Code (Checks : Check_Vectors.Vector) return Natural is
   begin
      for C of Checks loop
         if C.State = Fail then
            return 1;
         end if;
      end loop;
      return 0;
   end Exit_Code;

   function Count (Checks : Check_Vectors.Vector) return Counts is
      Result : Counts;
   begin
      for C of Checks loop
         case C.State is
            when Ok =>
               Result.Ok := Result.Ok + 1;

            when Warn =>
               Result.Warn := Result.Warn + 1;

            when Fail =>
               Result.Fail := Result.Fail + 1;
         end case;
      end loop;
      return Result;
   end Count;

   function Key_Of (Name : String) return String is
      Result : String := Name;
   begin
      for C of Result loop
         if C in 'A' .. 'Z' then
            C := Character'Val (Character'Pos (C) + 32);
         elsif C = ' ' then
            C := '-';
         end if;
      end loop;
      return Result;
   end Key_Of;

   function Json (Checks : Check_Vectors.Vector) return String is
      package J renames Synapse.Core.JSON;

      function Member (Key : String; Item : J.Value) return J.Member is
        (Key => To_Unbounded_String (Key), Item => Item);

      function Whole (Item : Natural) return J.Value is
        (J.Make_Integer (Long_Long_Integer (Item)));

      function Words (Item : Status) return String is
        (case Item is when Ok => "ok", when Warn => "warn", when Fail => "fail");

      Items : J.Value_Array (1 .. Natural (Checks.Length));
      N     : constant Counts := Count (Checks);
   begin
      for I in Items'Range loop
         declare
            C : constant Check := Checks (I);
         begin
            Items (I) :=
              J.Make_Object
                ([Member ("key", J.Make_String (Key_Of (To_String (C.Name)))),
                  Member ("name", J.Make_String (To_String (C.Name))),
                  Member ("status", J.Make_String (Words (C.State))),
                  Member ("detail", J.Make_String (To_String (C.Detail))),
                  Member ("value", J.Make_String (To_String (C.Value)))]);
         end;
      end loop;
      return J.To_String
        (J.Make_Object
           ([Member ("format", J.Make_String ("synapse-doctor/v1")),
             Member ("checks", J.Make_Array (Items)),
             Member
               ("counts",
                J.Make_Object
                  ([Member ("ok", Whole (N.Ok)),
                    Member ("warn", Whole (N.Warn)),
                    Member ("fail", Whole (N.Fail))]))]));
   end Json;

   function Report (Checks : Check_Vectors.Vector) return String is
      Text  : Unbounded_String;
      Width : Natural := 0;
   begin
      for C of Checks loop
         Width := Natural'Max (Width, Length (C.Name));
      end loop;
      for C of Checks loop
         declare
            Mark : constant String := Label (C.State);
         begin
            Append (Text, Mark & [1 .. 4 - Mark'Length => ' '] & "  ");
            Append (Text, C.Name);
            if Length (C.Detail) > 0 then
               Append (Text, [1 .. Width - Length (C.Name) => ' ']);
               Append (Text, "  ");
               Append (Text, C.Detail);
            end if;
            Append (Text, LF);
         end;
      end loop;
      declare
         N : constant Counts := Count (Checks);
      begin
         Append
           (Text,
            LF & Decimal_Image.Image (N.Ok) & " ok," & Natural'Image (N.Warn) &
            " warning(s)," & Natural'Image (N.Fail) & " failure(s)" & LF);
      end;
      return To_String (Text);
   end Report;

end Synapse.Core.Doctor;
