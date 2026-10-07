with Synapse.Core.Line_Slice;

package body Synapse.Core.Symbol is

   use Ada.Strings.Unbounded;

   function Outcome_For
     (Cached : Boolean; Unsupported : Boolean; Tags : String) return Outcome
   is
   begin
      if not Cached then
         return (Kind => Not_Cached);
      elsif Unsupported then
         return (Kind => Symbol.Unsupported);
      end if;
      return (Kind => Checked, Tags => To_Unbounded_String (Tags));
   end Outcome_For;

   function Matches
     (Payload : String; Name : String) return Tag_Payload.Tag_Vectors.Vector
   is
      Result   : Tag_Payload.Tag_Vectors.Vector;
      Position : Integer := Payload'First;
      Item     : Tag_Payload.Maybe_Tag;
   begin
      loop
         Tag_Payload.Next (Payload, Position, Item);
         exit when not Item.Found;
         if To_String (Item.Value.Name) = Name then
            Result.Append (Item.Value);
         end if;
      end loop;
      return Result;
   end Matches;

   function Requested_Paths (Text : String) return Text_Lists.Vector is
      Result : Text_Lists.Vector;
      Start  : Integer := Text'First;
   begin
      loop
         declare
            Stop : constant Natural := Line_Slice.Next_Line_Feed (Text, Start);
            Last : Integer := (if Stop = 0 then Text'Last else Stop - 1);
         begin
            if Last >= Start and then Text (Last) = Character'Val (13) then
               Last := Last - 1;
            end if;
            if Last >= Start then
               Result.Append (To_Unbounded_String (Text (Start .. Last)));
            end if;
            exit when Stop = 0;
            Start := Stop + 1;
         end;
      end loop;
      return Result;
   end Requested_Paths;

end Synapse.Core.Symbol;
