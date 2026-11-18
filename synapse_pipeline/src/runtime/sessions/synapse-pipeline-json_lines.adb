package body Synapse.Pipeline.Json_Lines is

   use type JSON.Kind;

   LF : constant Character := Character'Val (10);

   function Blank (Text : String) return Boolean is
   begin
      for C of Text loop
         if C not in ' ' | LF | Character'Val (13) | Character'Val (9) then
            return False;
         end if;
      end loop;
      return True;
   end Blank;

   procedure For_Each_Line
     (Text : String; Each : not null access procedure (Item : JSON.Value))
   is
      Start : Positive := Text'First;

      procedure One (Line : String) is
      begin
         if Blank (Line) then
            return;
         end if;
         declare
            Parsed : constant JSON.Parse_Result := JSON.Parse (Line);
         begin
            if Parsed.Ok and then JSON.Kind_Of (Parsed.Item) = JSON.JSON_Object
            then
               Each (Parsed.Item);
            end if;
         end;
      end One;
   begin
      for I in Text'Range loop
         if Text (I) = LF then
            One (Text (Start .. I - 1));
            Start := I + 1;
         end if;
      end loop;
      if Start <= Text'Last then
         One (Text (Start .. Text'Last));
      end if;
   end For_Each_Line;

   function Text_Member (Item : JSON.Value; Key : String) return String is
     (if JSON.Kind_Of (Item) = JSON.JSON_Object
        and then JSON.Has_Member (Item, Key)
        and then JSON.Kind_Of (JSON.Member_Value (Item, Key)) =
                 JSON.JSON_String
      then JSON.As_String (JSON.Member_Value (Item, Key)) else "");

   function Object_Member (Item : JSON.Value; Key : String) return JSON.Value
   is
     (if JSON.Kind_Of (Item) = JSON.JSON_Object
        and then JSON.Has_Member (Item, Key)
      then JSON.Member_Value (Item, Key) else JSON.Null_Value);

end Synapse.Pipeline.Json_Lines;
