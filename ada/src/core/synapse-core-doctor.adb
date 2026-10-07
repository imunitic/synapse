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

   function Number (N : Natural) return String is
      Text : constant String := Natural'Image (N);
   begin
      return Text (Text'First + 1 .. Text'Last);
   end Number;

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
            LF & Number (N.Ok) & " ok," & Natural'Image (N.Warn) &
            " warning(s)," & Natural'Image (N.Fail) & " failure(s)" & LF);
      end;
      return To_String (Text);
   end Report;

end Synapse.Core.Doctor;
