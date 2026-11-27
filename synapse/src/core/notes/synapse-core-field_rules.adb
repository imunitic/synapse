with Ada.Strings.Unbounded;

with Synapse.Core.Decimal_Image;
with Synapse.Core.Note_Text;
with Synapse.Core.Regex_Lite;
with Synapse.Core.Schema_Pattern;

package body Synapse.Core.Field_Rules is

   use JSON;
   use type Schema_Pattern.Fault;
   use type Regex_Lite.Outcome;

   function Has (V : Value; Key : String) return Boolean is
     (Kind_Of (V) = JSON_Object and then Has_Member (V, Key));

   function Has_String (V : Value; Key : String) return Boolean is
     (Has (V, Key) and then Kind_Of (Member_Value (V, Key)) = JSON_String);

   function String_At (V : Value; Key : String) return String is
     (if Has_String (V, Key) then As_String (Member_Value (V, Key)) else "");

   function Int_At
     (V : Value; Key : String; Default : Long_Long_Integer)
      return Long_Long_Integer is
     (if Has (V, Key) and then Kind_Of (Member_Value (V, Key)) = JSON_Integer
      then As_Integer (Member_Value (V, Key))
      else Default);

   --  Whether Text is one of the strings of the list Items.
   function In_List (Text : String; Items : Value) return Boolean is
   begin
      if Kind_Of (Items) /= JSON_Array then
         return False;
      end if;
      for I in 1 .. Length (Items) loop
         declare
            Item : constant Value := Element (Items, I);
         begin
            if Kind_Of (Item) = JSON_String and then As_String (Item) = Text
            then
               return True;
            end if;
         end;
      end loop;
      return False;
   end In_List;

   --  The number of characters of UTF-8 text: bytes that start a sequence.
   function Characters (Text : String) return Natural is
      Count : Natural := 0;
   begin
      for C of Text loop
         if Character'Pos (C) / 64 /= 2 then  --  not 10xxxxxx
            Count := Count + 1;
         end if;
      end loop;
      return Count;
   end Characters;

   --  Whether Text matches Pattern. A pattern that is not valid or runs out
   --  of steps matches nothing.
   function Matches (Pattern, Text : String) return Boolean is
     (Schema_Pattern.Validate (Pattern) = Schema_Pattern.None
      and then Schema_Pattern.Search (Pattern, Text) = Regex_Lite.Matched);

   --  Whether V has the schema type Type_Name.
   function Has_Type (V : Value; Type_Name : String) return Boolean is
     (if Type_Name in "string" | "timestamp" then Kind_Of (V) = JSON_String
      elsif Type_Name = "list" then Kind_Of (V) = JSON_Array
      elsif Type_Name = "integer" then Kind_Of (V) = JSON_Integer
      elsif Type_Name = "boolean" then Kind_Of (V) = JSON_Boolean
      else Type_Name = "any");

   function Check_Value
     (Prefix : String; Rule : JSON.Value; Value : JSON.Value)
      return Synapse.Core.Optional_Text.Option
   is
      Type_Name : constant String := String_At (Rule, "type");

      function Bad (Problem : String) return Optional_Text.Option is
        (Optional_Text.Of_Value
           (Ada.Strings.Unbounded.To_Unbounded_String
              (Prefix & ": " & Problem)));
   begin
      if not Has_Type (Value, Type_Name) then
         return Bad ("expected " & Type_Name);
      end if;
      if Kind_Of (Value) /= JSON_String then
         return Optional_Text.None;
      end if;

      declare
         Text : constant String := As_String (Value);
      begin
         if Has_String (Rule, "const")
           and then Text /= String_At (Rule, "const")
         then
            return Bad ("expected '" & String_At (Rule, "const") & "'");
         end if;
         if Has (Rule, "min_length") then
            declare
               Bound : constant Long_Long_Integer :=
                 Int_At (Rule, "min_length", 0);
            begin
               if Long_Long_Integer (Characters (Text)) < Bound then
                  return
                    Bad
                      ("must be at least " & Decimal_Image.Image (Bound) &
                       " characters");
               end if;
            end;
         end if;
         if Has_String (Rule, "pattern")
           and then not Matches (String_At (Rule, "pattern"), Text)
         then
            return Bad ("does not match required pattern");
         end if;
         if Has (Rule, "enum")
           and then not In_List (Text, Member_Value (Rule, "enum"))
         then
            return Bad ("value '" & Text & "' is not allowed");
         end if;
         if Type_Name = "timestamp"
           and then not Note_Text.Valid_Timestamp (Text)
         then
            return
              Bad
                ("expected RFC3339, YYYY-MM-DDTHH:MM:SS then Z or a" &
                 " colon-separated numeric offset");
         end if;
      end;
      return Optional_Text.None;
   end Check_Value;

end Synapse.Core.Field_Rules;
