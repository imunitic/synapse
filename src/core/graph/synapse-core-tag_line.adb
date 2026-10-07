with Ada.Strings.Unbounded;
with Ada.Strings.Fixed;
with Ada.Strings.Maps;

package body Synapse.Core.Tag_Line is

   use Ada.Strings.Unbounded;

   HT : constant Character := Character'Val (9);

   Pad_Left  : constant Ada.Strings.Maps.Character_Set :=
     Ada.Strings.Maps.To_Set (" " & HT & "|");
   Pad_Right : constant Ada.Strings.Maps.Character_Set :=
     Ada.Strings.Maps.To_Set (" " & HT);

   --  Leading blanks and pipes, trailing blanks.
   function Trimmed (S : String) return String is
     (Ada.Strings.Fixed.Trim (S, Pad_Left, Pad_Right));

   --  The first place C occurs in S, or 0.
   function Find (S : String; C : Character) return Natural is
   begin
      for I in S'Range loop
         if S (I) = C then
            return I;
         end if;
      end loop;
      return 0;
   end Find;

   --  The row number as digits, or -1 for anything else, an overflow
   --  included.
   function Row_Number (S : String) return Integer is
      Text  : constant String :=
        Ada.Strings.Fixed.Trim (S, Pad_Right, Pad_Right);
      Value : Natural         := 0;
   begin
      if Text'Length = 0 then
         return -1;
      end if;
      for C of Text loop
         if C not in '0' .. '9' then
            return -1;
         end if;
         declare
            Digit : constant Natural :=
              Character'Pos (C) - Character'Pos ('0');
         begin
            if Value > (Natural'Last - Digit) / 10 then
               return -1;
            end if;
            Value := Value * 10 + Digit;
         end;
      end loop;
      return Value;
   end Row_Number;

   --  Between the first backtick and the last.
   function Expression (Rest : String) return String is
      First : constant Natural := Find (Rest, '`');
   begin
      if First = 0 then
         return "";
      end if;
      declare
         Tail : constant String := Rest (First + 1 .. Rest'Last);
      begin
         for I in reverse Tail'Range loop
            if Tail (I) = '`' then
               return Tail (Tail'First .. I - 1);
            end if;
         end loop;
         return Tail;
      end;
   end Expression;

   function Parse (Line : String) return Maybe_Tag is
      Tab_1 : constant Natural := Find (Line, HT);
   begin
      if Tab_1 = 0 then
         return (Found => False);
      end if;
      declare
         After_1 : constant String  := Line (Tab_1 + 1 .. Line'Last);
         Tab_2   : constant Natural := Find (After_1, HT);
      begin
         if Tab_2 = 0 then
            return (Found => False);
         end if;
         declare
            After_2   : constant String := After_1 (Tab_2 + 1 .. After_1'Last);
            Tab_3     : constant Natural                := Find (After_2, HT);
            Raw_Name  : constant String := Line (Line'First .. Tab_1 - 1);
            Raw_Kind : constant String := After_1 (After_1'First .. Tab_2 - 1);
            Rest      : constant String                 :=
              (if Tab_3 = 0 then After_2
               else After_2 (After_2'First .. Tab_3 - 1));
            Space     : constant Natural                := Find (Rest, ' ');
            Role_Text : constant String                 :=
              (if Space = 0 then Rest else Rest (Rest'First .. Space - 1));
            Which     : constant Graph_Model.Maybe_Role :=
              Graph_Model.Parse (Role_Text);
         begin
            if not Which.Found then
               return (Found => False);
            end if;
            declare
               Open : constant Natural := Find (Rest, '(');
            begin
               if Open = 0 then
                  return (Found => False);
               end if;
               declare
                  After_Open : constant String := Rest (Open + 1 .. Rest'Last);
                  Comma      : constant Natural := Find (After_Open, ',');
               begin
                  if Comma = 0 then
                     return (Found => False);
                  end if;
                  declare
                     Row  : constant Integer :=
                       Row_Number (After_Open (After_Open'First .. Comma - 1));
                     Name : constant String  := Trimmed (Raw_Name);
                  begin
                     if Row < 0 or else Name'Length = 0 then
                        return (Found => False);
                     end if;
                     return
                       (Found => True,
                        Value =>
                          (Name       => To_Unbounded_String (Name),
                           Kind => To_Unbounded_String (Trimmed (Raw_Kind)),
                           Which      => Which.Value, Line => Row,
                           Expression =>
                             To_Unbounded_String (Expression (Rest))));
                  end;
               end;
            end;
         end;
      end;
   end Parse;

   function Refs_Row (Path : String; Of_Tag : Graph_Model.Tag) return String is
      Line_Text : constant String := Natural'Image (Of_Tag.Line);
   begin
      return
        To_String (Of_Tag.Name) & HT & Graph_Model.Image (Of_Tag.Which) & HT &
        To_String (Of_Tag.Kind) & HT & Path & ":" &
        Line_Text (Line_Text'First + 1 .. Line_Text'Last) & HT &
        To_String (Of_Tag.Expression) & Character'Val (10);
   end Refs_Row;

end Synapse.Core.Tag_Line;
