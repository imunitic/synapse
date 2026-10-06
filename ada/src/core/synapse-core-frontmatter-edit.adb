package body Synapse.Core.Frontmatter.Edit with SPARK_Mode => Off is

   use Ada.Strings.Unbounded;

   HT : constant Character := Character'Val (9);
   LF : constant Character := Character'Val (10);
   CR : constant Character := Character'Val (13);

   function Value_Span (Note, Key : String) return Maybe_Span is
      Line : constant Maybe_Span := Find_Key_Line (Note, Key);
   begin
      if not Line.Found then
         return (Found => False);
      end if;
      declare
         First : Natural := Line.Item.First + Key'Length + 1;
      begin
         while First < Line.Item.Stop
           and then Note (Note'First + First) in ' ' | HT
         loop
            First := First + 1;
         end loop;
         return
           (Found => True, Item => (First => First, Stop => Line.Item.Stop));
      end;
   end Value_Span;

   function Scalar (Note, Key : String) return Maybe_Text is
      Raw : constant Maybe_Span := Value_Span (Note, Key);
   begin
      if not Raw.Found then
         return (Found => False);
      end if;

      declare
         Text : constant String :=
            Note
              (Note'First + Raw.Item.First .. Note'First + Raw.Item.Stop - 1);
      begin
         --  Unquoted scalars carry no escapes.
         if Text'Length < 2
           or else Text (Text'First) /= '"'
           or else Text (Text'Last) /= '"'
         then
            return (Found => True, Item => To_Unbounded_String (Text));
         end if;

         declare
            Inner  : constant String := Text (Text'First + 1 .. Text'Last - 1);
            Result : Unbounded_String;
            I      : Natural := Inner'First;
         begin
            while I <= Inner'Last loop
               if Inner (I) = '\' and then I < Inner'Last then
                  case Inner (I + 1) is
                     when '\' =>
                        Append (Result, '\');
                        I := I + 2;

                     when '"' =>
                        Append (Result, '"');
                        I := I + 2;

                     when 'n' =>
                        Append (Result, LF);
                        I := I + 2;

                     when 'r' =>
                        Append (Result, CR);
                        I := I + 2;

                     when others =>
                        Append (Result, '\');
                        I := I + 1;
                  end case;
               else
                  Append (Result, Inner (I));
                  I := I + 1;
               end if;
            end loop;
            return (Found => True, Item => Result);
         end;
      end;
   end Scalar;

   function Set_Scalar (Note, Key, Value : String) return String is
   begin
      if not Has_Frontmatter (Note) then
         raise No_Frontmatter;
      end if;
      return Set_Rendered (Note, Key, Render_Scalar (Value));
   end Set_Scalar;

   function Total_Length (Items : String_Array) return Natural is
      Total : Natural := 0;
   begin
      for Item of Items loop
         Total := Total + Length (Item);
      end loop;
      return Total;
   end Total_Length;

   function Set_List (Note, Key : String; Items : String_Array) return String
   is
      Rendered : Unbounded_String := To_Unbounded_String ("[");
   begin
      if not Has_Frontmatter (Note) then
         raise No_Frontmatter;
      end if;
      for I in Items'Range loop
         if I /= Items'First then
            Append (Rendered, ", ");
         end if;
         Append (Rendered, Render_Scalar (To_String (Items (I))));
      end loop;
      Append (Rendered, ']');
      return Set_Rendered (Note, Key, To_String (Rendered));
   end Set_List;

   function Strip_Quotes (Item : String) return String
   is (if Item'Length >= 2
         and then Item (Item'First) = '"'
         and then Item (Item'Last) = '"'
       then Item (Item'First + 1 .. Item'Last - 1)
       else Item);

   function Trim_Blanks (S : String) return String is
      First : Natural := S'First;
      Last  : Integer := S'Last;
   begin
      while First <= Last and then S (First) in ' ' | HT loop
         First := First + 1;
      end loop;
      while Last >= First and then S (Last) in ' ' | HT loop
         Last := Last - 1;
      end loop;
      return S (First .. Last);
   end Trim_Blanks;

   function Parse_Tags (Note : String) return String_Array is
      Raw : constant Maybe_Span := Find_Field (Note, "tags");
   begin
      if not Raw.Found then
         return [];
      end if;

      declare
         Text : constant String :=
           Trim_Blanks
             (Note (Note'First + Raw.Item.First
                    .. Note'First + Raw.Item.Stop - 1));
      begin
         if Text'Length < 2
           or else Text (Text'First) /= '['
           or else Text (Text'Last) /= ']'
         then
            return [];
         end if;

         declare
            Inner  : constant String :=
              Trim_Blanks (Text (Text'First + 1 .. Text'Last - 1));
            Result : array (1 .. Inner'Length + 1) of Unbounded_String;
            Count  : Natural := 0;
            Start  : Natural := Inner'First;
         begin
            if Inner'Length = 0 then
               return [];
            end if;
            for I in Inner'First .. Inner'Last + 1 loop
               if I > Inner'Last or else Inner (I) = ',' then
                  Count := Count + 1;
                  Result (Count) :=
                    To_Unbounded_String
                      (Strip_Quotes (Trim_Blanks (Inner (Start .. I - 1))));
                  Start := I + 1;
               end if;
            end loop;
            return [for I in 1 .. Count => Result (I)];
         end;
      end;
   end Parse_Tags;

   function Add_Tag (Note, Tag : String) return String is
      Current : constant String_Array := Parse_Tags (Note);
   begin
      for Item of Current loop
         if To_String (Item) = Tag then
            return Note;
         end if;
      end loop;
      return
        Set_List
          (Note,
           "tags",
           Current & String_Array'[1 => To_Unbounded_String (Tag)]);
   end Add_Tag;

   function Remove_Tag (Note, Tag : String) return String is
      Current   : constant String_Array := Parse_Tags (Note);
      Remaining : String_Array (1 .. Current'Length);
      Count     : Natural := 0;
   begin
      for Item of Current loop
         if To_String (Item) /= Tag then
            Count := Count + 1;
            Remaining (Count) := Item;
         end if;
      end loop;
      if Count = Current'Length then
         return Note;
      end if;
      return Set_List (Note, "tags", Remaining (1 .. Count));
   end Remove_Tag;

end Synapse.Core.Frontmatter.Edit;
