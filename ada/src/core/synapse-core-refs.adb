with Ada.Containers.Indefinite_Ordered_Sets;

package body Synapse.Core.Refs is

   use Ports.Byte_Source;

   LF : constant Character := Character'Val (10);
   HT : constant Character := Character'Val (9);

   function Parse_Row (Line : String) return Maybe_Row is
      Starts   : array (1 .. 4) of Natural := [others => 0];
      Stops    : array (1 .. 4) of Natural := [others => 0];
      Field    : Natural                   := 1;
      Begin_Of : Natural                   := Line'First;
   begin
      for I in Line'First .. Line'Last + 1 loop
         if I > Line'Last or else Line (I) = HT then
            Starts (Field) := Begin_Of;
            Stops (Field)  := I - 1;
            exit when Field = 4 or else I > Line'Last;
            Field    := Field + 1;
            Begin_Of := I + 1;
         end if;
      end loop;
      if Field < 4 or else Starts (4) = 0 then
         return (Found => False);
      end if;
      declare
         Expr_First : constant Integer := Stops (4) + 2;
      begin
         return
           (Found => True,
            Value =>
              (Name => To_Unbounded_String (Line (Starts (1) .. Stops (1))),
               Dir  => To_Unbounded_String (Line (Starts (2) .. Stops (2))),
               Kind => To_Unbounded_String (Line (Starts (3) .. Stops (3))),
               Site => To_Unbounded_String (Line (Starts (4) .. Stops (4))),
               Expr =>
                 To_Unbounded_String
                   (if Expr_First > Line'Last then ""
                    else Line (Expr_First .. Line'Last))));
      end;
   end Parse_Row;

   --  The bytes From .. To_Exclusive - 1, however many blocks that takes.
   function Bytes
     (Index : in out Source'Class; From, To_Exclusive : Offset;
      Block :        Positive) return String
   is
      Result : Unbounded_String;
      Here   : Offset := From;
   begin
      while Here < To_Exclusive loop
         declare
            Want  : constant Positive :=
              Positive'Min (Block, Positive (To_Exclusive - Here));
            Chunk : constant String   := Index.Read (Here, Want);
         begin
            exit when Chunk'Length = 0;
            Append (Result, Chunk);
            Here := Here + Offset (Chunk'Length);
         end;
      end loop;
      return To_String (Result);
   end Bytes;

   --  The first position at or after From and before Size that holds C, or
   --  Size.
   function Find_Byte
     (Index : in out Source'Class; Size, From : Offset; C : Character;
      Block :        Positive) return Offset
   is
      Here : Offset := From;
   begin
      while Here < Size loop
         declare
            Chunk : constant String := Index.Read (Here, Block);
         begin
            exit when Chunk'Length = 0;
            for I in Chunk'Range loop
               exit when Here + Offset (I - Chunk'First) >= Size;
               if Chunk (I) = C then
                  return Here + Offset (I - Chunk'First);
               end if;
            end loop;
            Here := Here + Offset (Chunk'Length);
         end;
      end loop;
      return Size;
   end Find_Byte;

   --  Where the line holding position At begins: after the last line feed
   --  before At.
   function Line_Start
     (Index : in out Source'Class; At_Position : Offset; Block : Positive)
      return Offset
   is
      Stop : Offset := At_Position;
   begin
      while Stop > 0 loop
         declare
            From  : constant Offset := Offset'Max (0, Stop - Offset (Block));
            Chunk : constant String :=
              Index.Read (From, Positive (Stop - From));
         begin
            exit when Chunk'Length = 0;
            for I in reverse Chunk'Range loop
               if Chunk (I) = LF then
                  return From + Offset (I - Chunk'First + 1);
               end if;
            end loop;
            Stop := From;
         end;
      end loop;
      return 0;
   end Line_Start;

   --  The offset of the first line whose name is at or after Name, by
   --  bisection on byte offsets and then back to a line boundary.
   function First_At_Or_After
     (Index : in out Source'Class; Size : Offset; Name : String;
      Block :        Positive) return Offset
   is
      Low  : Offset := 0;
      High : Offset := Size;
   begin
      while Low < High loop
         declare
            Mid   : constant Offset := Low + (High - Low) / 2;
            Start : constant Offset := Line_Start (Index, Mid, Block);
            Stop  : constant Offset :=
              Find_Byte (Index, Size, Start, LF, Block);
            Tab : constant Offset := Find_Byte (Index, Stop, Start, HT, Block);
            Field : constant String := Bytes (Index, Start, Tab, Block);
         begin
            if Field < Name then
               Low := (if Stop = Size then Size else Stop + 1);
            else
               High := Start;
            end if;
         end;
      end loop;
      return Low;
   end First_At_Or_After;

   function Find
     (Index : in out Source'Class; Name : String;
      Block :        Positive := Default_Block) return Row_Vectors.Vector
   is
      Size   : constant Offset := Index.Size;
      Here   : Offset          := First_At_Or_After (Index, Size, Name, Block);
      Want   : Positive        := Block;
      Result : Row_Vectors.Vector;

      --  False once a row of another name ends the run.
      function Take (Line : String) return Boolean is
         Parsed : constant Maybe_Row := Parse_Row (Line);
      begin
         if not Parsed.Found then
            return True;
         end if;
         if To_String (Parsed.Value.Name) /= Name then
            return False;
         end if;
         Result.Append (Parsed.Value);
         return True;
      end Take;
   begin
      while Here < Size loop
         declare
            Chunk  : constant String  := Index.Read (Here, Want);
            Cursor : Positive         := Chunk'First;
            At_End : constant Boolean := Here + Offset (Chunk'Length) >= Size;
         begin
            exit when Chunk'Length = 0;
            loop
               declare
                  Stop : Natural := 0;
               begin
                  for I in Cursor .. Chunk'Last loop
                     if Chunk (I) = LF then
                        Stop := I;
                        exit;
                     end if;
                  end loop;
                  if Stop > 0 then
                     if not Take (Chunk (Cursor .. Stop - 1)) then
                        return Result;
                     end if;
                     Cursor := Stop + 1;
                  elsif At_End and then Cursor <= Chunk'Last then
                     --  The last line, with no line feed after it.
                     if not Take (Chunk (Cursor .. Chunk'Last)) then
                        return Result;
                     end if;
                     Cursor := Chunk'Last + 1;
                  end if;
                  exit when Stop = 0;
               end;
            end loop;
            --  A line longer than the block needs a longer read.
            Want :=
              (if Cursor = Chunk'First and then not At_End then Want * 2
               else Block);
            Here := Here + Offset (Cursor - Chunk'First);
         end;
      end loop;
      return Result;
   end Find;

   package String_Sets is new Ada.Containers.Indefinite_Ordered_Sets (String);

   function Sort_Unique (Unsorted : String) return Sorted_Index is
      Lines  : String_Sets.Set;
      Paths  : String_Sets.Set;
      Result : Sorted_Index;
      Start  : Positive := Unsorted'First;
   begin
      for I in Unsorted'First .. Unsorted'Last + 1 loop
         if I > Unsorted'Last or else Unsorted (I) = LF then
            if I > Start then
               Lines.Include (Unsorted (Start .. I - 1));
            end if;
            Start := I + 1;
         end if;
      end loop;

      for Line of Lines loop
         Append (Result.Text, Line & LF);
         Result.Tally.Tags := Result.Tally.Tags + 1;
         declare
            Parsed : constant Maybe_Row := Parse_Row (Line);
         begin
            if Parsed.Found then
               declare
                  Dir        : constant String := To_String (Parsed.Value.Dir);
                  Site : constant String := To_String (Parsed.Value.Site);
                  Last_Colon : Natural         := 0;
               begin
                  if Dir = "def" then
                     Result.Tally.Defs := Result.Tally.Defs + 1;
                  elsif Dir = "ref" then
                     Result.Tally.Refs := Result.Tally.Refs + 1;
                  end if;
                  for I in reverse Site'Range loop
                     if Site (I) = ':' then
                        Last_Colon := I;
                        exit;
                     end if;
                  end loop;
                  Paths.Include
                    (if Last_Colon = 0 then Site
                     else Site (Site'First .. Last_Colon - 1));
               end;
            end if;
         end;
      end loop;
      Result.Tally.Files := Natural (Paths.Length);
      return Result;
   end Sort_Unique;

end Synapse.Core.Refs;
