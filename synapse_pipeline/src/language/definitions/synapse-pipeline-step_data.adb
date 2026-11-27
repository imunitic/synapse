with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Synapse.Core.Object_Schema;
with Synapse.Pipeline.Outcomes;

package body Synapse.Pipeline.Step_Data is

   use Ada.Strings.Unbounded;
   use type JSON.Kind;
   use type JSON.Member;

   package Member_Lists is new Ada.Containers.Vectors (Positive, JSON.Member);

   package Value_Lists is new Ada.Containers.Vectors
     (Positive, JSON.Value, JSON."=");

   function Is_Object (Item : JSON.Value) return Boolean is
     (JSON.Kind_Of (Item) = JSON.JSON_Object);

   --  The member of Item called Key, or null when it has none.
   function Child (Item : JSON.Value; Key : String) return JSON.Value is
     (if Is_Object (Item) and then JSON.Has_Member (Item, Key)
      then JSON.Member_Value (Item, Key) else JSON.Null_Value);

   function Member (Key : String; Item : JSON.Value) return JSON.Member is
     (Key => To_Unbounded_String (Key), Item => Item);

   function To_Object (List : Member_Lists.Vector) return JSON.Value is
      Members : JSON.Member_Array (1 .. Natural (List.Length));
   begin
      for I in Members'Range loop
         Members (I) := List (I);
      end loop;
      return JSON.Make_Object (Members);
   end To_Object;

   function To_Array (List : Value_Lists.Vector) return JSON.Value is
      Items : JSON.Value_Array (1 .. Natural (List.Length));
   begin
      for I in Items'Range loop
         Items (I) := List (I);
      end loop;
      return JSON.Make_Array (Items);
   end To_Array;

   --  The members of Item in order, nothing when it is not an object.
   procedure Append_Members
     (List : in out Member_Lists.Vector; Item : JSON.Value) is
   begin
      if Is_Object (Item) then
         for I in 1 .. JSON.Length (Item) loop
            List.Append
              (Member (JSON.Member_Key (Item, I), JSON.Member_At (Item, I)));
         end loop;
      end if;
   end Append_Members;

   procedure Append_Elements
     (List : in out Value_Lists.Vector; Item : JSON.Value) is
   begin
      if JSON.Kind_Of (Item) = JSON.JSON_Array then
         for I in 1 .. JSON.Length (Item) loop
            List.Append (JSON.Element (Item, I));
         end loop;
      end if;
   end Append_Elements;

   function Declaration_For
     (Item : Resolved.Step; Outcome : String) return JSON.Value
   is
      Outcome_Data : constant JSON.Value :=
        (if Outcome'Length > 0 and then Is_Object (Item.Outcomes)
         then Outcomes.Data_Of (Item.Outcomes, Outcome)
         else JSON.Null_Value);
      Fields : Member_Lists.Vector;
      Checks : Value_Lists.Vector;
      Result : Member_Lists.Vector;
   begin
      if not Is_Object (Item.Data) and then not Is_Object (Outcome_Data) then
         return JSON.Null_Value;
      end if;
      Append_Members (Fields, Child (Item.Data, "fields"));
      Append_Members (Fields, Outcome_Data);
      Append_Elements (Checks, Child (Item.Data, "checks"));
      Result.Append (Member ("fields", To_Object (Fields)));
      if not Checks.Is_Empty then
         Result.Append (Member ("checks", To_Array (Checks)));
      end if;
      return To_Object (Result);
   end Declaration_For;

   function Problems
     (Item : Resolved.Step; Output : JSON.Value)
      return Synapse.Core.Text_Lists.Vector
   is
      Word : constant JSON.Value := Child (Output, "outcome");
      Declared : constant JSON.Value :=
        Declaration_For
          (Item,
           (if JSON.Kind_Of (Word) = JSON.JSON_String
            then JSON.As_String (Word) else ""));
      Data : constant JSON.Value := Child (Output, "data");
      None : Synapse.Core.Text_Lists.Vector;
   begin
      if JSON.Kind_Of (Declared) = JSON.JSON_Null then
         return None;
      elsif not Is_Object (Data) then
         None.Append (To_Unbounded_String ("data: expected an object"));
         return None;
      end if;
      return Synapse.Core.Object_Schema.Validate_Object
        (Declared, Data, Root => "data");
   end Problems;

end Synapse.Pipeline.Step_Data;
