with Ada.Containers.Vectors;

package body Synapse.Core.Schema_Rules is

   use Ada.Strings.Unbounded;
   use JSON;

   package Name_Vectors is new
     Ada.Containers.Vectors (Positive, Unbounded_String);

   ---------------------------------------------------------------------------
   --  Conversion
   ---------------------------------------------------------------------------

   function Renamed (Key : String) return String
   is (if Key = "eq" then "=="
       elsif Key = "ne" then "!="
       elsif Key = "lt" then "<"
       elsif Key = "lte" then "<="
       elsif Key = "gt" then ">"
       elsif Key = "gte" then ">="
       elsif Key = "not" then "!"
       else Key);

   function To_Rule (Value : JSON.Value) return Rule_Result is
   begin
      case Kind_Of (Value) is
         when JSON_Null =>
            return (Ok => False);

         when JSON_Array =>
            declare
               Items : JSON.Value_Array (1 .. Length (Value));
            begin
               for I in Items'Range loop
                  declare
                     Item : constant Rule_Result :=
                       To_Rule (Element (Value, I));
                  begin
                     if not Item.Ok then
                        return (Ok => False);
                     end if;
                     Items (I) := Item.Rule;
                  end;
               end loop;
               return (Ok => True, Rule => Make_Array (Items));
            end;

         when JSON_Object =>
            declare
               Members : JSON.Member_Array (1 .. Length (Value));
               Rename  : constant Boolean := Length (Value) = 1;
            begin
               for I in Members'Range loop
                  declare
                     Item : constant Rule_Result :=
                       To_Rule (Member_At (Value, I));
                     Key  : constant String := Member_Key (Value, I);
                  begin
                     if not Item.Ok then
                        return (Ok => False);
                     end if;
                     Members (I) :=
                       (Key  =>
                          To_Unbounded_String
                            (if Rename then Renamed (Key) else Key),
                        Item => Item.Rule);
                  end;
               end loop;
               return (Ok => True, Rule => Make_Object (Members));
            end;

         when others =>
            return (Ok => True, Rule => Value);
      end case;
   end To_Rule;

   ---------------------------------------------------------------------------
   --  Scans
   ---------------------------------------------------------------------------

   Vocabulary_Prefix : constant String := "vocabularies.";

   --  A one-key `{"var": <string>}` object's path.
   function Var_Path (Rule : JSON.Value; Found : out Boolean) return String is
   begin
      Found :=
        Kind_Of (Rule) = JSON_Object
        and then Length (Rule) = 1
        and then Member_Key (Rule, 1) = "var"
        and then Kind_Of (Member_At (Rule, 1)) = JSON_String;
      return (if Found then As_String (Member_At (Rule, 1)) else "");
   end Var_Path;

   procedure Collect_Stems
     (Rule : JSON.Value; Into : in out Name_Vectors.Vector)
   is
      Is_Var : Boolean;
      Path   : constant String := Var_Path (Rule, Is_Var);
   begin
      if Is_Var then
         if Path'Length >= Vocabulary_Prefix'Length
           and then
             Path (Path'First .. Path'First + Vocabulary_Prefix'Length - 1)
                    = Vocabulary_Prefix
         then
            declare
               Stem : constant String :=
                 Path (Path'First + Vocabulary_Prefix'Length .. Path'Last);
            begin
               for Seen of Into loop
                  if To_String (Seen) = Stem then
                     return;
                  end if;
               end loop;
               Into.Append (To_Unbounded_String (Stem));
            end;
         end if;
         return;
      end if;

      case Kind_Of (Rule) is
         when JSON_Object =>
            for I in 1 .. Length (Rule) loop
               Collect_Stems (Member_At (Rule, I), Into);
            end loop;

         when JSON_Array =>
            for I in 1 .. Length (Rule) loop
               Collect_Stems (Element (Rule, I), Into);
            end loop;

         when others =>
            null;
      end case;
   end Collect_Stems;

   function To_Array (Names : Name_Vectors.Vector) return String_Array is
      Result : String_Array (1 .. Natural (Names.Length));
   begin
      for I in Result'Range loop
         Result (I) := Names (I);
      end loop;
      return Result;
   end To_Array;

   function Vocabulary_Stems (Rule : JSON.Value) return String_Array is
      Names : Name_Vectors.Vector;
   begin
      Collect_Stems (Rule, Names);
      return To_Array (Names);
   end Vocabulary_Stems;

   function References_Var (Rule : JSON.Value; Path : String) return Boolean is
      Is_Var : Boolean;
      Found  : constant String := Var_Path (Rule, Is_Var);
   begin
      if Is_Var then
         return Found = Path;
      end if;
      case Kind_Of (Rule) is
         when JSON_Object =>
            for I in 1 .. Length (Rule) loop
               if References_Var (Member_At (Rule, I), Path) then
                  return True;
               end if;
            end loop;
            return False;

         when JSON_Array =>
            for I in 1 .. Length (Rule) loop
               if References_Var (Element (Rule, I), Path) then
                  return True;
               end if;
            end loop;
            return False;

         when others =>
            return False;
      end case;
   end References_Var;

   ---------------------------------------------------------------------------
   --  Entries
   ---------------------------------------------------------------------------

   function Shape_Of (Entry_Value : JSON.Value) return Entry_Shape is
      Found           : Boolean := False;
      Key             : Unbounded_String;
      Rule            : JSON.Value;
      Message_Present : Boolean := False;
      Message_Invalid : Boolean := False;
   begin
      if Kind_Of (Entry_Value) /= JSON_Object then
         return (Is_Rule => False);
      end if;

      for I in 1 .. Length (Entry_Value) loop
         declare
            Name : constant String := Member_Key (Entry_Value, I);
            Item : constant JSON.Value := Member_At (Entry_Value, I);
         begin
            if Name = "message" then
               if Kind_Of (Item) = JSON_String then
                  Message_Present := True;
               else
                  Message_Invalid := True;
               end if;
            elsif Name /= "severity" then
               if Found then
                  return (Is_Rule => False);  --  two rule-shaped keys
               end if;
               Found := True;
               Key := To_Unbounded_String (Name);
               Rule := Item;
            end if;
         end;
      end loop;

      if not Found then
         return (Is_Rule => False);
      end if;
      return
        (Is_Rule         => True,
         Key             => Key,
         Rule            => Rule,
         Message_Present => Message_Present,
         Message_Invalid => Message_Invalid);
   end Shape_Of;

   function Rule_Object (Shape : Entry_Shape) return JSON.Value
   is (Make_Object ([(Shape.Key, Shape.Rule)]));

   procedure Collect_From_List
     (List : JSON.Value; Into : in out Name_Vectors.Vector) is
   begin
      if Kind_Of (List) /= JSON_Array then
         return;
      end if;
      for I in 1 .. Length (List) loop
         declare
            Shape : constant Entry_Shape := Shape_Of (Element (List, I));
         begin
            if Shape.Is_Rule then
               declare
                  Converted : constant Rule_Result :=
                    To_Rule (Rule_Object (Shape));
               begin
                  if Converted.Ok then
                     Collect_Stems (Converted.Rule, Into);
                  end if;
               end;
            end if;
         end;
      end loop;
   end Collect_From_List;

   function Needed_Vocabulary_Stems (Schema : JSON.Value) return String_Array
   is
      Names : Name_Vectors.Vector;
   begin
      if Kind_Of (Schema) = JSON_Object then
         for Key of String_Array'[To_Unbounded_String ("checks"),
                                  To_Unbounded_String ("lints")]
         loop
            if Has_Member (Schema, To_String (Key)) then
                Collect_From_List
                  (Member_Value (Schema, To_String (Key)), Names);
            end if;
         end loop;
      end if;
      return To_Array (Names);
   end Needed_Vocabulary_Stems;

   function Needs_Identity_Scan (Schema : JSON.Value) return Boolean is
   begin
      if Kind_Of (Schema) /= JSON_Object
        or else not Has_Member (Schema, "checks")
      then
         return False;
      end if;
      declare
         Checks : constant JSON.Value := Member_Value (Schema, "checks");
      begin
         if Kind_Of (Checks) /= JSON_Array then
            return False;
         end if;
         for I in 1 .. Length (Checks) loop
            declare
               Shape : constant Entry_Shape := Shape_Of (Element (Checks, I));
            begin
               if Shape.Is_Rule then
                  declare
                     Converted : constant Rule_Result :=
                       To_Rule (Rule_Object (Shape));
                  begin
                     if Converted.Ok
                       and then References_Var (Converted.Rule, "id_is_unique")
                     then
                        return True;
                     end if;
                  end;
               end if;
            end;
         end loop;
         return False;
      end;
   end Needs_Identity_Scan;

end Synapse.Core.Schema_Rules;
