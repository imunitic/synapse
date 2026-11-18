with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

package body Synapse.Pipeline.Patches is

   use Ada.Strings.Unbounded;

   LF         : constant Character := Character'Val (10);
   File_Start : constant String := "diff --git ";

   function Starts_With (Text, Prefix : String) return Boolean is
     (Text'Length >= Prefix'Length
      and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

   --  The index just after the line that begins at From.
   function After_Line (Text : String; From : Positive) return Positive is
   begin
      for I in From .. Text'Last loop
         if Text (I) = LF then
            return I + 1;
         end if;
      end loop;
      return Text'Last + 1;
   end After_Line;

   --  Where the section that begins at From ends: where the diff of the next
   --  file begins, or just after the patch.
   function Section_End (Patch : String; From : Positive) return Positive is
      Line : Positive := After_Line (Patch, From);
   begin
      while Line <= Patch'Last loop
         if Starts_With (Patch (Line .. Patch'Last), File_Start) then
            return Line;
         end if;
         Line := After_Line (Patch, Line);
      end loop;
      return Patch'Last + 1;
   end Section_End;

   --  The diff of one file, as it is kept.
   function Kept (Section : String; Largest : Natural) return String is
      Line    : Positive := Section'First;
      Is_New  : Boolean := False;
      Hunk_At : Natural := 0;
   begin
      if Section'Length <= Largest then
         return Section;
      end if;
      while Line <= Section'Last loop
         if Starts_With (Section (Line .. Section'Last), "@@") then
            Hunk_At := Line;
            exit;
         elsif Starts_With (Section (Line .. Section'Last), "new file mode")
         then
            Is_New := True;
         end if;
         Line := After_Line (Section, Line);
      end loop;
      --  A file with no hunk, a binary one, has no lines to leave out.
      if not Is_New or else Hunk_At = 0 then
         return Section;
      end if;
      declare
         Count : Natural := 0;
      begin
         Line := Hunk_At;
         while Line <= Section'Last loop
            if Section (Line) = '+' then
               Count := Count + 1;
            end if;
            Line := After_Line (Section, Line);
         end loop;
         return Section (Section'First .. Hunk_At - 1) & "@@ -0,0 +1,"
           & Ada.Strings.Fixed.Trim (Natural'Image (Count), Ada.Strings.Left)
           & " @@" & LF & "\ " & Not_Kept & LF;
      end;
   end Kept;

   function Capped (Patch : String; Largest : Natural) return String is
      Result : Unbounded_String;
      Start  : Natural := Patch'First;
   begin
      while Start <= Patch'Last loop
         declare
            Stop : constant Positive := Section_End (Patch, Start);
         begin
            Append (Result, Kept (Patch (Start .. Stop - 1), Largest));
            Start := Stop;
         end;
      end loop;
      return To_String (Result);
   end Capped;

end Synapse.Pipeline.Patches;
